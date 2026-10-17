#!/usr/bin/env python3
"""Verify the registered process, release, loaded code and source-feed readiness without printing content."""
import argparse
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LABEL = 'com.growth.input-memory'


def verify(health, release, fingerprint, pid, command, cwd, database, upstream):
    if (health.get('schema') != 'growth.input-memory.service/1'
            or health.get('pid') != pid or health.get('source') != str(ROOT / 'mac/input_memory_service.mjs')
            or health.get('working_directory') != str(ROOT) or cwd != str(ROOT)
            or str(ROOT / 'mac/input_memory_service.mjs') not in command.split()):
        raise ValueError('registered process/source/cwd mismatch')
    if health.get('source_fingerprint') != fingerprint:
        raise ValueError('running old source')
    if any(health.get(k) != v for k, v in release.items()):
        raise ValueError('running release mismatch')
    if health.get('database') != str(database):
        raise ValueError('running database mismatch')
    if health.get('agent', {}).get('ready') is not True:
        raise ValueError('common Agent host not ready')
    sync = health.get('synchronization', {})
    expected = 'upstream' if upstream else 'direct'
    if sync.get('mode') != expected or (upstream and sync.get('origin') != upstream.rstrip('/')):
        raise ValueError('running upstream configuration mismatch')
    if not sync.get('ready'):
        raise ValueError('source feed not ready: ' + str(sync.get('state')))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', required=True)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    token = (os.environ.get('GROWTH_INPUT_MEMORY_TOKEN') or os.environ.get('GROWTH_CLIENT_TOKEN')
             or os.environ.get('GROWTH_PROXY_TOKEN'))
    if not token:
        raise SystemExit('input-memory token missing; configure the external env file')
    host = os.environ.get('GROWTH_INPUT_MEMORY_HOST', '127.0.0.1')
    if ':' in host:
        host = '[' + host + ']'
    port = os.environ.get('GROWTH_INPUT_MEMORY_PORT', '18791')
    tls = bool(os.environ.get('GROWTH_INPUT_MEMORY_TLS_CERT'))
    origin = ('https' if tls else 'http') + '://' + host + ':' + port
    context = ssl.create_default_context(cafile=os.environ.get('GROWTH_INPUT_MEMORY_TLS_CA')) if tls else None
    request = urllib.request.Request(origin + '/health', headers={'X-Growth-Token': token})
    try:
        health = json.load(urllib.request.urlopen(request, timeout=5, context=context))
        registered = subprocess.check_output(['launchctl', 'print', f'gui/{os.getuid()}/{LABEL}'], text=True)
        match = re.search(r'\bpid = (\d+)', registered)
        if not match:
            raise ValueError('registered service has no running pid')
        pid = int(match.group(1))
        command = subprocess.check_output(['ps', '-ww', '-p', str(pid), '-o', 'args='], text=True).strip()
        cwd = subprocess.check_output(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], text=True)
        cwd = next((line[1:] for line in cwd.splitlines() if line.startswith('n')), '')
        module = str(ROOT / 'mac/input_memory_service.mjs')
        fingerprint = subprocess.check_output([args.node, '--input-type=module', '-e',
            'import {pathToFileURL} from "node:url"; const m=await import(pathToFileURL(process.argv[1])); process.stdout.write(m.sourceFingerprint());', module], text=True).strip()
        release = json.loads((ROOT / 'mac/input_memory_release.json').read_text())
        database = Path(os.environ.get('GROWTH_INPUT_MEMORY_DB', str(Path.home() / 'Library/Application Support/GrowthApp/InputMemory/sources.sqlite'))).resolve()
        verify(health, release, fingerprint, pid, command, cwd, database, os.environ.get('GROWTH_INPUT_MEMORY_UPSTREAM'))
        recording_upstream = os.environ.get('GROWTH_RECORDING_MEMORY_UPSTREAM', os.environ.get('GROWTH_INPUT_MEMORY_UPSTREAM'))
        if recording_upstream:
            recordings = health.get('recordings', {})
            recording_db = Path(os.environ.get('GROWTH_RECORDING_MEMORY_DB', str(Path.home() / 'Library/Application Support/GrowthApp/RecordingMemory/sources.sqlite'))).resolve()
            if (recordings.get('origin') != recording_upstream.rstrip('/') or recordings.get('ready') is not True
                    or health.get('recording_database') != str(recording_db)):
                raise ValueError('recording source feed/database not ready or mismatched')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        # Never include response bodies, subprocess command lines or environment values in errors.
        message = str(error) if type(error) is ValueError else type(error).__name__
        raise SystemExit('input-memory status failed: ' + message)
    if args.receipt:
        receipt = {**health, 'git_commit': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()}
        args.receipt.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
        args.receipt.chmod(0o600)
    if args.json:
        print(json.dumps(health, ensure_ascii=False))
    else:
        state = health['synchronization']
        print(f"input-memory {health['version']} / {health['build']} running, pid {pid}, source {fingerprint[:12]}, feed {state['state']}, sources {health['coverage']['sources']}")


if __name__ == '__main__':
    main()
