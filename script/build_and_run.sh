#!/usr/bin/env zsh
set -euo pipefail

# Verify the Codex Watch Mac app bundle. Does not open a /tmp build and does
# not boot out or kill the LaunchAgent listener.

usage() {
  print -u2 "usage: $0 [--verify]"
  print -u2 "build only; open the installed Application Support app after install"
  exit 64
}

if [[ $# -eq 1 && "$1" == "--verify" ]]; then
  :
elif [[ $# -ne 0 ]]; then
  usage
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$(mktemp -d /private/tmp/codex-watch-bridge-app.XXXXXX)"
"$repo_root/Scripts/build-bridge-app.sh" --output "$output"
app="$output/CodexWatch.app"
background_only="$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$app/Contents/Info.plist")"
[[ "$background_only" == "false" ]] || {
  print -u2 "expected LSBackgroundOnly=false, got $background_only"
  exit 1
}

print "built $app"
print "install with Scripts/install-bridge.sh; do not run this /tmp build as the companion"
