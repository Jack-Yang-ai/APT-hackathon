#!/usr/bin/env python3
"""Exercise Android FD ownership in a fresh root-only fixture, without opening the App or mic."""
import argparse
import hashlib
import json
import pathlib
import shlex
import subprocess
import tempfile
import uuid
import zipfile

p = argparse.ArgumentParser()
for name in ('adb', 'serial', 'java', 'javac', 'android-jar', 'r8-jar', 'receipt'):
    p.add_argument('--' + name, required=True)
a = p.parse_args()
project = pathlib.Path(__file__).resolve().parents[1]
sources = [project / 'src/cn/apt/rootaudio/PrivateDirectory.java',
           project / 'src/cn/apt/rootaudio/BackScreenLock.java',
           project / 'tests/PrivateDirectoryAndroidTest.java']
base = [a.adb, '-s', a.serial, 'shell', 'su', '0', 'sh', '-c']
def root(command, timeout=10):
    result = subprocess.run(base + [shlex.quote(command)], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Android fixture command failed: ' + str(result.returncode)
                           + '\n' + result.stdout[-2000:] + result.stderr[-2000:])
    return result.stdout.strip()
if root('id -u') != '0':
    raise RuntimeError('existing root access required')
with tempfile.TemporaryDirectory(prefix='apt-android-files-') as temporary:
    host = pathlib.Path(temporary)
    classes, dex = host / 'classes', host / 'dex'
    classes.mkdir(); dex.mkdir()
    subprocess.run([a.javac, '--release', '8', '-classpath', a.android_jar, '-d', str(classes)]
                   + [str(source) for source in sources], check=True)
    subprocess.run([a.java, '-cp', a.r8_jar, 'com.android.tools.r8.D8', '--min-api', '26',
                    '--lib', a.android_jar, '--output', str(dex)]
                   + [str(f) for f in sorted(classes.rglob('*.class'))], check=True)
    jar = host / 'files-test.jar'
    with zipfile.ZipFile(jar, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for item in sorted(dex.glob('*.dex')):
            archive.write(item, item.name)
    digest = hashlib.sha256(jar.read_bytes()).hexdigest()
    identity = uuid.uuid4().hex
    fixture = '/data/local/tmp/apt-fd-check.' + identity
    stage = '/data/local/tmp/apt-fd-stage.' + identity + '.jar'
    created = False
    try:
        subprocess.run([a.adb, '-s', a.serial, 'push', str(jar), stage], check=True, capture_output=True)
        root('mkdir -m 700 ' + shlex.quote(fixture))
        created = True
        device_jar = fixture + '/files-test.jar'
        root('cp ' + shlex.quote(stage) + ' ' + shlex.quote(device_jar)
             + ' && chmod 600 ' + shlex.quote(device_jar))
        if root('sha256sum ' + shlex.quote(device_jar)).split()[0] != digest:
            raise RuntimeError('fixture JAR fingerprint mismatch')
        result = root('CLASSPATH=' + shlex.quote(device_jar)
                      + ' timeout -k 5 55 app_process /system/bin cn.apt.rootaudio.PrivateDirectoryAndroidTest '
                      + shlex.quote(fixture), timeout=65)
        completed = [line for line in result.splitlines() if line.startswith('ANDROID_FILES_OK ')]
        if len(completed) != 1 or ' delta=0 ' not in completed[0]:
            raise RuntimeError('Android FD verification was not completed')
        receipt = {'version': 1, 'test': 'android-files', 'jarSHA256': digest, 'result': completed[0],
                   'sourceSHA256': {source.relative_to(project).as_posix(): hashlib.sha256(source.read_bytes()).hexdigest()
                                    for source in sources}, 'microphoneOpened': False, 'appDataRead': False}
        target = pathlib.Path(a.receipt)
        with target.open('x') as out:
            target.chmod(0o600)
            out.write(json.dumps(receipt, indent=2) + '\n')
        print(completed[0])
    finally:
        # Only this invocation's random fixture and staging file are disposable.
        root('rm -rf ' + (shlex.quote(fixture) + ' ' if created else '') + shlex.quote(stage))
