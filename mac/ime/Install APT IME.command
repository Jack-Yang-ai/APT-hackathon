#!/bin/zsh
set -eu
apt_repo="$(cd "$(dirname "$0")/../.." && pwd)"
exec zsh "$apt_repo/scripts/install_ime.sh" "$@"
