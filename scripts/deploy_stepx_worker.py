#!/usr/bin/env python3
"""Deploy only the StepX route, then verify its source and the untouched native Worker."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BASE = 'https://apt-backend.example'

def gate():
    token = os.environ.get('GROWTH_CLIENT_TOKEN', '')
    if not token:
        for line in (Path.home() / '.config/growth-agent/secrets.env').read_text().splitlines():
            text = line.removeprefix('export ').strip()
            if text.startswith('GROWTH_CLIENT_TOKEN='):
                words = shlex.split(text.partition('=')[2], comments=True)
                if len(words) == 1:
                    token = words[0]
                break
    if not token:
        raise SystemExit('Growth gate not configured')
    return token

def request(path, token):
    req = urllib.request.Request(BASE + path, headers={'X-Growth-Token': token, 'User-Agent': 'growth-stepx-deploy/1.0'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)

def main():
    # 公开快照不发布 wrangler.toml 与 .deployed.json：前者是运营部署配置，后者是
    # 上一版部署回执。缺回执不等于线上是新环境：必须显式声明首次部署，或给出
    # 预期的线上指纹，否则中止，不伪造原回执。
    paths = ['stepx-worker/src', 'worker/src/collector.js', 'worker/src/stepx_audio.js', 'scripts/deploy_stepx_worker.py',
             'stepx-client/src/growth/processing-data.ts', 'stepx-client/src/growth/source-scope.ts',
             'stepx-client/src/growth/quote-normalize.ts', 'stepx-client/src/growth/personal-action-data.ts',
             'stepx-client/src/growth/recording-memory-data.ts']
    dirty = subprocess.check_output(['git', 'status', '--porcelain', '--', *paths], cwd=ROOT, text=True)
    if dirty:
        raise SystemExit('Commit the StepX deployment inputs first')
    blobs = [subprocess.check_output(['git', 'rev-parse', 'HEAD:' + path], cwd=ROOT).strip() for path in paths]
    source = hashlib.sha256(b'\n'.join(blobs)).hexdigest()
    token = gate()
    receipt = ROOT / 'stepx-worker/.deployed.json'
    if receipt.is_file():
        expected = json.loads(receipt.read_text()).get('source')
        if not expected or request('/stepx/version', token).get('source') != expected:
            raise SystemExit('StepX deployment changed; preserve the newer bridge and its receipt before publishing')
    elif os.environ.get('STEPX_EXPECTED_SOURCE'):
        if request('/stepx/version', token).get('source') != os.environ['STEPX_EXPECTED_SOURCE']:
            raise SystemExit('StepX deployment differs from STEPX_EXPECTED_SOURCE; preserve the newer bridge before publishing')
    elif os.environ.get('STEPX_FIRST_DEPLOY') == '1':
        print('首次部署：已由 STEPX_FIRST_DEPLOY=1 显式确认，跳过线上漂移对撞。')
    else:
        raise SystemExit('缺少部署回执 stepx-worker/.deployed.json：已有线上部署请设 STEPX_EXPECTED_SOURCE=<线上 source 指纹>，确属首次部署请设 STEPX_FIRST_DEPLOY=1')
    native_before = request('/version', token)
    cli = ['npx', '--yes', 'wrangler@4.120.0']
    subprocess.run([*cli, 'deploy', '--var', 'STEPX_SRC_SHA:' + source], cwd=ROOT / 'stepx-worker', check=True)
    result = subprocess.run([*cli, 'secret', 'put', 'GROWTH_CLIENT_TOKEN'], cwd=ROOT / 'stepx-worker',
                            input=token + '\n', text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Could not configure the StepX gate secret; route remains closed')
    for attempt in range(3):
        try:
            deployed = request('/stepx/version', token)
            health = request('/stepx/health', token)
            break
        except urllib.error.HTTPError as error:
            if error.code not in (502, 503) or attempt == 2:
                raise SystemExit('StepX endpoint verification failed; no receipt written')
            time.sleep(3)
    native_after = request('/version', token)
    if deployed.get('source') != source or native_after != native_before or health.get('ok') is not True:
        raise SystemExit('Deployment verification failed; no receipt written')
    receipt = {'source': source, 'nativeSource': native_after.get('src_sha'), 'health': health}
    (ROOT / 'stepx-worker/.deployed.json').write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    print('StepX source verified:', source)
    print('Original native Worker source unchanged:', native_after.get('src_sha'))
    print('Configured:', {key: health[key] for key in ('chatConfigured', 'asrConfigured', 'extractionQueueConfigured')})

if __name__ == '__main__':
    main()
