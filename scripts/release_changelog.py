#!/usr/bin/env python3
"""Require version-specific notes before installing a Mac release; archive them with its receipt."""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def notes_for(text, component, version, build):
    marker = f'<!-- release: {component} {version} {build} -->'
    sections = re.split(r'(?m)(?=^## )', text)
    matches = [section for section in sections if marker in section]
    if len(matches) != 1:
        raise ValueError(f'CHANGELOG.md 须有唯一版本记录：{component} {version} / {build}')
    section = matches[0]
    for label in ('变更', '验证', '限制'):
        if not re.search(rf'(?m)^- {label}：\S.+', section):
            raise ValueError(f'版本记录缺少{label}：{component} {version} / {build}')
    return section.strip() + '\n'


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--ime-package', type=Path)
    source.add_argument('--input-memory', action='store_true')
    parser.add_argument('--copy-to', type=Path)
    args = parser.parse_args()
    if args.ime_package:
        info = plistlib.loads((args.ime_package / 'Contents/Info.plist').read_bytes())
        identity = ('ime', info['CFBundleShortVersionString'], info['CFBundleVersion'])
    else:
        release = json.loads((ROOT / 'mac/input_memory_release.json').read_text())
        identity = (release['component'], release['version'], release['build'])
    try:
        notes = notes_for((ROOT / 'CHANGELOG.md').read_text(), *identity)
    except (ValueError, FileNotFoundError) as error:
        raise SystemExit(str(error))
    if args.copy_to:
        args.copy_to.write_text(notes)
        args.copy_to.chmod(0o600)
    print(f'changelog 已核：{identity[0]} {identity[1]} / {identity[2]}')


if __name__ == '__main__':
    main()
