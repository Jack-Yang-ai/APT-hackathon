#!/usr/bin/env python3
"""Install a verified dex runtime and start the idle controller, never a recording.

The APK, its private database and all old media remain in place. No boot hook.
"""
import argparse
import hashlib
import json
import pathlib
import shlex
import subprocess
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument('--adb', required=True)
p.add_argument('--serial', required=True)
p.add_argument('--jar', required=True)
p.add_argument('--receipt', required=True)
p.add_argument('--service', choices=['recorder', 'backscreen'], default='recorder')
p.add_argument('--backscreen-validation', action='store_true')
p.add_argument('--validation-seconds', type=int)
p.add_argument('--validation-chunk', type=int, default=10)
a = p.parse_args()
if a.service == 'backscreen' and a.validation_seconds is not None: p.error('backscreen does not capture audio')
if a.backscreen_validation and a.service != 'backscreen': p.error('backscreen validation requires --service backscreen')
if a.validation_seconds is not None and not (12 <= a.validation_seconds <= 43200 and 5 <= a.validation_chunk <= 600):
    p.error('invalid validation bounds')
jar = pathlib.Path(a.jar)
expected = hashlib.sha256(jar.read_bytes()).hexdigest()
base = [a.adb, '-s', a.serial]
def root(command):
    return subprocess.run(base + ['shell', 'su', '0', 'sh', '-c', shlex.quote(command)],
                          check=True, capture_output=True, text=True).stdout.strip()
if root('id -u') != '0': raise RuntimeError('root unavailable')
identity = uuid.uuid4().hex
directory = '/data/local/tmp/apt-root-runtime.' + identity
stage = '/data/local/tmp/apt-root-stage.' + identity + '.jar'
subprocess.run(base + ['push', str(jar), stage], check=True, capture_output=True)
root('mkdir -m 700 ' + shlex.quote(directory))
root('cp ' + shlex.quote(stage) + ' ' + shlex.quote(directory + '/recorder.jar') +
     ' && chmod 600 ' + shlex.quote(directory + '/recorder.jar'))
actual = root('sha256sum ' + shlex.quote(directory + '/recorder.jar')).split()[0]
if actual != expected: raise RuntimeError('device runtime SHA mismatch')
root('rm ' + shlex.quote(stage))
arguments = [] if a.validation_seconds is None else ['--validation', str(a.validation_seconds), str(a.validation_chunk)]
controller = 'RootController' if a.service == 'recorder' else 'BackScreenController'
command = ['app_process', '/system/bin', 'cn.apt.rootaudio.' + controller] + arguments
if a.backscreen_validation: command.append('--validation')
pid = root('CLASSPATH=' + shlex.quote(directory + '/recorder.jar') + ' nohup ' + shlex.join(command) +
           ' >' + shlex.quote(directory + '/controller.log') + ' 2>&1 </dev/null & echo $!')
ready = 'CONTROLLER_READY' if a.service == 'recorder' else 'BACKSCREEN_READY'
for attempt in range(40):
    log = root('cat ' + shlex.quote(directory + '/controller.log'))
    if ready in log: break
    if '_FAILED' in log: raise RuntimeError('controller startup failed; inspect private log in ' + directory)
    time.sleep(0.25)
else: raise RuntimeError('controller readiness not confirmed in ' + directory)
receipt = {'version': 1, 'service': a.service, 'ready': True, 'directory': directory, 'pid': int(pid), 'jarSHA256': actual,
           'validation': a.validation_seconds is not None or a.backscreen_validation, 'package': 'com.stepx.aiapp.publicapt'}
path = pathlib.Path(a.receipt); path.write_text(json.dumps(receipt, indent=2) + '\n'); path.chmod(0o600)
print(json.dumps(receipt))
