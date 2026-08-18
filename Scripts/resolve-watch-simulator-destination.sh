#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output_file="${GITHUB_OUTPUT:-}"
if [[ -z "$output_file" || "$output_file" != /* || ! -d "${output_file:h}" ]]; then
    print -u2 "GITHUB_OUTPUT must be an absolute path in an existing directory"
    exit 64
fi

if [[ -n "${WATCH_SIMULATOR_SELECTOR_BIN:-}" ]]; then
    selector="$WATCH_SIMULATOR_SELECTOR_BIN"
    if [[ "$selector" != /* || ! -x "$selector" || ! -f "$selector" ]]; then
        print -u2 "WATCH_SIMULATOR_SELECTOR_BIN must be an absolute executable file"
        exit 64
    fi
    selection="$($selector --format shell)"
else
    selection="$(swift run --package-path "$repo_root" watch-simulator-selector --format shell)"
fi

destination_ids=()
while IFS= read -r line; do
    if [[ "$line" == identifier=* ]]; then
        identifier="${line#identifier=}"
        if [[ ! "$identifier" =~ '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' ]]; then
            print -u2 "selector returned an invalid destination identifier"
            exit 2
        fi
        destination_ids+=("$identifier")
    fi
done <<< "$selection"

if (( ${#destination_ids[@]} != 1 )); then
    print -u2 "expected exactly one validated destination identifier"
    exit 2
fi

print -r -- "destination_id=${destination_ids[1]}" >> "$output_file"
