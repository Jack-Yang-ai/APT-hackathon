#!/usr/bin/env python3
"""Run the real Java upload-key cross-language regression; no Android, microphone or user data."""
import argparse
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--java', default='java')
parser.add_argument('--javac', default='javac')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='apt-upload-identity-') as temporary:
    subprocess.run([args.javac, '--release', '8', '-d', temporary,
                    str(root / 'src/cn/apt/rootaudio/RootUploadIdentity.java'),
                    str(root / 'tests/RootUploadIdentityTest.java')], check=True)
    subprocess.run([args.java, '-cp', temporary, 'cn.apt.rootaudio.RootUploadIdentityTest'], check=True)
