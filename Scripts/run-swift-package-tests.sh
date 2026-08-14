#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
common_arguments=(
  --package-path "$repo_root"
  --no-parallel
  -Xswiftc -warnings-as-errors
)

# SecPKCS12Import can exhaust its process-local memory-only identity state when
# the Security-heavy TLS fixtures share a long-lived runner with the rest of
# the package. Run the TLS suite, the remaining service tests, and all other
# targets in complementary processes without omitting any tests.
swift test "${common_arguments[@]}" \
  --filter '^CodexBridgeServiceTests\.TLSIdentitySecurityTests'
swift test "${common_arguments[@]}" \
  --filter '^CodexBridgeServiceTests\.' \
  --skip '^CodexBridgeServiceTests\.TLSIdentitySecurityTests'
swift test "${common_arguments[@]}" --skip '^CodexBridgeServiceTests\.'
