#!/usr/bin/env python3
"""Encode a supplied synthetic fixture in an isolated Android directory; never opens a microphone."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import uuid
import wave
import zipfile

p = argparse.ArgumentParser()
for name in ('adb', 'serial', 'java', 'javac', 'android-jar', 'r8-jar', 'input', 'output'):
    p.add_argument('--' + name, required=True)
a = p.parse_args()
project = Path(__file__).resolve().parents[1]
out = Path(a.output)
out.mkdir(mode=0o700, parents=True, exist_ok=False)
fixture = '/data/local/tmp/apt-aac-check.' + uuid.uuid4().hex
stage = fixture + '.jar'
base = [a.adb, '-s', a.serial]


def root(command, timeout=15):
    result = subprocess.run(base + ['shell', 'su', '0', 'sh', '-c', shlex.quote(command)],
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Isolated AAC test failed (' + str(result.returncode) + '): ' + result.stdout[-2000:] + result.stderr[-1000:])
    return result.stdout


created = False
with tempfile.TemporaryDirectory(prefix='apt-aac-build-') as temporary:
    host = Path(temporary)
    classes, dex = host / 'classes', host / 'dex'
    classes.mkdir(); dex.mkdir()
    sources = sorted((project / 'src').rglob('*.java'))
    sources.append(project / 'tests/AacChunkAndroidTest.java')
    subprocess.run([a.javac, '--release', '8', '-classpath', a.android_jar, '-d', str(classes)] + list(map(str, sources)), check=True)
    subprocess.run([a.java, '-cp', a.r8_jar, 'com.android.tools.r8.D8', '--min-api', '26', '--lib', a.android_jar,
                    '--output', str(dex)] + list(map(str, sorted(classes.rglob('*.class')))), check=True)
    jar = host / 'test.jar'
    with zipfile.ZipFile(jar, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for item in sorted(dex.glob('*.dex')):
            archive.write(item, item.name)
    # Canonicalize only the explicitly supplied test fixture to a 44-byte PCM header.
    with wave.open(a.input, 'rb') as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000) or not 0 < audio.getnframes() <= 600 * 16000:
            raise ValueError('Test fixture must be 16k mono PCM16, at most 600 seconds')
        with wave.open(str(host / 'input.wav'), 'wb') as target:
            target.setparams(audio.getparams()); target.writeframes(audio.readframes(audio.getnframes()))
    try:
        if root('id -u').strip() != '0':
            raise RuntimeError('Existing root access required')
        root('mkdir -m 700 ' + shlex.quote(fixture)); created = True
        subprocess.run(base + ['push', str(jar), stage], check=True, capture_output=True)
        root('cp ' + shlex.quote(stage) + ' ' + shlex.quote(fixture + '/test.jar') + ' && chmod 600 ' + shlex.quote(fixture + '/test.jar'))
        # adb shell cannot traverse root-private directories; stage the synthetic PCM first.
        subprocess.run(base + ['push', str(host / 'input.wav'), fixture + '.wav'], check=True, capture_output=True)
        root('mv ' + shlex.quote(fixture + '.wav') + ' ' + shlex.quote(fixture + '/input.wav'))
        result = root('CLASSPATH=' + shlex.quote(fixture + '/test.jar') + ' timeout -k 5 55 app_process /system/bin cn.apt.rootaudio.AacChunkAndroidTest '
                      + shlex.quote(fixture), timeout=60)
        lines = [line for line in result.splitlines() if line.startswith('AAC_TEST_OK ')]
        if len(lines) != 1:
            raise RuntimeError('AAC test did not complete: ' + result[-2000:])
        for index, name in ((0, 'android-speech.m4a'), (1, 'android-600s.m4a')):
            # Only generated synthetic outputs leave the isolated fixture.
            data = subprocess.run(base + ['exec-out', 'su', '0', 'cat', fixture + f'/chunk-{index:04d}.m4a'], check=True, capture_output=True).stdout
            target = out / name
            with target.open('xb') as output:
                target.chmod(0o600); output.write(data)
        receipt = json.loads(lines[0].removeprefix('AAC_TEST_OK '))
        receipt['jarSHA256'] = hashlib.sha256(jar.read_bytes()).hexdigest()
        receipt['sources'] = {str(source.relative_to(project)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources}
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt))
    finally:
        root('rm -rf ' + (shlex.quote(fixture) + ' ' if created else '') + shlex.quote(stage) + ' ' + shlex.quote(fixture + '.wav'))
