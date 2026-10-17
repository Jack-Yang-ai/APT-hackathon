#!/bin/zsh
# Compatibility entry; upgrades the same registered input source.
set -eu
exec zsh "$(dirname "$0")/Install APT IME.command" "$@"
