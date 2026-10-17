#!/usr/bin/env python3
"""Stamp the actual input method build inputs, independent of checkout location."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import subprocess
import sys


def source_fingerprint(module: Path) -> str:
    paths = [module / 'build.sh', module / 'EchoMemoryIME/build.sh']
    for name in ['Sources', 'Tests', 'Resources', 'Data', 'Vendor']:
        paths.extend(p for p in (module / 'EchoMemoryIME' / name).rglob('*')
                     if (p.is_file() or p.is_symlink()) and '__pycache__' not in p.parts)
    paths.extend(p for p in (module / 'Brand').rglob('*') if p.is_file())
    digest = hashlib.sha256()
    digest.update(Path(__file__).read_bytes())
    for path in sorted(paths):
        digest.update(path.relative_to(module).as_posix().encode() + b'\0')
        digest.update(path.read_bytes())
        digest.update(b'\0')
    return digest.hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    module = Path(__file__).resolve().parents[1] / 'mac/ime'
    plist = args.package / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    fingerprint = source_fingerprint(module)
    if args.check:
        mode_id = 'local.echo.inputmethod.memory.hans'
        mode = info.get('ComponentInputModeDict', {}).get('tsInputModeListKey', {}).get(mode_id, {})
        if (info.get('APTSourceFingerprint') != fingerprint
                or info.get('CFBundleDisplayName') != 'APT 输入法'
                or info.get('CFBundleExecutable') != 'APT'
                or info.get('CFBundleIdentifier') != 'local.echo.inputmethod.memory'
                or info.get('TISInputSourceID') != 'local.echo.inputmethod.memory'
                or info.get('InputMethodConnectionName') != 'local.echo.inputmethod.memory_Connection'
                or info.get('InputMethodServerControllerClass') != 'EchoInputController'
                or mode.get('TISInputSourceID') != mode_id
                or mode.get('TISIntendedLanguage') != 'zh-Hans'
                or mode.get('tsInputModeIsVisibleKey') is not True
                or mode.get('tsInputModeDefaultStateKey') is not True
                or info.get('ComponentInputModeDict', {}).get('tsVisibleInputModeOrderedArrayKey') != [mode_id]):
            raise SystemExit('构建包与当前源码不符；先运行 scripts/build_ime.sh')
        localization_paths = ['InfoPlist.strings'] + [
            f'{language}.lproj/{name}.strings' for language in ['en', 'zh-Hans']
            for name in ['InfoPlist', 'Localizable']]
        for relative in localization_paths:
            strings = args.package / 'Contents/Resources' / relative
            result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(strings)],
                                    check=True, capture_output=True)
            localized = json.loads(result.stdout)
            if any(localized.get(key) != 'APT 输入法' for key in [
                    'CFBundleName', 'CFBundleDisplayName', 'local.echo.inputmethod.memory', mode_id]):
                raise SystemExit(f'输入源显示名不完整：{relative}')
        print('APT 输入法包与当前源码指纹一致')
    else:
        info['APTSourceFingerprint'] = fingerprint
        plist.write_bytes(plistlib.dumps(info))
