#!/bin/zsh
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
apt_checks="$(mktemp -d "${TMPDIR:-/tmp}/apt-installer-checks.XXXXXX")"
trap 'rm -rf "$apt_checks"' EXIT INT TERM
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 \
  "$apt_repo/mac/ime/Installer/Sources/InstallerCore.swift" \
  "$apt_repo/mac/ime/Installer/Sources/InputSourceCatalog.swift" \
  "$apt_repo/mac/ime/Installer/Tests/InstallerChecks.swift" \
  "$apt_repo/mac/ime/EchoMemoryIME/Sources/InputSource.swift" \
  -framework Cocoa -framework Carbon -framework CryptoKit -o "$apt_checks/installer-checks"
"$apt_checks/installer-checks"
