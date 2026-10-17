#!/bin/zsh
# Developer entry point; downloaded releases open the graphical installer directly.
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
apt_package="$apt_repo/mac/ime/APT.app"
apt_installer="$apt_repo/mac/ime/安装 APT 输入法.app"
case "${1:-}" in
  '') (( $# == 0 )) || exit 2; apt_action=--install ;;
  --dry-run|--check-installed) (( $# == 1 )) || exit 2; apt_action="$1" ;;
  *) print -u2 '用法：scripts/install_ime.sh [--dry-run|--check-installed]'; exit 2 ;;
esac
python3 "$apt_repo/scripts/ime_package.py" --check "$apt_package"
[[ -x "$apt_installer/Contents/MacOS/APTInstaller" ]] || { print -u2 '先运行 zsh scripts/build_ime_installer.sh'; exit 1; }
apt_engine_fingerprint="$(/usr/libexec/PlistBuddy -c 'Print APTSourceFingerprint' "$apt_package/Contents/Info.plist")"
apt_payload_fingerprint="$(/usr/libexec/PlistBuddy -c 'Print APTSourceFingerprint' "$apt_installer/Contents/Resources/Payload/APT.app/Contents/Info.plist")"
[[ "$apt_engine_fingerprint" == "$apt_payload_fingerprint" ]] || { print -u2 '安装器内的输入法尚未更新；重新运行 scripts/build_ime_installer.sh'; exit 1; }
python3 "$apt_repo/scripts/ime_installer_manifest.py" --check "$apt_installer/Contents/Resources"
exec "$apt_installer/Contents/MacOS/APTInstaller" "$apt_action"
