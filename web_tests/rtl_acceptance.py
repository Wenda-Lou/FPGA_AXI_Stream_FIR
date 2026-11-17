"""Real HTTP -> request-driven XSim acceptance. No precomputed RTL outputs."""

import argparse
import csv
import io
import json
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from webapp.service import Service
from webapp.server import Server


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vivado-bin',required=True)
    args=parser.parse_args()
    output=ROOT/'build/web_rtl_acceptance'
    output.mkdir(exist_ok=True)
    service=Service(output/'state',vivado_bin=args.vivado_bin)
    server=Server(('127.0.0.1',0),service)
    thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    url=f'http://127.0.0.1:{server.server_port}'
    def call(path,body=None,content_type=None):
        request=urllib.request.Request(url+path,data=body,headers={'Content-Type':content_type} if content_type else {})
        try: response=urllib.request.urlopen(request,timeout=10)
        except urllib.error.HTTPError as error: response=error
        with response: return response.status,response.read()
    rng=random.Random(1); other=random.Random(42)
    max_samples=[rng.randint(-32768,32767) for _ in range(10000)]
    other_samples=[other.randint(-32768,32767) for _ in range(257)]
    cases=[('negative_shift',[1],[-1]+[0]*7),
           ('impulse',[16384]+[0]*30,[16384,-8192,4096,-2048,1024,-512,256,-128]),
           ('zero_coefficients',[32767,-32768,-1,1]*128,[0]*8),
           ('both_saturation_signs',[32767]*16+[-32768]*24,[32767]*8),
           ('signed_extrema',[32767,-32768,-1,0,1]*51,[-32768,32767]*4),
           ('random_seed_1_max',max_samples,[16384,-8192,4096,-2048,1024,-512,256,-128]),
           ('random_seed_42',other_samples,[other.randint(-32768,32767) for _ in range(8)]),
           ('changed_coefficients',other_samples,[-16384,8192,0,0,0,0,0,0])]
    results=[]; passed=False
    try:
        assert service.capabilities()['modes']['rtl']['available'],'RTL tools unavailable'
        for name,samples,coefficients in cases:
            csv_data='sample\n'+''.join(f'{value}\n' for value in samples)
            body=b'--b\r\nContent-Disposition: form-data; name="file"; filename="samples.csv"\r\n\r\n'+csv_data.encode()+b'\r\n--b--\r\n'
            code,data=call('/api/v1/datasets',body,'multipart/form-data; boundary=b'); assert code==201,data
            dataset=json.loads(data)
            code,data=call('/api/v1/jobs',json.dumps({'mode':'rtl','dataset_id':dataset['dataset_id'],'coefficients':coefficients}).encode(),'application/json')
            assert code==202,data
            job=json.loads(data)['job_id']; deadline=time.monotonic()+310
            while time.monotonic()<deadline:
                code,data=call('/api/v1/jobs/'+job); assert code==200,data
                status=json.loads(data)
                if status['state'] in ('succeeded','failed','timed_out'): break
                time.sleep(.1)
            assert status['state']=='succeeded',status
            code,data=call('/api/v1/jobs/'+job+'/result'); assert code==200,data
            result=json.loads(data)
            assert result['mode']=='rtl' and result['execution']['engine']=='vivado-xsim'
            assert result['verification']=={'status':'passed','compared_outputs':len(samples),'mismatches':0}
            assert result['input_count']==result['output_count']==len(samples)
            code,download=call('/api/v1/jobs/'+job+'/result.csv'); assert code==200,download
            rows=list(csv.DictReader(io.StringIO(download.decode())))
            assert [int(row['output_raw']) for row in rows]==result['outputs']
            assert [bool(int(row['saturated'])) for row in rows]==result['saturated']
            if name=='both_saturation_signs':
                assert any(flag and value==32767 for flag,value in zip(result['saturated'],result['outputs']))
                assert any(flag and value==-32768 for flag,value in zip(result['saturated'],result['outputs']))
            if name=='negative_shift': assert result['outputs']==[-1]
            if name=='zero_coefficients': assert not any(result['outputs'])
            (output/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
            results.append({'case':name,'job_id':job,'samples':len(samples),'rtl_cycles':result['metrics']['rtl_cycles'],
                            'saturation_count':result['saturation_count'],'execution':result['execution']})
            print(f'PASS: real RTL HTTP case={name} samples={len(samples)} flags/data matched',flush=True)
        # Actual native-process timeout, using a server-side deadline only.
        service.rtl_timeout=.1
        ds=service.upload(b'sample\n1\n')['dataset_id']
        code,data=call('/api/v1/jobs',json.dumps({'mode':'rtl','dataset_id':ds,'coefficients':[0]*8}).encode(),'application/json')
        assert code==202,data
        job=json.loads(data)['job_id']; deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            code,data=call('/api/v1/jobs/'+job); status=json.loads(data)
            if status['state'] in ('succeeded','failed','timed_out'): break
            time.sleep(.05)
        assert status['state']=='timed_out' and status['error']['code']=='EXECUTION_TIMEOUT',status
        code,data=call('/api/v1/jobs/'+job+'/result'); assert code==409
        results.append({'case':'real_rtl_deadline','job_id':job,'state':status['state']})
        print('PASS: real RTL process-tree deadline terminates the job and exposes no partial result',flush=True)
        passed=True
    finally:
        server.shutdown();server.server_close();thread.join();service.close()
        report={'status':'passed' if passed else 'failed','cases':results,'real_rtl_jobs':len(results),
                'matched_outputs':sum(case.get('samples',0) for case in results),
                'scope':'Real loopback HTTP, submitted CSV and coefficients, actual XSim compile/simulation; final case intentionally enforces a 0.1 s native-process deadline'}
        (output/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')


if __name__=='__main__': main()
