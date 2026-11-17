"""Selenium + real loopback backend. Timeout case uses an injected slow worker."""

import argparse
import csv
import shutil
import hashlib
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
if (ROOT / "build/web_test_deps").is_dir(): sys.path.insert(0, str(ROOT / "build/web_test_deps"))
import selenium
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait, Select
from webapp.server import Server
from webapp.service import Service, reference_worker

OUTPUT = ROOT / "build/web_e2e"


def slow_worker(output_path, samples, coefficients):
    time.sleep(10)


def gated_reference_worker(output_path, samples, coefficients):
    """Test-only timing gate; computation still uses the real reference worker."""
    gate = Path(output_path).parent / "release.marker"
    deadline = time.monotonic()+25
    while not gate.exists():
        if time.monotonic() >= deadline: raise RuntimeError("Test did not release its worker")
        time.sleep(.02)
    reference_worker(output_path, samples, coefficients)


class BrowserFixture(unittest.TestCase):
    vivado_bin = None
    execution_records = []
    @classmethod
    def setUpClass(cls):
        OUTPUT.mkdir(parents=True, exist_ok=True)
        cls.downloads = OUTPUT / "downloads"
        cls.downloads.mkdir(exist_ok=True)
        os.environ.setdefault("SE_CACHE_PATH", str(ROOT / "build/selenium_cache"))
        os.environ.setdefault("SE_AVOID_STATS", "true")
        options = webdriver.EdgeOptions()
        for flag in ("--headless=new", "--disable-gpu", "--no-first-run", "--disable-background-networking", "--window-size=1440,1100"):
            options.add_argument(flag)
        options.add_experimental_option("prefs", {"download.default_directory": str(cls.downloads), "download.prompt_for_download": False})
        cls.driver = webdriver.Edge(options=options)
        cls.wait = WebDriverWait(cls.driver, 120 if cls.vivado_bin else 20)

    @classmethod
    def tearDownClass(cls):
        cls.driver.quit()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=OUTPUT)
        kwargs = {"worker": slow_worker, "timeout": .1} if "injected_timeout" in self.id() else {}
        if "running_refresh" in self.id(): kwargs["worker"] = gated_reference_worker
        if self.vivado_bin:
            kwargs["vivado_bin"] = self.vivado_bin
            if "native_timeout" in self.id(): kwargs["rtl_timeout"] = .1
        self.service = Service(Path(self.temp.name)/"state", **kwargs)
        self.server = Server(("127.0.0.1", 0), self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.driver.set_window_size(1440, 1100)
        self.driver.execute_cdp_cmd("Emulation.clearDeviceMetricsOverride", {})
        self.driver.get(self.url)
        self.wait.until(lambda d: not self.element("mode-select").get_property("disabled"))

    def tearDown(self):
        name = self._testMethodName
        self.driver.save_screenshot(str(OUTPUT / f"{name}.png"))
        (OUTPUT / f"{name}.html").write_text(self.driver.page_source, encoding="utf-8")
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.service.close()
        if self.vivado_bin:
            connection = __import__("sqlite3").connect(Path(self.temp.name)/"state/service.sqlite3")
            for status_text,result_text in connection.execute("SELECT status,result FROM jobs"):
                status=json.loads(status_text); value=json.loads(result_text) if result_text else None
                record={"test":name,"status":status,"result":value}
                self.execution_records.append(record)
                destination=OUTPUT/"rtl_jobs"/status["job_id"]
                destination.mkdir(parents=True,exist_ok=True)
                (destination/"job.json").write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
                source=Path(self.temp.name)/"state/runs"/status["job_id"]
                if source.exists():
                    for item in source.iterdir():
                        if item.is_file() and item.suffix in ('.txt','.json','.mem','.log'):
                            shutil.copyfile(item,destination/item.name)
                    if (source/'sources').is_dir(): shutil.copytree(source/'sources',destination/'sources')
            connection.close()
        self.temp.cleanup()

    def element(self, test_id):
        return self.driver.find_element(By.CSS_SELECTOR, f'[data-testid="{test_id}"]')

    def upload(self, text="sample\n16384\n-16384\n1\n", success=True):
        path = Path(self.temp.name)/"samples.csv"
        path.write_text(text, encoding="utf-8")
        self.element("sample-upload").send_keys(str(path))
        self.element("upload-dataset").click()
        if success:
            self.wait.until(lambda d: "samples ready" in self.element("sample-count").text)
        else:
            self.wait.until(lambda d: self.element("error-message").is_displayed())

    def run_job(self, state="succeeded"):
        self.wait.until(lambda d: self.element("submit-job").is_enabled())
        self.element("submit-job").click()
        self.wait.until(lambda d: self.element("job-status").get_attribute("data-state") in ("succeeded","failed","timed_out"))
        self.assertEqual(self.element("job-status").get_attribute("data-state"),state,self.element("error-message").text)
        if state == "succeeded": self.wait.until(lambda d: self.element("download-results").is_displayed())

class BrowserTests(BrowserFixture):
    def test_running_refresh_preserves_job_and_finishes(self):
        self.upload()
        self.element("submit-job").click()
        self.wait.until(lambda d: self.element("job-status").get_attribute("data-state")=="running")
        job=self.element("job-id").text
        self.driver.refresh()
        self.wait.until(lambda d: self.element("job-status").get_attribute("data-state")=="running")
        self.assertEqual(self.element("job-id").text,job)
        self.assertFalse(self.element("submit-job").is_enabled())
        (self.service.directory/"runs"/job/"release.marker").touch()
        self.wait.until(lambda d:self.element("download-results").is_displayed())
        self.assertEqual(self.service.result(job)["outputs"],[8192,-8192,0])
        with self.service.mutex:
            self.assertEqual(self.service.db.execute("SELECT count(*) FROM jobs").fetchone()[0],1)

    def test_server_restart_preserves_result_and_fails_unfinished(self):
        self.upload();self.run_job()
        finished=self.element("job-id").text
        old_result=self.service.result(finished)
        self.service.worker=gated_reference_worker
        self.element("submit-job").click()
        self.wait.until(lambda d:self.element("job-status").get_attribute("data-state")=="running")
        running=self.element("job-id").text
        current,_=self.service.job(running)
        queued=self.service.submit({"mode":"reference","dataset_id":current["dataset_id"],"coefficients":current["coefficients"]},"req_restart_test")
        address=self.server.server_address
        self.server.shutdown();self.server.server_close();self.thread.join();self.service.close()
        self.service=Service(Path(self.temp.name)/"state")
        self.server=Server(address,self.service)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.driver.refresh()
        self.wait.until(lambda d:self.element("job-status").get_attribute("data-state")=="failed")
        self.assertEqual(self.element("error-message").get_attribute("data-code"),"SERVER_RESTART")
        self.assertFalse(self.element("download-results").is_displayed())
        self.assertEqual(self.service.job(queued["job_id"])[0]["error"]["code"],"SERVER_RESTART")
        self.driver.get(self.url+"/?job_id="+finished)
        self.wait.until(lambda d:self.element("download-results").is_displayed())
        self.assertEqual(self.service.result(finished),old_result)

    def test_real_reference_flow(self):
        self.upload(); self.run_job()
        self.assertEqual(self.element("execution-engine").text, "python-reference")
        rows = self.element("result-table").find_elements(By.CSS_SELECTOR,"tbody tr")
        self.assertEqual([[cell.text for cell in row.find_elements(By.TAG_NAME,"td")] for row in rows],
                         [["0","16384","8192","No"],["1","-16384","-8192","No"],["2","1","0","No"]])
        self.assertEqual(self.element("saturation-count").text,"0")
        self.assertTrue(self.element("output-chart").is_displayed())
        self.assertIn("not applicable", self.driver.find_element(By.ID,"verification").text)

    def test_invalid_coefficient_blocks_submission(self):
        self.upload()
        field=self.element("coefficient-2"); field.clear(); field.send_keys("32768")
        self.assertFalse(self.element("submit-job").is_enabled())
        self.assertEqual(field.get_attribute("aria-invalid"),"true")
        self.assertEqual(self.element("error-message").get_attribute("data-code"),"COEFFICIENT_OUT_OF_RANGE")
        field.clear(); field.send_keys("0")
        self.wait.until(lambda d: self.element("submit-job").is_enabled())

    def test_bad_csv_error_is_real_backend_response(self):
        self.upload("sample\nnot-a-number\n",success=False)
        self.assertEqual(self.element("error-message").get_attribute("data-code"),"INVALID_CSV")
        self.assertFalse(self.element("submit-job").is_enabled())

    def test_refresh_restores_same_job_without_rerun(self):
        self.upload(); self.run_job()
        job=self.element("job-id").text
        before=self.service.result(job)["execution"]["run_id"]
        self.driver.refresh()
        self.wait.until(lambda d: self.element("download-results").is_displayed())
        self.assertEqual(self.element("job-id").text,job)
        self.assertEqual(self.service.result(job)["execution"]["run_id"],before)
        self.assertIn("3 samples ready",self.element("sample-count").text)

    def test_actual_csv_download(self):
        self.upload(); self.run_job()
        job=self.element("job-id").text
        path=self.downloads/f"fir-{job}.csv"
        self.element("download-results").click()
        self.wait.until(lambda d: path.exists() and path.stat().st_size>0)
        with path.open(encoding="utf-8",newline="") as file: rows=list(csv.reader(file))
        self.assertEqual(rows[0],["sample_index","input_raw","output_raw","saturated"])
        self.assertEqual(rows[1:],[['0','16384','8192','0'],['1','-16384','-8192','0'],['2','1','0','0']])

    def test_rtl_mode_is_disabled(self):
        option=self.element("mode-select").find_element(By.CSS_SELECTOR,'option[value="rtl"]')
        self.assertTrue(option.get_property("disabled"))

    def test_pagination_and_mobile_layout(self):
        self.upload("sample\n"+"\n".join(str(i) for i in range(128))+"\n"); self.run_job()
        self.assertEqual(len(self.element("result-table").find_elements(By.CSS_SELECTOR,"tbody tr")),50)
        self.driver.find_element(By.ID,"next").click()
        self.assertEqual(self.element("result-table").find_element(By.CSS_SELECTOR,"tbody td").text,"50")
        self.driver.find_element(By.ID,"next").click()
        self.assertEqual(len(self.element("result-table").find_elements(By.CSS_SELECTOR,"tbody tr")),28)
        self.assertFalse(self.driver.find_element(By.ID,"next").is_enabled())
        self.driver.execute_cdp_cmd("Emulation.setDeviceMetricsOverride", {"width":390,"height":1000,"deviceScaleFactor":1,"mobile":True})
        self.assertEqual(self.driver.execute_script("return window.innerWidth"),390)
        self.assertTrue(self.driver.execute_script("return document.documentElement.scrollWidth <= window.innerWidth"))

    def test_explicitly_injected_timeout_is_not_success(self):
        self.upload(); self.run_job(state="timed_out")
        self.assertEqual(self.element("error-message").get_attribute("data-code"),"EXECUTION_TIMEOUT")
        self.assertFalse(self.element("download-results").is_displayed())

    def test_unknown_job_link(self):
        self.driver.get(self.url+"/?job_id=job_missing")
        self.wait.until(lambda d: self.element("error-message").is_displayed())
        self.assertEqual(self.element("error-message").get_attribute("data-code"),"JOB_NOT_FOUND")


class RtlBrowserTests(BrowserFixture):
    def select_rtl(self):
        self.wait.until(lambda d: not self.element("mode-select").find_element(By.CSS_SELECTOR,'option[value="rtl"]').get_property("disabled"))
        Select(self.element("mode-select")).select_by_value("rtl")

    def test_rtl_saturation_refresh_and_download(self):
        self.select_rtl()
        samples=[32767]*16+[-32768]*24
        self.upload("sample\n"+"".join(f"{value}\n" for value in samples))
        for i in range(8):
            field=self.element(f"coefficient-{i}");field.clear();field.send_keys("32767")
        self.run_job()
        job=self.element("job-id").text
        value=self.service.result(job)
        self.assertEqual(self.element("execution-engine").text,"vivado-xsim")
        self.assertEqual(value['verification'],{'status':'passed','compared_outputs':40,'mismatches':0})
        self.assertIn('RTL data and flags verified',self.driver.find_element(By.ID,'verification').text)
        self.assertGreater(value['saturation_count'],0)
        self.driver.refresh()
        self.wait.until(lambda d:self.element('download-results').is_displayed())
        self.assertEqual(self.service.result(job)['execution']['run_id'],value['execution']['run_id'])
        self.element('download-results').click()
        path=self.downloads/f'fir-{job}.csv'
        self.wait.until(lambda d:path.exists() and path.stat().st_size>0)
        with path.open(encoding='utf-8',newline='') as file: rows=list(csv.DictReader(file))
        self.assertEqual([int(row['output_raw']) for row in rows],value['outputs'])
        self.assertEqual([bool(int(row['saturated'])) for row in rows],value['saturated'])

    def test_rtl_changed_coefficients_produce_new_results(self):
        self.select_rtl();self.upload('sample\n16384\n-16384\n0\n8192\n')
        self.run_job();first=self.element('job-id').text
        first_value=self.service.result(first)
        field=self.element('coefficient-0');field.clear();field.send_keys('-16384')
        self.run_job();second=self.element('job-id').text
        second_value=self.service.result(second)
        self.assertNotEqual(first,second)
        self.assertEqual(second_value['outputs'],[-value for value in first_value['outputs']])
        self.assertEqual(first_value['execution']['engine'],second_value['execution']['engine'])
        self.assertEqual(second_value['execution']['engine'],'vivado-xsim')

    def test_rtl_native_timeout_no_partial_result(self):
        self.select_rtl();self.upload();self.run_job(state='timed_out')
        self.assertEqual(self.element('error-message').get_attribute('data-code'),'EXECUTION_TIMEOUT')
        self.assertFalse(self.element('download-results').is_displayed())


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl',action='store_true')
    parser.add_argument('--vivado-bin')
    args=parser.parse_args()
    if args.rtl and not args.vivado_bin:parser.error('--rtl requires --vivado-bin')
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(BrowserTests)
    if args.rtl:
        RtlBrowserTests.vivado_bin=args.vivado_bin
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(RtlBrowserTests))
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    driver=getattr(RtlBrowserTests if args.rtl else BrowserTests,'driver',None)
    data={"status":"passed" if result.wasSuccessful() else "failed", "tests":result.testsRun,
          "failures":len(result.failures),"errors":len(result.errors),"selenium_version":selenium.__version__,
          "scope":"Real headless Edge + real HTTP backend; reference fault case is explicitly injected; RTL cases use actual XSim and a real native-process timeout" if args.rtl else "Real headless Edge + reference HTTP backend; timeout test uses an injected slow worker",
          "browser_name":driver.capabilities['browserName'] if driver else None,
          "browser_version":driver.capabilities['browserVersion'] if driver else None,
          "rtl_jobs":BrowserFixture.execution_records,
          "source_sha256":{p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest().upper()
                           for p in [*sorted((ROOT/'webapp').rglob('*')), ROOT/'model/fir.py',ROOT/'scripts/run_web_rtl.ps1', Path(__file__).resolve()]
                           if p.is_file() and '__pycache__' not in p.parts}}
    OUTPUT.mkdir(parents=True,exist_ok=True)
    (OUTPUT/'results.json').write_text(json.dumps(data,indent=2)+'\n',encoding='utf-8')
    sys.exit(0 if result.wasSuccessful() else 1)
