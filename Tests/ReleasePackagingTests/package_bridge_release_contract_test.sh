#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
packager="$repo_root/Scripts/package-bridge-release.sh"

help_output="$($packager --help 2>&1)"
[[ "$help_output" == *"--output ABSOLUTE_DIRECTORY"* ]]
[[ "$help_output" == *"--sign-identity IDENTITY"* ]]
[[ "$help_output" == *"source checkout must be clean"* ]]
[[ "$help_output" == *'Developer ID Application identity and `--notary-profile`'* ]]

relative_error="$($packager --output relative --sign-identity - 2>&1 || true)"
if [[ "$relative_error" != *"release output must be an absolute path"* ]]; then
  print -u2 "relative release output unexpectedly succeeded"
  exit 1
fi

existing_output="$(mktemp -d /private/tmp/codex-watch-release-contract.XXXXXX)"
trap 'rm -rf "$existing_output"' EXIT
existing_error="$($packager --output "$existing_output" --sign-identity - 2>&1 || true)"
if [[ "$existing_error" != *"refusing to overwrite existing release output"* ]]; then
  print -u2 "existing release output unexpectedly succeeded"
  exit 1
fi

developer_output="/private/tmp/voice-inbox-release-contract-$RANDOM-$RANDOM"
developer_error="$($packager --output "$developer_output" --sign-identity "Developer ID Application: Fixture" 2>&1 || true)"
if [[ "$developer_error" != *"public Developer ID releases require --notary-profile"* ]]; then
  print -u2 "Developer ID release without notarization profile unexpectedly succeeded"
  exit 1
fi

print "package bridge release contract: pass"
