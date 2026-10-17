#!/bin/zsh
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
apt_engine="$apt_repo/mac/ime/APT.app"
apt_installer="$apt_repo/mac/ime/安装 APT 输入法.app"
python3 "$apt_repo/scripts/ime_package.py" --check "$apt_engine"
codesign --verify --deep --strict "$apt_engine"
rm -rf -- "$apt_installer"
mkdir -p "$apt_installer/Contents/MacOS" "$apt_installer/Contents/Resources/Payload"
ditto "$apt_engine" "$apt_installer/Contents/Resources/Payload/APT.app"
cp "$apt_repo/mac/ime/Brand/APTAppIcon.icns" "$apt_installer/Contents/Resources/"
python3 "$apt_repo/scripts/release_changelog.py" --ime-package "$apt_engine" --copy-to "$apt_installer/Contents/Resources/ReleaseNotes.md"
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx13.0 \
  "$apt_repo/mac/ime/Installer/Sources/InstallerCore.swift" \
  "$apt_repo/mac/ime/Installer/Sources/InputSourceCatalog.swift" \
  "$apt_repo/mac/ime/Installer/Sources/InstallerMain.swift" \
  "$apt_repo/mac/ime/EchoMemoryIME/Sources/InputSource.swift" \
  -framework Cocoa -framework Carbon -framework CryptoKit -o "$apt_installer/Contents/MacOS/APTInstaller"
python3 "$apt_repo/scripts/ime_installer_manifest.py" "$apt_installer/Contents/Resources"
codesign --force --sign - "$apt_installer"
codesign --verify --deep --strict "$apt_installer"
"$apt_installer/Contents/MacOS/APTInstaller" --dry-run
