#!/bin/zsh
set -euo pipefail

# Build the Voice Inbox Bridge app and optionally open it.
# Does not boot out or kill the LaunchAgent listener.

usage() {
  print -u2 "usage: $0 [--verify]"
  exit 64
}

verify=0
if [[ $# -eq 1 && "$1" == "--verify" ]]; then
  verify=1
elif [[ $# -ne 0 ]]; then
  usage
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$(mktemp -d /private/tmp/voice-inbox-bridge-app.XXXXXX)"
"$repo_root/Scripts/build-bridge-app.sh" --output "$output"
app="$output/VoiceInboxBridge.app"
background_only="$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$app/Contents/Info.plist")"
[[ "$background_only" == "false" ]] || {
  print -u2 "expected LSBackgroundOnly=false, got $background_only"
  exit 1
}

if [[ "$verify" -eq 1 ]]; then
  print "built $app"
  exit 0
fi

open "$app"
print "opened $app"
