"""Execute private, request-specific XSim jobs and verify actual handshakes."""

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from model.fir import FirModel

ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = ROOT / "fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new"
SOURCES = [RTL_DIR / name for name in ("axis_fifo.v", "fir_core.v", "dsp_datapath.v", "axi_lite_regs.v", "dsp_accelerator.v")] + [
    ROOT / "webapp/rtl/tb_web_fir.sv", ROOT / "scripts/run_web_rtl.ps1"]


class RtlError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def configuration(vivado_bin):
    if not vivado_bin: return None, "RTL_NOT_CONFIGURED"
    if os.name != "nt": return None, "RTL_PLATFORM_UNSUPPORTED"
    directory = Path(vivado_bin).resolve()
    if not shutil.which("powershell.exe") or not all((directory / (name+".bat")).is_file() for name in ("xvlog", "xelab", "xsim")):
        return None, "RTL_TOOLS_UNAVAILABLE"
    if not all(path.is_file() for path in SOURCES): return None, "RTL_ADAPTER_UNAVAILABLE"
    return directory, None


def terminate_tree(process):
    """Only called with the still-owned process handle for this particular job."""
    if process.poll() is not None: return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW, timeout=15)
    else:
        os.killpg(process.pid, signal.SIGKILL)
    if process.poll() is None: process.kill()
    process.wait(timeout=15)


def parse_results(directory, samples, coefficients):
    """Fail closed on count/order/input mismatch before numerical comparison."""
    directory = Path(directory)
    try:
        accepted = [list(map(int, line.split())) for line in (directory / "rtl_inputs.txt").read_text(encoding="utf-8-sig").splitlines()]
        actual = [list(map(int, line.split())) for line in (directory / "rtl_outputs.txt").read_text(encoding="utf-8-sig").splitlines()]
        summary = list(map(int, (directory / "rtl_summary.txt").read_text(encoding="utf-8-sig").split()))
    except (OSError, ValueError):
        raise RtlError("RTL_PROTOCOL_ERROR", "Simulation did not export valid transfer evidence.")
    if len(accepted) != len(samples) or len(actual) != len(samples) or len(summary) != 3 or summary[:2] != [len(samples)]*2:
        raise RtlError("RTL_OUTPUT_COUNT_MISMATCH", "Simulation input/output counts do not match the request.")
    if accepted != [[i, value] for i, value in enumerate(samples)] or summary[2] < 1:
        raise RtlError("RTL_PROTOCOL_ERROR", "Accepted simulation inputs differ from the submitted dataset.")
    if any(len(row) != 3 or row[0] != i or not -32768 <= row[1] <= 32767 or row[2] not in (0, 1) for i, row in enumerate(actual)):
        raise RtlError("RTL_PROTOCOL_ERROR", "Simulation output ordering or payload format is invalid.")
    model = FirModel()
    for index, value in enumerate(coefficients): model.write_coefficient(index, value)
    expected = [model.process(sample) for sample in samples]
    mismatches = sum((row[1], bool(row[2])) != (value.value, value.saturated) for row, value in zip(actual, expected))
    comparison = {"status": "passed" if not mismatches else "failed", "compared_outputs": len(actual), "mismatches": mismatches}
    (directory / "comparison.json").write_text(json.dumps(comparison, indent=2)+"\n", encoding="utf-8")
    if mismatches: raise RtlError("RTL_MISMATCH", "Simulation output or clipping flags differ from the Python reference.")
    return {"outputs": [row[1] for row in actual], "saturated": [bool(row[2]) for row in actual],
            "rtl_cycles": summary[2], "verification": comparison}


def run_job(directory, samples, coefficients, vivado_bin, deadline, stop):
    started = time.perf_counter()
    directory = Path(directory)
    snapshot = directory / "sources"
    snapshot.mkdir()
    source_hashes = {}
    for source in SOURCES:
        destination = snapshot / source.name
        shutil.copyfile(source, destination)
        source_hashes[source.relative_to(ROOT).as_posix()] = sha(destination)
    for name, values in (("input.mem", samples), ("coefficients.mem", coefficients)):
        (directory / name).write_text("".join(f"{value & 0xffff:04x}\n" for value in values), encoding="ascii")
    (directory / "request.json").write_text(json.dumps({"samples": samples, "coefficients": coefficients}, indent=2)+"\n", encoding="utf-8")
    command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(snapshot / "run_web_rtl.ps1"),
               "-VivadoBin", str(vivado_bin), "-SourcesDir", str(snapshot), "-JobDir", str(directory), "-Count", str(len(samples))]
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {"start_new_session": True}
    with (directory / "runner.stdout.txt").open("wb") as stdout, (directory / "runner.stderr.txt").open("wb") as stderr:
        process = subprocess.Popen(command, cwd=directory, stdout=stdout, stderr=stderr, **options)
        try:
            while process.poll() is None:
                if stop.is_set(): raise RtlError("SERVER_RESTART", "Server stopped before simulation finished.")
                if time.monotonic() >= deadline: raise RtlError("EXECUTION_TIMEOUT", "RTL compilation/simulation exceeded its deadline.")
                stop.wait(.05)
        finally:
            terminate_tree(process)
    simulation = directory / "simulation.log"
    log = simulation.read_text(encoding="utf-8-sig", errors="replace") if simulation.is_file() else ""
    if re.search(r"^\s*(fatal|error)\s*:", log, re.I | re.M):
        raise RtlError("RTL_PROTOCOL_ERROR", "Simulation failed a protocol or accounting check.")
    if process.returncode != 0 or "PASS: web_request " not in log:
        raise RtlError("EXECUTION_FAILED", "RTL tools did not complete the request successfully.")
    values = parse_results(directory, samples, coefficients)
    version = re.search(r"xsim v([^\s]+)", log, re.I)
    if not version: raise RtlError("RTL_PROTOCOL_ERROR", "Simulator version is missing from the execution log.")
    if time.monotonic() >= deadline: raise RtlError("EXECUTION_TIMEOUT", "RTL job exceeded its deadline.")
    artifacts = {path.name: sha(path) for path in directory.iterdir() if path.is_file()}
    evidence = {"engine": "vivado-xsim", "tool_version": "Vivado XSim "+version[1],
                "source_sha256": source_hashes, "artifact_sha256": artifacts}
    (directory / "evidence.json").write_text(json.dumps(evidence, indent=2)+"\n", encoding="utf-8")
    values.update(elapsed_ms=(time.perf_counter()-started)*1000, execution=evidence)
    return values
