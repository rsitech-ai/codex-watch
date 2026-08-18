#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
runner="$repo_root/Scripts/run-swift-package-tests.sh"
workflow="$repo_root/.github/workflows/ci.yml"

[[ -x "$runner" ]] || { printf '%s\n' "package test runner is missing or not executable" >&2; exit 1; }
/usr/bin/grep -Fq -- "--filter '^CodexBridgeServiceTests\\.TLSIdentitySecurityTests'" "$runner"
/usr/bin/grep -Fq -- "--filter '^CodexBridgeServiceTests\\.'" "$runner"
/usr/bin/grep -Fq -- "--skip '^CodexBridgeServiceTests\\.TLSIdentitySecurityTests'" "$runner"
/usr/bin/grep -Fq -- "--skip '^CodexBridgeServiceTests\\.'" "$runner"
[[ "$(/usr/bin/grep -cF -- '-Xswiftc -warnings-as-errors' "$runner")" == 1 ]]
/usr/bin/grep -Fq -- 'Scripts/run-swift-package-tests.sh' "$workflow"

printf '%s\n' "swift package test process contract: pass"
