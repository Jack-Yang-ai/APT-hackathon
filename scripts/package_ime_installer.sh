#!/bin/zsh
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
(( $# == 1 )) || { print -u2 '用法：scripts/package_ime_installer.sh 输出目录'; exit 2; }
apt_installer="$apt_repo/mac/ime/安装 APT 输入法.app"
python3 "$apt_repo/scripts/ime_installer_manifest.py" --check "$apt_installer/Contents/Resources"
"$apt_installer/Contents/MacOS/APTInstaller" --dry-run
apt_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$apt_installer/Contents/Info.plist")"
apt_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$apt_installer/Contents/Info.plist")"
mkdir -p "$1"
apt_output="$(cd "$1" && pwd)"
apt_name="APT-IME-$apt_version-$apt_build"
[[ ! -e "$apt_output/$apt_name" && ! -e "$apt_output/$apt_name.zip" ]] || { print -u2 '输出目录已有同名产物；选择新的空目录以保全旧包。'; exit 1; }
mkdir "$apt_output/$apt_name"
ditto --norsrc --noextattr "$apt_installer" "$apt_output/$apt_name/安装 APT 输入法.app"
cp "$apt_repo/mac/ime/Installer/安装说明.txt" "$apt_output/$apt_name/安装说明.txt"
cp "$apt_installer/Contents/Resources/ReleaseNotes.md" "$apt_output/$apt_name/CHANGELOG.md"
ditto --norsrc --noextattr -c -k --keepParent "$apt_output/$apt_name" "$apt_output/$apt_name.zip"
cd "$apt_output"
shasum -a 256 "$apt_name.zip" > SHA256SUMS
cat SHA256SUMS
