"""Real loopback HTTP tests; fault-injected workers are labeled explicitly."""

import hashlib
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

from webapp.server import Server
from webapp.service import ApiError, Service, parse_csv


def crashing_worker(output_path, samples, coefficients):
    __import__("os")._exit(3)


def slow_worker(output_path, samples, coefficients):
    time.sleep(10)


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.service = Service(self.temp.name)
        self.server = Server(("127.0.0.1", 0), self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.service.close(); self.temp.cleanup()

    def call(self, path, method="GET", body=None, content_type=None):
        headers = {"Content-Type": content_type} if content_type else {}
        request = urllib.request.Request(self.url+path, data=body, headers=headers, method=method)
        try: response = urllib.request.urlopen(request, timeout=10)
        except urllib.error.HTTPError as error: response = error
        with response:
            data = response.read()
            return response.status, response.headers, data

    def upload(self, content=b"sample\n16384\n-16384\n1\n"):
        body = b'--boundary\r\nContent-Disposition: form-data; name="file"; filename="samples.csv"\r\nContent-Type: text/csv\r\n\r\n'+content+b'\r\n--boundary--\r\n'
        code, headers, data = self.call("/api/v1/datasets", "POST", body, "multipart/form-data; boundary=boundary")
        self.assertEqual(code, 201, data)
        metadata = json.loads(data)
        self.assertEqual(headers["Location"], "/api/v1/datasets/"+metadata["dataset_id"])
        return metadata

    def post_job(self, dataset, coefficients=None, **extra):
        request = {"mode": "reference", "dataset_id": dataset,
                   "coefficients": coefficients if coefficients is not None else [16384]+[0]*7}
        request.update(extra)
        code, headers, body = self.call("/api/v1/jobs", "POST", json.dumps(request).encode(), "application/json")
        return code, headers, json.loads(body)

    def wait(self, job_id):
        deadline = time.monotonic()+15
        while time.monotonic() < deadline:
            code, _, body = self.call("/api/v1/jobs/"+job_id)
            self.assertEqual(code, 200)
            status = json.loads(body)
            if status["state"] in ("succeeded", "failed", "timed_out"): return status
            time.sleep(.02)
        self.fail("Job did not reach terminal state")

    def test_full_http_processing_download_and_persistence(self):
        metadata = self.upload()
        self.assertEqual(metadata["sha256"], hashlib.sha256(b"16384\n-16384\n1\n").hexdigest())
        self.assertEqual(json.loads(self.call("/api/v1/datasets/"+metadata["dataset_id"])[2]), metadata)
        code, headers, status = self.post_job(metadata["dataset_id"])
        self.assertEqual(code, 202)
        self.assertEqual(headers["Location"], "/api/v1/jobs/"+status["job_id"])
        status = self.wait(status["job_id"])
        self.assertEqual(status["state"], "succeeded")
        self.assertIsNotNone(status["started_at"]); self.assertIsNotNone(status["finished_at"])
        result = json.loads(self.call(status["result_url"])[2])
        self.assertEqual(result["outputs"], [8192,-8192,0])
        self.assertEqual(result["saturated"], [False]*3)
        self.assertEqual(result["verification"]["status"], "not_applicable")
        self.assertEqual(result["execution"]["engine"], "python-reference")
        self.assertIsNone(result["metrics"]["clock_period_ns"])
        code, headers, data = self.call(status["result_url"]+".csv")
        self.assertEqual(code, 200)
        self.assertIn("attachment", headers["Content-Disposition"])
        self.assertEqual(data, b"sample_index,input_raw,output_raw,saturated\n0,16384,8192,0\n1,-16384,-8192,0\n2,1,0,0\n")
        # Reload stored state through a new service instance without rerunning it.
        self.service.close()
        self.service = Service(self.temp.name)
        self.server.service = self.service
        self.assertEqual(self.service.result(status["job_id"]), result)

    def test_capabilities_rtl_not_silently_fallback(self):
        caps = json.loads(self.call("/api/v1/capabilities")[2])
        self.assertTrue(caps["modes"]["reference"]["available"])
        self.assertFalse(caps["modes"]["rtl"]["available"])
        code, _, data = self.post_job(self.upload()["dataset_id"], mode="rtl")
        self.assertEqual(code, 503); self.assertEqual(data["error"]["code"], "MODE_UNAVAILABLE")

    def test_strict_coefficients_and_unknown_fields(self):
        dataset = self.upload()["dataset_id"]
        for bad in (True, "1", 1.0, None, 32768, -32769):
            with self.subTest(value=bad):
                code, _, body = self.post_job(dataset, [bad]+[0]*7)
                self.assertEqual(code, 422)
                self.assertEqual(body["error"]["field"], "coefficients[0]")
        self.assertEqual(self.post_job(dataset, [0]*7)[2]["error"]["code"], "INVALID_COEFFICIENT_COUNT")
        self.assertEqual(self.post_job(dataset, command="anything")[0], 422)

    def test_unknown_ids_and_bad_json(self):
        for path in ("/api/v1/jobs/job_missing", "/api/v1/jobs/job_missing/result", "/api/v1/jobs/job_missing/result.csv", "/api/v1/datasets/ds_missing"):
            code, headers, body = self.call(path)
            self.assertEqual(code, 404); self.assertEqual(json.loads(body)["error"]["request_id"], headers["X-Request-ID"])
        for data in (b'{', b'{"mode":"reference","mode":"rtl"}', b'{"value":NaN}'):
            self.assertEqual(self.call("/api/v1/jobs", "POST", data, "application/json")[0], 400)
        self.assertEqual(self.call("/api/v1/jobs", "POST", b'{}', "text/plain")[0], 415)

    def test_upload_validation_and_limits(self):
        for content, expected in ((b"sample\n1.0\n",400),(b"sample\n\n",400),(b"other\n1\n",400),
                                  (b"sample\n1,2\n",400),(b"sample\n32768\n",422),(b"sample\n",422)):
            body=b'--b\r\nContent-Disposition: form-data; name="file"; filename="f"\r\n\r\n'+content+b'\r\n--b--\r\n'
            self.assertEqual(self.call("/api/v1/datasets","POST",body,"multipart/form-data; boundary=b")[0],expected)
        self.assertEqual(self.call("/api/v1/datasets","POST",b"x"*(2*1024*1024+1),"multipart/form-data; boundary=b")[0],413)
        self.assertEqual(self.call("/api/v1/datasets","POST",b"bad","multipart/form-data; boundary=b")[0],400)

    def test_isolated_history_and_saturation(self):
        metadata=self.upload(b"sample\n32767\n32767\n-32768\n")
        results=[]
        for _ in range(2):
            status=self.wait(self.post_job(metadata["dataset_id"],[32767]*8)[2]["job_id"])
            results.append(json.loads(self.call(status["result_url"])[2]))
        self.assertNotEqual(results[0]["job_id"],results[1]["job_id"])
        self.assertEqual(results[0]["outputs"],results[1]["outputs"])
        self.assertEqual(results[0]["saturation_count"],1)
        self.assertEqual(results[0]["saturated"],[False,True,False])

    def test_maximum_dataset_and_result(self):
        dataset=self.upload(b"sample\n"+b"32767\n"*10000)
        status=self.wait(self.post_job(dataset["dataset_id"])[2]["job_id"])
        self.assertEqual(status["state"],"succeeded")
        result=json.loads(self.call(status["result_url"])[2])
        self.assertEqual(result["output_count"],10000)
        self.assertEqual(result["outputs"],[16383]*10000)
        with self.assertRaises(ApiError) as error: parse_csv(b"sample\n"+b"0\n"*10001)
        self.assertEqual(error.exception.code,"INVALID_SAMPLE_COUNT")


class ServiceLifecycleTests(unittest.TestCase):
    def test_queue_limit_readiness_restart_and_single_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            service=Service(directory,start_worker=False)
            try:
                with self.assertRaises(RuntimeError): Service(directory,start_worker=False)
                dataset=service.upload(b"sample\n1\n")["dataset_id"]
                request={"dataset_id":dataset,"mode":"reference","coefficients":[0]*8}
                jobs=[service.submit(request,"req_test") for _ in range(8)]
                with self.assertRaises(ApiError) as error: service.submit(request,"req_test")
                self.assertEqual(error.exception.code,"QUEUE_FULL")
                with self.assertRaises(ApiError) as error: service.result(jobs[0]["job_id"])
                self.assertEqual(error.exception.code,"RESULT_NOT_READY")
            finally: service.close()
            service=Service(directory)
            try:
                for job in jobs:
                    status,_=service.job(job["job_id"])
                    self.assertEqual(status["state"],"failed")
                    self.assertEqual(status["error"]["code"],"SERVER_RESTART")
                    with self.assertRaises(ApiError) as error: service.result(job["job_id"])
                    self.assertEqual(error.exception.code,"JOB_NOT_SUCCEEDED")
            finally: service.close()

    def test_fault_injected_timeout_and_crashed_worker(self):
        for worker,deadline,state in ((slow_worker,.1,"timed_out"),(crashing_worker,10,"failed")):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                service=Service(directory,timeout=deadline,worker=worker)
                try:
                    dataset=service.upload(b"sample\n1\n")["dataset_id"]
                    job=service.submit({"dataset_id":dataset,"mode":"reference","coefficients":[0]*8},"req_test")
                    until=time.monotonic()+15
                    while time.monotonic()<until:
                        status,result=service.job(job["job_id"])
                        if status["state"] in ("failed","timed_out"): break
                        time.sleep(.02)
                    self.assertEqual(status["state"],state)
                    self.assertIsNone(result)
                    self.assertIsNone(status["result_url"])
                finally: service.close()

    def test_csv_canonicalization_and_large_integer(self):
        self.assertEqual(parse_csv(b"\xef\xbb\xbfsample\r\n +001 \r\n-0002"),[1,-2])
        self.assertEqual(parse_csv(b"sample\n"+b"0"*5000+b"1\n"),[1])
        with self.assertRaises(ApiError) as error: parse_csv(b"sample\n"+b"9"*5000+b"\n")
        self.assertEqual(error.exception.code,"SAMPLE_OUT_OF_RANGE")


if __name__ == "__main__": unittest.main()
