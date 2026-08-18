#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 --output ABSOLUTE_DIRECTORY"
  exit 64
}

[[ $# -eq 2 && "$1" == "--output" ]] || usage
output="$2"
[[ "$output" = /* ]] || usage

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
mkdir -p "$output"
app="$output/CodexWatch.app"
[[ ! -e "$app" ]] || { print -u2 "refusing to overwrite existing bundle: $app"; exit 73; }

scratch="$(mktemp -d /private/tmp/codex-watch-bridge-build.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
swift build --package-path "$repo_root" --scratch-path "$scratch" -c release --product codex-watch-bridge

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
icon="$repo_root/Bridge/AppIcon.icns"
[[ -f "$icon" ]] || { print -u2 "missing Mac app icon: $icon"; exit 66; }
cp "$repo_root/Bridge/Info.plist" "$app/Contents/Info.plist"
cp "$scratch/release/codex-watch-bridge" "$app/Contents/MacOS/codex-watch-bridge"
cp "$icon" "$app/Contents/Resources/AppIcon.icns"
chmod 755 "$app/Contents/MacOS/codex-watch-bridge"
/usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$app"
