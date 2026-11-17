"""Unified reference-only CI or full local XSim Web acceptance entry point."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from webapp.rtl_runner import configuration, terminate_tree


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def sources():
    paths=[ROOT/'.gitattributes',ROOT/'scripts/run_web_rtl.ps1',Path(__file__).resolve()]
    for name in ('webapp','web_tests','model','tests'):
        paths += [path for path in (ROOT/name).rglob('*') if path.is_file() and '__pycache__' not in path.parts]
    paths += sorted((ROOT/'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new').glob('*.v'))
    return {path.relative_to(ROOT).as_posix():sha(path) for path in sorted(set(paths))}


def require(value,message):
    if not value: raise ValueError(message)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl',action='store_true')
    parser.add_argument('--vivado-bin')
    args=parser.parse_args()
    if args.rtl:
        config,reason=configuration(args.vivado_bin)
        if config is None: parser.error('Full RTL acceptance requires configured tools: '+str(reason))
    profile='full-rtl' if args.rtl else 'reference-only'
    build=ROOT/'build/web_validation'/profile;build.mkdir(parents=True,exist_ok=True)
    archive=ROOT/'reports/web' if args.rtl else ROOT/'reports/web/reference'
    report={'status':'incomplete','profile':profile,'started_at_utc':datetime.now(timezone.utc).isoformat(),
            'source_sha256':sources(),'steps':[]}
    summary=build/'summary.json'
    def save(): summary.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    save()
    tasks=[('python',[sys.executable,'-m','unittest','discover','-s','tests','-v']),
           ('backend',[sys.executable,'-m','unittest','discover','-s','web_tests','-v']),
           ('selenium',[sys.executable,'web_tests/browser_acceptance.py']+(['--rtl','--vivado-bin',args.vivado_bin] if args.rtl else []))]
    if args.rtl:tasks.append(('rtl',[sys.executable,'web_tests/rtl_acceptance.py','--vivado-bin',args.vivado_bin]))
    try:
        for name,command in tasks:
            print('Web acceptance:',name,flush=True)
            started=time.monotonic()
            options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
            with (build/(name+'.stdout.txt')).open('wb') as stdout,(build/(name+'.stderr.txt')).open('wb') as stderr:
                process=subprocess.Popen(command,cwd=ROOT,stdout=stdout,stderr=stderr,**options)
                try: code=process.wait(timeout=900)
                except subprocess.TimeoutExpired:
                    terminate_tree(process)
                    raise ValueError('Acceptance stage exceeded 900 seconds: '+name)
            report['steps'].append({'name':name,'exit_code':code,'elapsed_seconds':round(time.monotonic()-started,3)})
            save()
            require(code==0,'Stage failed: '+name+'; inspect '+str(build))
        require(report['source_sha256']==sources(),'Source inputs changed during the acceptance run')
        for name,expected in (('python',27),('backend',14),('selenium',14 if args.rtl else 11)):
            log=(build/(name+'.stderr.txt')).read_text(encoding='utf-8',errors='replace')
            match=re.search(r'Ran (\d+) tests? in',log)
            require(match is not None and int(match[1])==expected and re.search(r'^OK\s*$',log,re.M),name+' test count/PASS evidence mismatch')
            report[name+'_tests']=int(match[1])
        browser=json.loads((ROOT/'build/web_e2e/results.json').read_text(encoding='utf-8'))
        require(browser['status']=='passed' and browser['tests']==report['selenium_tests'] and browser['errors']==browser['failures']==0,'Invalid Selenium evidence')
        for name,value in browser['source_sha256'].items():require(sha(ROOT/name)==value,'Selenium source differs: '+name)
        if args.rtl:
            rtl=json.loads((ROOT/'build/web_rtl_acceptance/results.json').read_text(encoding='utf-8'))
            require(rtl['status']=='passed' and len(rtl['cases'])==9 and rtl['matched_outputs']==11353,'Incomplete real RTL matrix')
            for case in rtl['cases']:
                if 'execution' not in case:
                    require(case['case']=='real_rtl_deadline' and case['state']=='timed_out','Unexpected RTL failure')
                    continue
                directory=ROOT/'build/web_rtl_acceptance/state/runs'/case['job_id']
                for name,value in case['execution']['source_sha256'].items():
                    require(sha(directory/'sources'/Path(name).name)==value,'RTL snapshot changed: '+name)
                    require(sha(ROOT/name)==value,'RTL snapshot differs from delivered source: '+name)
                for name,value in case['execution']['artifact_sha256'].items():require(sha(directory/name)==value,'RTL artifact changed: '+name)
            require(sum(row['status']['state']=='succeeded' for row in browser['rtl_jobs'])==3,'Selenium did not complete three real RTL jobs')
            require(sum(row['status']['state']=='timed_out' for row in browser['rtl_jobs'])==1,'Missing Selenium native-process timeout')
            report.update(rtl_http_successful_jobs=8,rtl_http_matched_outputs_and_flags=11353,rtl_http_expected_timeout_jobs=1)
        archive.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/'build/web_e2e/results.json',archive/'selenium_results.json')
        if args.rtl:shutil.copyfile(ROOT/'build/web_rtl_acceptance/results.json',archive/'rtl_acceptance.json')
        for path in build.glob('*.txt'):shutil.copyfile(path,archive/path.name)
        report['report_sha256']={path.name:sha(path) for path in archive.iterdir() if path.is_file() and path.name!='summary.json'}
        report.update(status='passed',finished_at_utc=datetime.now(timezone.utc).isoformat(),
                      scope='Real HTTP and Edge; running-refresh and HTTP/service restart tests use a gated real reference worker. RTL only in full-rtl profile; no board execution.')
        save();shutil.copyfile(summary,archive/'summary.json')
        print(f"PASS: {profile}: {report['python_tests']} model, {report['backend_tests']} backend, {report['selenium_tests']} browser tests"+
              ('; 8 real RTL jobs / 11353 outputs and flags, plus native timeout' if args.rtl else '; Vivado not required'),flush=True)
    except Exception as error:
        report.update(status='failed',error=str(error));save()
        raise


if __name__=='__main__':main()
