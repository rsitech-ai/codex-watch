#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
resolver="$repo_root/Scripts/resolve-watch-simulator-destination.sh"
fixtures="$repo_root/Tests/CIContractTests/Fixtures"
fixture_root="$(mktemp -d /private/tmp/watch-destination-contract.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

success_output="$fixture_root/success-output"
WATCH_SIMULATOR_SELECTOR_BIN="$fixtures/selector-success.sh" \
GITHUB_OUTPUT="$success_output" \
    "$resolver"
[[ "$(<"$success_output")" == "destination_id=00000000-0000-0000-0000-000000000040" ]]

duplicate_output="$fixture_root/duplicate-output"
if WATCH_SIMULATOR_SELECTOR_BIN="$fixtures/selector-duplicate.sh" \
    GITHUB_OUTPUT="$duplicate_output" \
    "$resolver" 2>"$fixture_root/duplicate-error"
then
    print -u2 "duplicate selector identifiers unexpectedly succeeded"
    exit 1
fi
[[ "$(<"$fixture_root/duplicate-error")" == *"expected exactly one validated destination identifier"* ]]
[[ ! -s "$duplicate_output" ]]

missing_output="$fixture_root/missing-output"
if WATCH_SIMULATOR_SELECTOR_BIN="$fixtures/selector-missing.sh" \
    GITHUB_OUTPUT="$missing_output" \
    "$resolver" 2>"$fixture_root/missing-error"
then
    print -u2 "missing selector identifier unexpectedly succeeded"
    exit 1
fi
[[ "$(<"$fixture_root/missing-error")" == *"expected exactly one validated destination identifier"* ]]
[[ ! -s "$missing_output" ]]

print "watch destination contract: pass"
