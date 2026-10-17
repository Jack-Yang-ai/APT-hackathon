#!/usr/bin/env python3
"""Build-time sealed payload manifest. The downloaded installer needs no Python."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys
from ime_package import source_fingerprint

repo = Path(__file__).resolve().parents[1]
checking = sys.argv[1] == '--check'
resources = Path(sys.argv[2] if checking else sys.argv[1])
payload = resources / 'Payload/APT.app'
info = plistlib.loads((payload / 'Contents/Info.plist').read_bytes())
if info.get('APTSourceFingerprint') != source_fingerprint(repo / 'mac/ime'):
    raise SystemExit('安装器内输入法与当前源码不符；请重新构建输入法和安装器。')
files = {}
for path in sorted(payload.rglob('*')):
    relative = path.relative_to(payload).as_posix()
    if path.is_symlink():
        target = path.readlink()
        if target.is_absolute() or not path.resolve().is_relative_to(payload.resolve()):
            raise SystemExit(f'越界链接：{relative}')
        files[relative] = 'link:' + str(target)
    elif path.is_file():
        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
inputs = sorted((repo / 'mac/ime/Installer/Sources').glob('*.swift')) + [
    repo / 'mac/ime/EchoMemoryIME/Sources/InputSource.swift',
    repo / 'scripts/build_ime_installer.sh', Path(__file__).resolve(),
]
digest = hashlib.sha256()
for path in inputs:
    digest.update(path.relative_to(repo).as_posix().encode() + b'\0' + path.read_bytes() + b'\0')
value = {
    'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
    'sourceFingerprint': info['APTSourceFingerprint'], 'installerFingerprint': digest.hexdigest(), 'files': files,
}
plist = {
    'CFBundleExecutable': 'APTInstaller', 'CFBundleIdentifier': 'local.apt.inputmethod.installer',
    'CFBundleName': '安装 APT 输入法', 'CFBundleDisplayName': '安装 APT 输入法',
    'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'APTAppIcon.icns',
    'CFBundleShortVersionString': value['version'], 'CFBundleVersion': value['build'],
    'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication', 'APTInstallerFingerprint': value['installerFingerprint'],
}
if checking:
    if json.loads((resources / 'PayloadManifest.json').read_text()) != value or plistlib.loads((resources.parent / 'Info.plist').read_bytes()) != plist:
        raise SystemExit('图形安装器与当前源码／文件清单不符；请重新运行 scripts/build_ime_installer.sh。')
else:
    (resources / 'PayloadManifest.json').write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps(plist))
print(f"图形安装器{'校验通过' if checking else ''}：{value['version']} / {value['build']} · {value['installerFingerprint']}")
