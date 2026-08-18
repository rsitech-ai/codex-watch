#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 [--purge-data]"
  exit 64
}

[[ $# -eq 0 || ( $# -eq 1 && "$1" == "--purge-data" ) ]] || usage
bridge="${CODEX_WATCH_BRIDGE_EXECUTABLE:-$HOME/Library/Application Support/CodexWatch/Service/CodexWatch.app/Contents/MacOS/codex-watch-bridge}"
[[ -x "$bridge" ]] || { print -u2 "installed bridge executable not found"; exit 66; }

exec "$bridge" uninstall "$@"
