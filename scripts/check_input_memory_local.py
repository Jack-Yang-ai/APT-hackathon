#!/usr/bin/env python3
"""Real local HTTPS + Echo Swift outbox; temporary CA/database, no phone or model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--echo-root', type=Path, default=Path(__file__).resolve().parents[1] / 'mac/ime',
                        help='Input method module root; defaults to this repository mac/ime')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    echo = args.echo_root.resolve() / 'EchoMemoryIME'
    node = shutil.which('node')
    if not node:
        raise RuntimeError('Node 24+ is required')
    with tempfile.TemporaryDirectory(prefix='growth-input-local-') as temp:
        root = Path(temp)
        cert, key, der = root/'cert.pem', root/'key.pem', root/'ca.der'
        ca, ca_key, csr, extensions = root/'ca.pem', root/'ca-key.pem', root/'cert.csr', root/'extensions.cnf'
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
        def openssl(*parts):
            subprocess.run(['openssl', *map(str,parts)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=GrowthLocalTestCA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',ca_key,'-out',ca)
        openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=localhost','-keyout',key,'-out',csr)
        openssl('x509','-req','-in',csr,'-CA',ca,'-CAkey',ca_key,'-CAcreateserial','-days','1','-extfile',extensions,'-out',cert)
        key.chmod(0o600);ca_key.chmod(0o600)
        openssl('x509','-in',ca,'-outform','der','-out',der)
        with socket.socket() as endpoint:
            endpoint.bind(('127.0.0.1', 0))
            port = endpoint.getsockname()[1]
        env = os.environ.copy()
        for name in list(env):
            if name.startswith(('GROWTH_INPUT_MEMORY_','GROWTH_RECORDING_MEMORY_')) or name in ('GROWTH_CLIENT_TOKEN','GROWTH_PROXY_TOKEN','GROWTH_AGENT_IME_APP'):
                env.pop(name)
        env['GROWTH_CLIENT_TOKEN'] = 'fixture-local-token'
        env['GROWTH_INPUT_MEMORY_TOKEN'] = 'fixture-local-token'
        env['GROWTH_RECORDING_MEMORY_DB'] = str(root/'recording-server/sources.sqlite')
        env['GROWTH_RECORDING_MEMORY_UPSTREAM'] = ''
        env['CFFIXED_USER_HOME'] = str(root/'scratch-home')
        env['NODE_EXTRA_CA_CERTS'] = str(ca)
        origin = f'https://localhost:{port}'
        context = ssl.create_default_context(cafile=str(ca))
        log = (root/'runtime.log').open('w')
        mirror = None
        server = subprocess.Popen([node, str(repo/'mac/input_memory_service.mjs'), '--db', str(root/'replica/sources.sqlite'), '--port', str(port), '--tls-cert', str(cert), '--tls-key', str(key)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            health = None
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError('local service startup failed: ' + (root/'runtime.log').read_text())
                try:
                    request = urllib.request.Request(origin+'/health', headers={'X-Growth-Token':'fixture-local-token'})
                    health = json.load(urllib.request.urlopen(request, context=context, timeout=1))
                    break
                except OSError:
                    time.sleep(.1)
            if not health:
                raise RuntimeError('local HTTPS health timeout')
            parts = ['mac/input_memory_service.mjs', 'mac/input_memory_store.mjs', 'mac/input_memory_agent.mjs', 'mac/input_memory_pull.mjs', 'mac/input_memory_feed.mjs', 'mac/input_memory_release.json', 'mac/recording_memory.mjs', 'worker/src/recording_memory.js', 'worker/migrations/0002_recording_memory.sql', 'worker/src/input_memory.js', 'worker/migrations/0001_input_memory.sql', 'mac/common_agent.mjs']
            fingerprint = hashlib.sha256(b''.join((repo/p).read_bytes() for p in parts)).hexdigest()
            assert health['pid'] == server.pid and health['source_fingerprint'] == fingerprint
            sources = ['AgentModels.swift','VoiceCore.swift','SmartMemory.swift','LocalMemory.swift','MemoryLog.swift','DayDigest.swift','MemoryActivity.swift','GrowthMemorySync.swift','StyleProfile.swift','VoiceRecord.swift','MeetingNotes.swift']
            command = ['swiftc', '-Onone', '-swift-version', '5', '-parse-as-library'] + [str(echo/'Sources'/name) for name in sources]
            command += [str(echo/'Tests/GrowthLocalChecks.swift'), '-framework', 'Security', '-o', str(root/'echo-local-check')]
            compiled = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if compiled.returncode:
                raise RuntimeError(compiled.stdout)
            subprocess.run([str(root/'echo-local-check'), origin, str(der)], env=env, check=True, timeout=60)
            with socket.socket() as endpoint:
                endpoint.bind(('127.0.0.1',0)); mirror_port=endpoint.getsockname()[1]
            mirror_origin=f'https://localhost:{mirror_port}'
            env['GROWTH_RECORDING_MEMORY_DB'] = str(root/'recording-mirror/sources.sqlite')
            mirror=subprocess.Popen([node,str(repo/'mac/input_memory_service.mjs'),'--db',str(root/'mirror/sources.sqlite'),'--port',str(mirror_port),'--tls-cert',str(cert),'--tls-key',str(key),'--upstream',origin],env=env,stdout=log,stderr=subprocess.STDOUT)
            for _ in range(100):
                if mirror.poll() is not None: raise RuntimeError('mirror startup failed')
                try:
                    request=urllib.request.Request(mirror_origin+'/health',headers={'X-Growth-Token':'fixture-local-token'})
                    active=json.load(urllib.request.urlopen(request,context=context,timeout=1));break
                except OSError: time.sleep(.1)
            assert active['pid']==mirror.pid and active['source_fingerprint']==fingerprint
            def post(base,route,value):
                request=urllib.request.Request(base+route,data=json.dumps(value).encode(),headers={'X-Growth-Token':'fixture-local-token','Content-Type':'application/json'})
                try:
                    with urllib.request.urlopen(request,context=context,timeout=25) as response: return response.status,json.load(response)
                except urllib.error.HTTPError as error: return error.code,json.load(error)
            status,materials=post(mirror_origin,'/input-memory/context',{'query':'本地后端验证'})
            assert status==200 and len(materials['sources'])==2
            source=dict(materials['sources'][0]['record']); source.update(revision=source['revision']+1,deleted=True,text='',pasted=[],voiced=[],updated=(datetime.now(timezone.utc)+timedelta(seconds=5)).isoformat().replace('+00:00','Z'))
            assert post(origin,'/input-memory/sync',{'schema':'growth.input-memory.batch/1','device_id':source['device_id'],'records':[source]})[0]==200
            assert post(mirror_origin,'/input-memory/validate',{'snapshots':materials['snapshots']})[0]==409
            assert len(post(mirror_origin,'/input-memory/context',{'query':'本地后端验证'})[1]['sources'])==1
            print('PASS: live source-service → Mac pull/cursor → Agent context/validation; remote deletion invalidates snapshots')
            print('PASS: temporary Mac service pid, active source fingerprint, TLS hostname/CA trust and real Echo receipt path verified')
        finally:
            for process in [mirror,server]:
                if process is None: continue
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill();process.wait()
            log.close()


if __name__ == '__main__':
    main()
