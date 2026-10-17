#!/bin/zsh
# Existing native checks run only in a renamed, unregistered copy and a private data home.
set -eu
apt_repo="$(cd "$(dirname "$0")/.." && pwd)"
apt_package="$apt_repo/mac/ime/APT.app"
[[ -d "$apt_package" ]] || { print -u2 '先运行 scripts/build_ime.sh'; exit 1; }
python3 "$apt_repo/scripts/ime_package.py" --check "$apt_package"
codesign --verify --deep --strict "$apt_package"
apt_scratch="$(mktemp -d "${TMPDIR:-/tmp}/apt-ime-check.XXXXXX")"
trap 'rm -rf "$apt_scratch"' EXIT INT TERM
ditto "$apt_package" "$apt_scratch/APTCheck.app"
plutil -replace CFBundleIdentifier -string scratch.apt.ime.check "$apt_scratch/APTCheck.app/Contents/Info.plist"
codesign --force --sign - "$apt_scratch/APTCheck.app"
mkdir -p "$apt_scratch/data-home"
apt_binary="$apt_scratch/APTCheck.app/Contents/MacOS/APT"
apt_checks=(--verify-typing --verify-voice --verify-inline --verify-settings --verify-input-memory --verify-day --verify-style --verify-activity --verify-growth-memory --verify-au05 --verify-meetings --verify-editor)
if (( $# )); then
  apt_checks=("$@")
  for apt_check in "${apt_checks[@]}"; do
    case "$apt_check" in
      --verify-typing|--verify-voice|--verify-inline|--verify-settings|--verify-input-memory|--verify-day|--verify-style|--verify-activity|--verify-growth-memory|--verify-au05|--verify-meetings|--verify-editor|--verify-vectors-live) ;;
      *) print -u2 "不支持的隔离检查：$apt_check"; exit 2 ;;
    esac
  done
fi
for apt_check in "${apt_checks[@]}"; do
  print "APT 输入法检查：$apt_check"
  CFFIXED_USER_HOME="$apt_scratch/data-home" "$apt_binary" "$apt_check"
  if [[ "$apt_check" == --verify-typing ]]; then
    CFFIXED_USER_HOME="$apt_scratch/data-home" "$apt_binary" --verify-typing --reload
  fi
done
apt_sources="$apt_repo/mac/ime/EchoMemoryIME"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$apt_sources/Sources/SmartMemory.swift" "$apt_sources/Sources/AgentModels.swift" "$apt_sources/Sources/VoiceCore.swift" "$apt_sources/Sources/LocalMemory.swift" \
  "$apt_sources/Sources/MemoryLog.swift" "$apt_sources/Sources/DayDigest.swift" \
  "$apt_sources/Sources/MemoryActivity.swift" "$apt_sources/Sources/GrowthMemorySync.swift" \
  "$apt_sources/Sources/StyleProfile.swift" "$apt_sources/Sources/VoiceRecord.swift" \
  "$apt_sources/Sources/MeetingNotes.swift" "$apt_sources/Tests/SmartMemoryTests.swift" \
  -framework Security -o "$apt_scratch/memory-tests"
CFFIXED_USER_HOME="$apt_scratch/data-home" "$apt_scratch/memory-tests"
python3 "$apt_repo/scripts/test_agent_host_cancel.py" "$apt_binary"
print 'APT 输入法隔离检查通过'
