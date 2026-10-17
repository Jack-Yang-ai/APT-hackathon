#!/bin/zsh
# Native UI review in an unregistered app and private data home; never installs or changes the input source.
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
apt_package="$apt_repo/mac/ime/APT.app"
apt_output="${1:-$apt_repo/mac/ime/work/ui-review}"
(( $# <= 1 )) || { print -u2 '用法：scripts/preview_ime.sh [输出目录]'; exit 2; }
apt_output="$(python3 - "$apt_output" <<'PY'
from pathlib import Path
import sys
print(Path(sys.argv[1]).expanduser().resolve())
PY
)"
python3 "$apt_repo/scripts/ime_package.py" --check "$apt_package"
codesign --verify --deep --strict "$apt_package"
apt_scratch="$(mktemp -d "${TMPDIR:-/tmp}/apt-ui-review.XXXXXX")"
trap 'rm -rf "$apt_scratch"' EXIT INT TERM
ditto "$apt_package" "$apt_scratch/APT UI Review.app"
plutil -replace CFBundleIdentifier -string scratch.apt.ime.ui-review "$apt_scratch/APT UI Review.app/Contents/Info.plist"
codesign --force --sign - "$apt_scratch/APT UI Review.app"
mkdir -p "$apt_scratch/data-home"
CFFIXED_USER_HOME="$apt_scratch/data-home" "$apt_scratch/APT UI Review.app/Contents/MacOS/APT" --verify-ui-review "$apt_output"
print "APT UI 预览：$apt_output"
