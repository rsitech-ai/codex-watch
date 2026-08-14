#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
runner="$repo_root/Scripts/run-swift-package-tests.sh"
workflow="$repo_root/.github/workflows/ci.yml"

[[ -x "$runner" ]] || { printf '%s\n' "package test runner is missing or not executable" >&2; exit 1; }
rg -F -- "--filter '^CodexBridgeServiceTests\\.TLSIdentitySecurityTests'" "$runner" > /dev/null
rg -F -- "--filter '^CodexBridgeServiceTests\\.'" "$runner" > /dev/null
rg -F -- "--skip '^CodexBridgeServiceTests\\.TLSIdentitySecurityTests'" "$runner" > /dev/null
rg -F -- "--skip '^CodexBridgeServiceTests\\.'" "$runner" > /dev/null
[[ "$(rg -c -- '-Xswiftc -warnings-as-errors' "$runner")" == 1 ]]
rg -F -- 'Scripts/run-swift-package-tests.sh' "$workflow" > /dev/null

printf '%s\n' "swift package test process contract: pass"
