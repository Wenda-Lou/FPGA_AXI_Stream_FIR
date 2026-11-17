"""Persistent single-worker job service with process-enforced deadlines."""

import csv
import hashlib
import io
import json
import logging
import math
import multiprocessing as mp
import re
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from model.fir import FirModel
from .rtl_runner import configuration, run_job, RtlError

FORMAT = "signed-int16-q1.15"
TERMINAL = {"succeeded", "failed", "timed_out"}


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def identifier(prefix):
    return prefix + "_" + uuid.uuid4().hex


class ApiError(Exception):
    def __init__(self, status, code, message, field=None):
        super().__init__(message)
        self.status, self.code, self.message, self.field = status, code, message, field

    def payload(self, request_id):
        return {"code": self.code, "message": self.message, "field": self.field, "request_id": request_id}


def parse_csv(data):
    if len(data) > 1024*1024:
        raise ApiError(413, "UPLOAD_TOO_LARGE", "File exceeds 1 MiB.", "file")
    try:
        rows = list(csv.reader(io.StringIO(data.decode("utf-8-sig"), newline=""), strict=True))
    except (UnicodeError, csv.Error):
        raise ApiError(400, "INVALID_CSV", "Expected UTF-8 CSV.", "file")
    if not rows or rows[0] != ["sample"]:
        raise ApiError(400, "INVALID_CSV", "Expected the single header sample.", "file")
    if not 1 <= len(rows)-1 <= 10000:
        raise ApiError(422, "INVALID_SAMPLE_COUNT", "Provide 1 to 10000 samples.", "file")
    samples = []
    for index, row in enumerate(rows[1:]):
        if len(row) != 1 or not re.fullmatch(r"[+-]?[0-9]+", row[0].strip()):
            raise ApiError(400, "INVALID_CSV", "Each data row must contain one decimal integer.", f"samples[{index}]")
        token = row[0].strip()
        # Avoid Python's long-integer conversion limit without rejecting leading zeros.
        digits = token.lstrip("+-").lstrip("0") or "0"
        if len(digits) > 5:
            raise ApiError(422, "SAMPLE_OUT_OF_RANGE", "Sample is outside signed int16.", f"samples[{index}]")
        value = int(("-" if token.startswith("-") else "") + digits)
        if not -32768 <= value <= 32767:
            raise ApiError(422, "SAMPLE_OUT_OF_RANGE", "Sample is outside signed int16.", f"samples[{index}]")
        samples.append(value)
    return samples


def reference_worker(output_path, samples, coefficients):
    """Child process: no access to HTTP state or another job's model history."""
    try:
        start = time.perf_counter()
        model = FirModel()
        for index, value in enumerate(coefficients):
            model.write_coefficient(index, value)
        values = [model.process(value) for value in samples]
        result = {"outputs": [value.value for value in values],
                  "saturated": [value.saturated for value in values],
                  "elapsed_ms": (time.perf_counter()-start)*1000}
        path = Path(output_path)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(result), encoding="utf-8")
        temporary.replace(path)
    except Exception:
        logging.exception("Reference worker failed")
        raise


class Service:
    def __init__(self, directory, timeout=30.0, worker=reference_worker, start_worker=True, vivado_bin=None, rtl_timeout=300.0):
        if not all(math.isfinite(value) and value > 0 for value in (timeout, rtl_timeout)):
            raise ValueError("Worker deadlines must be finite and positive")
        self.vivado_bin, self.rtl_reason = configuration(vivado_bin)
        self.rtl_timeout = rtl_timeout
        directory = Path(directory).resolve()
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.lock_file = (directory / "service.lock").open("a+b")
        try:
            if __import__("os").name == "nt":
                import msvcrt
                self.lock_file.seek(0)
                if not self.lock_file.read(1):
                    self.lock_file.write(b"0"); self.lock_file.flush()
                self.lock_file.seek(0)
                msvcrt.locking(self.lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock_file.close()
            raise RuntimeError("Another service owns this data directory")
        self.db = sqlite3.connect(directory / "service.sqlite3", check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS datasets (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, samples TEXT NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, status TEXT NOT NULL, result TEXT)")
        self.mutex = threading.RLock()
        self.stop = threading.Event()
        self.timeout, self.worker = timeout, worker
        self.closed = False
        for job_id, status in self.db.execute("SELECT id,status FROM jobs").fetchall():
            status = json.loads(status)
            if status["state"] not in TERMINAL:
                self._finish(status, "failed", error=ApiError(500, "SERVER_RESTART", "Server restarted before completion.").payload(identifier("req")))
        self.db.commit()
        self.thread = None
        if start_worker:
            self.thread = threading.Thread(target=self._work, name="fir-worker", daemon=True)
            self.thread.start()

    def capabilities(self):
        return {"api_version": "1", "format": FORMAT, "taps": 8,
                "limits": {"samples": 10000, "file_bytes": 1048576, "body_bytes": 2097152, "queued_jobs": 8},
                "modes": {"reference": {"available": True, "reason": None},
                          "rtl": {"available": self.vivado_bin is not None, "reason": self.rtl_reason}}}

    def upload(self, data):
        samples = parse_csv(data)
        canonical = "".join(f"{value}\n" for value in samples).encode("ascii")
        metadata = {"dataset_id": identifier("ds"), "sample_count": len(samples), "format": FORMAT,
                    "sha256": hashlib.sha256(canonical).hexdigest()}
        with self.mutex, self.db:
            self.db.execute("INSERT INTO datasets VALUES (?,?,?)", (metadata["dataset_id"], json.dumps(metadata), json.dumps(samples)))
        return metadata

    def dataset(self, dataset_id):
        with self.mutex:
            row = self.db.execute("SELECT metadata,samples FROM datasets WHERE id=?", (dataset_id,)).fetchone()
        if row is None:
            raise ApiError(404, "DATASET_NOT_FOUND", "Dataset does not exist.", "dataset_id")
        return json.loads(row[0]), json.loads(row[1])

    def submit(self, request, request_id):
        if type(request) is not dict or set(request) != {"mode", "dataset_id", "coefficients"}:
            raise ApiError(422, "INVALID_REQUEST", "Expected mode, dataset_id and coefficients.")
        if type(request["mode"]) is not str or request["mode"] not in ("reference", "rtl"):
            raise ApiError(422, "INVALID_REQUEST", "Unknown mode.", "mode")
        if type(request["dataset_id"]) is not str:
            raise ApiError(422, "INVALID_REQUEST", "dataset_id must be a string.", "dataset_id")
        coefficients = request["coefficients"]
        if type(coefficients) is not list or len(coefficients) != 8:
            raise ApiError(422, "INVALID_COEFFICIENT_COUNT", "Exactly eight coefficients are required.", "coefficients")
        for index, value in enumerate(coefficients):
            if type(value) is not int or not -32768 <= value <= 32767:
                raise ApiError(422, "COEFFICIENT_OUT_OF_RANGE", "Coefficient must be an integer between -32768 and 32767.", f"coefficients[{index}]")
        self.dataset(request["dataset_id"])
        if request["mode"] == "rtl" and self.vivado_bin is None:
            raise ApiError(503, "MODE_UNAVAILABLE", "RTL tools are not configured or available.", "mode")
        with self.mutex, self.db:
            queued = sum(json.loads(row[0])["state"] == "queued" for row in self.db.execute("SELECT status FROM jobs"))
            if queued >= 8:
                raise ApiError(429, "QUEUE_FULL", "The job queue is full.")
            status = {"job_id": identifier("job"), "mode": request["mode"], "dataset_id": request["dataset_id"],
                      "coefficients": list(coefficients), "state": "queued", "created_at": now(), "started_at": None,
                      "finished_at": None, "progress": None, "result_url": None, "error": None}
            self.db.execute("INSERT INTO jobs(id,status) VALUES (?,?)", (status["job_id"], json.dumps(status)))
        return status

    def job(self, job_id):
        with self.mutex:
            row = self.db.execute("SELECT status,result FROM jobs WHERE id=?", (job_id,)).fetchone()
        if row is None:
            raise ApiError(404, "JOB_NOT_FOUND", "Job does not exist.")
        return json.loads(row[0]), json.loads(row[1]) if row[1] else None

    def result(self, job_id):
        status, result = self.job(job_id)
        if status["state"] != "succeeded":
            code = "RESULT_NOT_READY" if status["state"] in ("queued", "running") else "JOB_NOT_SUCCEEDED"
            raise ApiError(409, code, "The job has no successful result.")
        return result

    def _finish(self, status, state, result=None, error=None):
        status.update(state=state, finished_at=now(), error=error,
                      result_url=f"/api/v1/jobs/{status['job_id']}/result" if state == "succeeded" else None)
        self.db.execute("UPDATE jobs SET status=?,result=? WHERE id=?", (json.dumps(status), json.dumps(result) if result is not None else None, status["job_id"]))

    def _execute(self, status):
        _, samples = self.dataset(status["dataset_id"])
        run_dir = self.directory / "runs" / status["job_id"]
        run_dir.mkdir(parents=True)
        if status["mode"] == "rtl":
            try:
                values = run_job(run_dir, samples, status["coefficients"], self.vivado_bin,
                                 time.monotonic()+self.rtl_timeout, self.stop)
            except RtlError as error:
                raise ApiError(500, error.code, error.message)
            return self._result(status, samples, values)
        output_path = run_dir / "worker.json"
        process = mp.get_context("spawn").Process(target=self.worker, args=(str(output_path), samples, status["coefficients"]), daemon=True)
        deadline = time.monotonic() + self.timeout
        try:
            process.start()
            while process.is_alive():
                if self.stop.is_set():
                    raise ApiError(500, "SERVER_RESTART", "Server stopped before completion.")
                if time.monotonic() >= deadline:
                    raise ApiError(500, "EXECUTION_TIMEOUT", "Worker exceeded its deadline.")
                process.join(min(.02, max(0, deadline-time.monotonic())))
            if process.exitcode != 0 or not output_path.is_file():
                raise ApiError(500, "EXECUTION_FAILED", "Worker exited without a result.")
            values = json.loads(output_path.read_text(encoding="utf-8"))
            if len(values["outputs"]) != len(samples) or len(values["saturated"]) != len(samples):
                raise ApiError(500, "EXECUTION_FAILED", "Worker output count is invalid.")
            return self._result(status, samples, values)
        finally:
            if process.pid is not None:
                if process.is_alive(): process.terminate()
                process.join()
                process.close()

    def _result(self, status, samples, values):
        rtl = status["mode"] == "rtl"
        execution = dict(values.get("execution", {"engine": "python-reference", "tool_version": None}))
        execution["run_id"] = identifier("run")
        return {"job_id": status["job_id"], "mode": status["mode"], "format": FORMAT,
                "input_count": len(samples), "output_count": len(samples), "inputs": samples,
                "outputs": values["outputs"], "saturated": values["saturated"], "saturation_count": sum(values["saturated"]),
                "verification": values["verification"] if rtl else {"status": "not_applicable", "compared_outputs": 0, "mismatches": None},
                "metrics": {"worker_elapsed_ms": values["elapsed_ms"], "rtl_cycles": values["rtl_cycles"] if rtl else None,
                            "clock_period_ns": 10 if rtl else None},
                "execution": execution}

    def _work(self):
        while not self.stop.is_set():
            status = None
            with self.mutex, self.db:
                for row in self.db.execute("SELECT status FROM jobs ORDER BY sequence"):
                    candidate = json.loads(row[0])
                    if candidate["state"] == "queued":
                        status = candidate
                        status.update(state="running", started_at=now())
                        self.db.execute("UPDATE jobs SET status=? WHERE id=?", (json.dumps(status), status["job_id"]))
                        break
            if status is None:
                self.stop.wait(.05)
                continue
            try:
                result = self._execute(status)
                with self.mutex, self.db: self._finish(status, "succeeded", result=result)
            except Exception as error:
                if not isinstance(error, ApiError):
                    logging.exception("Job failed: %s", status["job_id"])
                    error = ApiError(500, "EXECUTION_FAILED", "Worker execution failed.")
                state = "timed_out" if error.code == "EXECUTION_TIMEOUT" else "failed"
                detail = error.payload(identifier("req"))
                logging.warning("Job=%s code=%s request=%s", status["job_id"], detail["code"], detail["request_id"])
                with self.mutex, self.db: self._finish(status, state, error=detail)

    def close(self):
        if self.closed: return
        self.stop.set()
        if self.thread: self.thread.join()
        with self.mutex: self.db.close()
        self.lock_file.close()
        self.closed = True


def result_csv(result):
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(["sample_index", "input_raw", "output_raw", "saturated"])
    writer.writerows((i, sample, output, int(flag)) for i, (sample, output, flag) in
                    enumerate(zip(result["inputs"], result["outputs"], result["saturated"])))
    return buffer.getvalue().encode("utf-8")
