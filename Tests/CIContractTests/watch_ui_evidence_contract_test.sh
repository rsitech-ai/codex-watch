#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
capture="$repo_root/Scripts/capture-watch-ui-evidence.sh"
[[ -x "$capture" ]] || { printf '%s\n' "capture script is missing or not executable" >&2; exit 1; }

fixture_root="$(mktemp -d /private/tmp/watch-ui-evidence-contract.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

app="$fixture_root/CodexWatch.app"
mkdir -p "$app"
/usr/bin/plutil -create xml1 "$app/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string ai.rsitech.voiceinbox "$app/Info.plist"

selector="$fixture_root/selector"
cat > "$selector" <<'SELECTOR'
#!/bin/zsh
[[ "$*" == "--all-sizes --format json" ]] || exit 64
print -r -- '{"destinations":[
{"display_mm":40,"identifier":"00000000-0000-0000-0000-000000000040","name":"Apple Watch SE 3 (40mm)","rationale":"one-stable-destination-per-display-on-exact-active-runtime","runtime":"26.5","runtime_identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5"},
{"display_mm":42,"identifier":"00000000-0000-0000-0000-000000000042","name":"Apple Watch Series 11 (42mm)","rationale":"one-stable-destination-per-display-on-exact-active-runtime","runtime":"26.5","runtime_identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5"},
{"display_mm":44,"identifier":"00000000-0000-0000-0000-000000000044","name":"Apple Watch Series 6 (44mm)","rationale":"one-stable-destination-per-display-on-exact-active-runtime","runtime":"26.5","runtime_identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5"},
{"display_mm":46,"identifier":"00000000-0000-0000-0000-000000000046","name":"Apple Watch Series 11 (46mm)","rationale":"one-stable-destination-per-display-on-exact-active-runtime","runtime":"26.5","runtime_identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5"},
{"display_mm":49,"identifier":"00000000-0000-0000-0000-000000000049","name":"Apple Watch Ultra 3 (49mm)","rationale":"one-stable-destination-per-display-on-exact-active-runtime","runtime":"26.5","runtime_identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5"}
]}'
SELECTOR
chmod +x "$selector"

simctl="$fixture_root/simctl"
cat > "$simctl" <<'SIMCTL'
#!/bin/zsh
set -euo pipefail
print -r -- "${CODEX_WATCH_RENDER_SCENARIO:-none}|$*" >> "$WATCH_SIMCTL_LOG"
if [[ "${WATCH_SIMCTL_HANG_BOOT:-0}" == 1 && "$1" == boot ]]; then
    sleep 5
fi
if [[ "$1" == io && "$3" == screenshot ]]; then
    print -n -- 'fixture-png' > "$4"
fi
SIMCTL
chmod +x "$simctl"

expect_failure() {
    if "$capture" "$@" > /dev/null 2> "$fixture_root/expected-error"; then
        printf '%s\n' "invalid capture invocation unexpectedly succeeded: $*" >&2
        exit 1
    fi
}

expect_failure --app CodexWatch.app --output "$fixture_root/relative-app"
expect_failure --app "$fixture_root/not-an-app" --output "$fixture_root/non-app"
expect_failure --app "$app" --output relative-output
mkdir -p "$fixture_root/nonempty"
printf '%s\n' sentinel > "$fixture_root/nonempty/keep"
expect_failure --app "$app" --output "$fixture_root/nonempty"
[[ "$(<"$fixture_root/nonempty/keep")" == sentinel ]]

output="$fixture_root/evidence"
log="$fixture_root/simctl.log"
WATCH_SIMULATOR_SELECTOR_BIN="$selector" \
WATCH_SIMCTL_BIN="$simctl" \
WATCH_SIMCTL_LOG="$log" \
WATCH_UI_RENDER_DELAY_SECONDS=0 \
WATCH_UI_COMMAND_TIMEOUT_SECONDS=2 \
    "$capture" --app "$app" --output "$output"

scenarios=(ready recording savedOnWatch delivered needsAttention queue pairing)
sizes=(40 42 44 46 49)
for size in "${sizes[@]}"; do
    for scenario in "${scenarios[@]}"; do
        image="$output/${scenario}-${size}mm.png"
        [[ -s "$image" ]] || { printf '%s\n' "missing image: $image" >&2; exit 1; }
        [[ "$(<"$image")" == fixture-png ]]
    done
done

[[ -f "$output/manifest.tsv" ]]
[[ "$(wc -l < "$output/manifest.tsv" | tr -d ' ')" == 36 ]]
/usr/bin/awk -F $'\t' 'NF != 8 { exit 1 }' "$output/manifest.tsv"
[[ "$(/usr/bin/grep -cF '|boot ' "$log")" == 5 ]]
[[ "$(/usr/bin/grep -cF '|install ' "$log")" == 5 ]]
[[ "$(/usr/bin/grep -cF '|launch ' "$log")" == 35 ]]
[[ "$(/usr/bin/grep -cE '\|io .* screenshot ' "$log")" == 35 ]]
[[ "$(/usr/bin/grep -cF '|terminate ' "$log")" == 35 ]]
for scenario in "${scenarios[@]}"; do
    [[ "$(/usr/bin/grep -cE "^${scenario}\\|" "$log")" == 3 ]]
done
if /usr/bin/grep -nE '(^|[^[:alnum:]_])(erase|delete|shutdown|pair)([^[:alnum:]_]|$)' "$log"; then
    printf '%s\n' "capture invoked a destructive simulator command" >&2
    exit 1
fi

hang_output="$fixture_root/hang-evidence"
SECONDS=0
if WATCH_SIMULATOR_SELECTOR_BIN="$selector" \
    WATCH_SIMCTL_BIN="$simctl" \
    WATCH_SIMCTL_LOG="$fixture_root/hang.log" \
    WATCH_SIMCTL_HANG_BOOT=1 \
    WATCH_UI_RENDER_DELAY_SECONDS=0 \
    WATCH_UI_COMMAND_TIMEOUT_SECONDS=1 \
        "$capture" --app "$app" --output "$hang_output" > /dev/null 2>&1
then
    printf '%s\n' "timed-out simulator command unexpectedly succeeded" >&2
    exit 1
fi
(( SECONDS < 4 )) || { printf '%s\n' "simulator command timeout was not bounded" >&2; exit 1; }

printf '%s\n' "watch ui evidence contract: pass"
