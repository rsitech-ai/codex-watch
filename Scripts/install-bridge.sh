#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 --bundle APP --codex PATH --bind-host HOST --advertised-host HOST"
  exit 64
}

[[ $# -eq 8 ]] || usage
typeset -A bridge_options
while [[ $# -gt 0 ]]; do
  [[ "$1" == --* && -z "${bridge_options[${1#--}]:-}" ]] || usage
  bridge_options[${1#--}]="$2"
  shift 2
done
for required in bundle codex bind-host advertised-host; do
  [[ -n "${bridge_options[$required]:-}" ]] || usage
done
bundle="${bridge_options[bundle]}"
bridge="$bundle/Contents/MacOS/codex-watch-bridge"
[[ "$bundle" = /* && -d "$bundle" && -x "$bridge" ]] || { print -u2 "invalid bridge bundle"; exit 66; }

exec "$bridge" install \
  --bundle "$bundle" \
  --codex "${bridge_options[codex]}" \
  --bind-host "${bridge_options[bind-host]}" \
  --advertised-host "${bridge_options[advertised-host]}"
