#!/bin/bash
# Manage only the input-source replica; keep recordings, templates and other consumers intact.
set -euo pipefail
MEMORY_REPO="$(cd "$(dirname "$0")/.." && pwd)"
MEMORY_LABEL=com.growth.input-memory
MEMORY_ENV="${GROWTH_INPUT_MEMORY_ENV_FILE:-$HOME/.config/growth-agent/secrets.env}"
MEMORY_CONFIG="${GROWTH_INPUT_MEMORY_CONFIG_FILE:-$HOME/.config/apt/input-memory.env}"
MEMORY_PLIST="$HOME/Library/LaunchAgents/$MEMORY_LABEL.plist"
MEMORY_DOMAIN="gui/$(id -u)"
if [ -f "$MEMORY_ENV" ]; then set -a; . "$MEMORY_ENV"; set +a; fi
if [ -f "$MEMORY_CONFIG" ]; then set -a; . "$MEMORY_CONFIG"; set +a; fi
MEMORY_NODE="${GROWTH_INPUT_MEMORY_NODE:-$HOME/.local/bin/node}"
if [ ! -x "$MEMORY_NODE" ]; then MEMORY_NODE="$(command -v node || true)"; fi
[ -n "$MEMORY_NODE" ] && [ -x "$MEMORY_NODE" ] || { echo 'Node 24+ is required' >&2; exit 1; }

memory_status() { python3 "$MEMORY_REPO/scripts/input_memory_status.py" --node "$MEMORY_NODE" "$@"; }
memory_stop() {
  local previous_pid
  previous_pid=$(launchctl print "$MEMORY_DOMAIN/$MEMORY_LABEL" 2>/dev/null | awk '/^[[:space:]]*pid = / {print $3}' || true)
  if launchctl print "$MEMORY_DOMAIN/$MEMORY_LABEL" >/dev/null 2>&1; then
    launchctl bootout "$MEMORY_DOMAIN/$MEMORY_LABEL"
  fi
  if [ -n "$previous_pid" ]; then
    for attempt in $(seq 1 100); do
      if ! kill -0 "$previous_pid" 2>/dev/null; then break; fi
      sleep .1
    done
    if kill -0 "$previous_pid" 2>/dev/null; then echo 'input-memory process still exiting; not starting another instance' >&2; return 1; fi
  fi
  echo 'input-memory stopped; registered startup file, database, cursor and logs retained'
}
memory_start() {
  local receipt_dir status_log
  python3 "$MEMORY_REPO/scripts/release_changelog.py" --input-memory
  [ -f "$MEMORY_PLIST" ] || { echo 'input-memory startup file missing; use install' >&2; return 1; }
  receipt_dir="$HOME/.local/share/apt/input-memory-installations/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$receipt_dir"; chmod 700 "$receipt_dir"
  python3 "$MEMORY_REPO/scripts/release_changelog.py" --input-memory --copy-to "$receipt_dir/changelog.md"
  if ! launchctl print "$MEMORY_DOMAIN/$MEMORY_LABEL" >/dev/null 2>&1; then
    launchctl bootstrap "$MEMORY_DOMAIN" "$MEMORY_PLIST"
  fi
  status_log="$receipt_dir/status.log"
  for attempt in $(seq 1 30); do
    if memory_status --receipt "$receipt_dir/receipt.json" >"$status_log" 2>&1; then
      chmod 600 "$status_log"; cat "$status_log"; echo "receipt: $receipt_dir"; return 0
    fi
    sleep 1
  done
  chmod 600 "$status_log"; cat "$status_log" >&2
  echo 'input-memory registered but verification failed; no successful receipt written' >&2
  return 1
}
case "${1:-status}" in
  run) exec "$MEMORY_NODE" "$MEMORY_REPO/mac/input_memory_service.mjs" ;;
  install)
    python3 "$MEMORY_REPO/scripts/release_changelog.py" --input-memory
    if [ -n "$(git -C "$MEMORY_REPO" status --porcelain -- 'mac/input_memory*.mjs' mac/common_agent.mjs mac/recording_memory.mjs mac/input_memory_release.json 'scripts/input_memory*' scripts/release_changelog.py CHANGELOG.md worker/src/input_memory.js worker/src/recording_memory.js worker/migrations/0001_input_memory.sql worker/migrations/0002_recording_memory.sql)" ]; then
      echo 'input-memory release has uncommitted inputs; commit them before installation' >&2; exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/growth"
    if [ -f "$MEMORY_PLIST" ]; then
      MEMORY_BACKUP="$HOME/.local/share/apt/input-memory-installations/previous-$(date +%Y%m%d-%H%M%S)-$$"
      mkdir -p "$MEMORY_BACKUP"; chmod 700 "$MEMORY_BACKUP"; cp -p "$MEMORY_PLIST" "$MEMORY_BACKUP/agent.plist"
    fi
    memory_stop
    python3 - "$MEMORY_REPO" "$MEMORY_ENV" "$MEMORY_CONFIG" "$MEMORY_NODE" "$MEMORY_PLIST" <<'PLIST'
import os, pathlib, plistlib, sys
repo, env, config, node, dest = sys.argv[1:]
logs = pathlib.Path.home()/'Library/Logs/growth/com.growth.input-memory.log'
value = {'Label':'com.growth.input-memory','ProgramArguments':['/bin/bash',repo+'/scripts/input_memory_daemon.sh','run'],
 'WorkingDirectory':repo,'EnvironmentVariables':{'GROWTH_INPUT_MEMORY_ENV_FILE':env,'GROWTH_INPUT_MEMORY_CONFIG_FILE':config,'GROWTH_INPUT_MEMORY_NODE':node},
 'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':10,'StandardOutPath':str(logs),'StandardErrorPath':str(logs)}
pathlib.Path(dest).write_bytes(plistlib.dumps(value));os.chmod(dest,0o600)
PLIST
    memory_start ;;
  status) shift || true; memory_status "$@" ;;
  stop) memory_stop ;;
  start) memory_start ;;
  restart) memory_stop; memory_start ;;
  uninstall)
    memory_stop; rm -f "$MEMORY_PLIST"
    echo 'input-memory startup file removed; database, config and logs retained' ;;
  *) echo 'usage: input_memory_daemon.sh run|install|status [--json]|stop|start|restart|uninstall' >&2; exit 2 ;;
esac
