#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: capture-watch-ui-evidence.sh --app <absolute .app> --output <absolute absent-or-empty directory>"
    exit 64
}

fail() {
    print -u2 -- "$1"
    exit "${2:-1}"
}

if (( $# != 4 )) || [[ "$1" != --app || "$3" != --output ]]; then
    usage
fi

app="$2"
output="$4"
[[ "$app" == /* && "$app" == *.app && -d "$app" && ! -L "$app" ]] || usage
[[ -f "$app/Info.plist" && ! -L "$app/Info.plist" ]] || usage
app_physical="$(cd "$app" && pwd -P)"
[[ "$app_physical" == "$app" ]] || usage

bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist" 2>/dev/null)" \
    || fail "app bundle identifier is unavailable" 64
[[ "$bundle_identifier" == ai.rsitech.voiceinbox ]] \
    || fail "app bundle identifier must be ai.rsitech.voiceinbox" 64

[[ "$output" == /* && "$output" != / && ! -L "$output" ]] || usage
if [[ -e "$output" ]]; then
    [[ -d "$output" ]] || usage
    [[ "$(cd "$output" && pwd -P)" == "$output" ]] || usage
    [[ -z "$(/usr/bin/find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "output directory must be empty" 64
else
    output_parent="${output:h}"
    [[ -d "$output_parent" && ! -L "$output_parent" ]] || usage
    [[ "$(cd "$output_parent" && pwd -P)" == "$output_parent" ]] || usage
    /bin/mkdir "$output"
fi

command_timeout="${WATCH_UI_COMMAND_TIMEOUT_SECONDS:-30}"
render_delay="${WATCH_UI_RENDER_DELAY_SECONDS:-2}"
[[ "$command_timeout" =~ '^[0-9]+$' ]] || usage
[[ "$render_delay" =~ '^[0-9]+$' ]] || usage
(( command_timeout >= 1 && command_timeout <= 60 )) || usage
(( render_delay >= 0 && render_delay <= 5 )) || usage

run_bounded() {
    local timeout_seconds="$1"
    shift
    "$@" &
    local child_pid=$!
    local tick=0
    local maximum_ticks=$(( timeout_seconds * 10 ))
    while kill -0 "$child_pid" 2>/dev/null; do
        if (( tick >= maximum_ticks )); then
            kill -TERM "$child_pid" 2>/dev/null || true
            /bin/sleep 0.1
            kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
            return 124
        fi
        /bin/sleep 0.1
        (( tick += 1 ))
    done
    wait "$child_pid"
}

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
temporary_root="$(/usr/bin/mktemp -d /private/tmp/codex-watch-ui-evidence.XXXXXX)"
trap '/bin/rm -rf "$temporary_root"' EXIT
selection_json="$temporary_root/selection.json"

if [[ -n "${WATCH_SIMULATOR_SELECTOR_BIN:-}" ]]; then
    selector="$WATCH_SIMULATOR_SELECTOR_BIN"
    [[ "$selector" == /* && -f "$selector" && -x "$selector" && ! -L "$selector" ]] || usage
    selector_command=("$selector")
else
    selector_command=(/usr/bin/swift run --package-path "$repo_root" watch-simulator-selector)
fi

run_bounded "$command_timeout" \
    "${selector_command[@]}" --all-sizes --format json > "$selection_json" \
    || fail "Watch simulator selection failed or timed out" 2
destination_count="$(/usr/bin/plutil -extract destinations raw -o - "$selection_json" 2>/dev/null)" \
    || fail "selector returned malformed JSON" 2
[[ "$destination_count" =~ '^[0-9]+$' ]] || fail "selector returned malformed JSON" 2
(( destination_count >= 1 && destination_count <= 32 )) \
    || fail "selector returned an invalid destination count" 2

typeset -a identifiers names runtimes sizes rationales
typeset -A seen_identifiers seen_sizes
for (( index = 0; index < destination_count; index++ )); do
    identifier="$(/usr/bin/plutil -extract "destinations.$index.identifier" raw -o - "$selection_json" 2>/dev/null)" \
        || fail "selector record is missing an identifier" 2
    name="$(/usr/bin/plutil -extract "destinations.$index.name" raw -o - "$selection_json" 2>/dev/null)" \
        || fail "selector record is missing a name" 2
    runtime="$(/usr/bin/plutil -extract "destinations.$index.runtime" raw -o - "$selection_json" 2>/dev/null)" \
        || fail "selector record is missing a runtime" 2
    size="$(/usr/bin/plutil -extract "destinations.$index.display_mm" raw -o - "$selection_json" 2>/dev/null)" \
        || fail "selector record is missing a display size" 2
    rationale="$(/usr/bin/plutil -extract "destinations.$index.rationale" raw -o - "$selection_json" 2>/dev/null)" \
        || fail "selector record is missing a rationale" 2

    [[ "$identifier" =~ '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' ]] \
        || fail "selector returned an invalid destination identifier" 2
    [[ "$runtime" =~ '^[0-9]+\.[0-9]+$' ]] || fail "selector returned an invalid runtime" 2
    [[ "$size" =~ '^[0-9]{2}$' ]] || fail "selector returned an invalid display size" 2
    [[ "$rationale" == one-stable-destination-per-display-on-exact-active-runtime ]] \
        || fail "selector returned an unexpected rationale" 2
    [[ "$name" != *$'\n'* && "$name" != *$'\r'* && "$name" != *$'\t'* ]] \
        || fail "selector returned an unsafe device name" 2
    [[ -z "${seen_identifiers[$identifier]:-}" && -z "${seen_sizes[$size]:-}" ]] \
        || fail "selector returned a duplicate identifier or display size" 2

    seen_identifiers[$identifier]=1
    seen_sizes[$size]=1
    identifiers+=("$identifier")
    names+=("$name")
    runtimes+=("$runtime")
    sizes+=("$size")
    rationales+=("$rationale")
done
(( ${#identifiers[@]} > 0 )) || fail "selector returned no destinations" 2

if [[ -n "${WATCH_SIMCTL_BIN:-}" ]]; then
    simctl="$WATCH_SIMCTL_BIN"
    [[ "$simctl" == /* && -f "$simctl" && -x "$simctl" && ! -L "$simctl" ]] || usage
    simctl_command=("$simctl")
else
    simctl_command=(/usr/bin/xcrun simctl)
fi

manifest="$output/manifest.tsv"
print -r -- $'display_mm\tscenario\tfilename\tsha256\tdevice\tidentifier\truntime\trationale' > "$manifest"
scenarios=(ready recording savedOnWatch delivered needsAttention queue pairing)

for position in {1..${#identifiers[@]}}; do
    identifier="${identifiers[$position]}"
    size="${sizes[$position]}"
    boot_error="$temporary_root/boot-$size.log"

    if run_bounded "$command_timeout" "${simctl_command[@]}" boot "$identifier" \
        > /dev/null 2> "$boot_error"
    then
        :
    else
        boot_status=$?
        (( boot_status != 124 )) || fail "boot timed out for ${size}mm" 2
    fi
    run_bounded "$command_timeout" "${simctl_command[@]}" bootstatus "$identifier" -b \
        > /dev/null || fail "boot readiness failed for ${size}mm" 2
    run_bounded "$command_timeout" "${simctl_command[@]}" install "$identifier" "$app" \
        > /dev/null || fail "app install failed for ${size}mm" 2

    for scenario in $scenarios; do
        filename="${scenario}-${size}mm.png"
        screenshot="$output/$filename"
        run_bounded "$command_timeout" /usr/bin/env \
            "SIMCTL_CHILD_CODEX_WATCH_RENDER_SCENARIO=$scenario" \
            "${simctl_command[@]}" launch --terminate-running-process \
            "$identifier" "$bundle_identifier" > /dev/null \
            || fail "scenario launch failed for ${scenario} ${size}mm" 2
        (( render_delay == 0 )) || /bin/sleep "$render_delay"
        run_bounded "$command_timeout" "${simctl_command[@]}" io "$identifier" \
            screenshot "$screenshot" > /dev/null \
            || fail "screenshot failed for ${scenario} ${size}mm" 2
        [[ -s "$screenshot" ]] || fail "empty screenshot for ${scenario} ${size}mm" 2
        run_bounded "$command_timeout" "${simctl_command[@]}" terminate \
            "$identifier" "$bundle_identifier" > /dev/null \
            || fail "app termination failed for ${scenario} ${size}mm" 2

        digest="$(/usr/bin/shasum -a 256 "$screenshot" | /usr/bin/awk '{print $1}')"
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$size" "$scenario" "$filename" "$digest" "${names[$position]}" \
            "$identifier" "${runtimes[$position]}" "${rationales[$position]}" \
            >> "$manifest"
    done
done

expected_images=$(( ${#identifiers[@]} * ${#scenarios[@]} ))
actual_images="$(/usr/bin/find "$output" -maxdepth 1 -type f -name '*.png' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
(( actual_images == expected_images )) || fail "incomplete Watch screenshot matrix" 2
print -r -- "captured $actual_images content-free Watch screenshots in $output"
