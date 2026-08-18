#!/bin/zsh
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: package-bridge-release.sh --output ABSOLUTE_DIRECTORY --sign-identity IDENTITY [--notary-profile PROFILE]

Builds the macOS Codex Watch companion app, applies the requested code-signing identity,
notarizes and staples public builds, and writes a versioned zip, manifest, and
SHA256SUMS into a new output directory. The source checkout must be clean. Use
`-` as IDENTITY only for local ad-hoc validation; a public release requires a
Developer ID Application identity and `--notary-profile`.
USAGE
}

[[ $# -gt 0 ]] || { usage >&2; exit 64; }
if [[ $# -eq 1 && "$1" == "--help" ]]; then
  usage
  exit 0
fi

typeset -A release_options
while [[ $# -gt 0 ]]; do
  [[ "$1" == --* && $# -ge 2 && -z "${release_options[${1#--}]:-}" ]] || { usage >&2; exit 64; }
  release_options[${1#--}]="$2"
  shift 2
done

output="${release_options[output]:-}"
sign_identity="${release_options[sign-identity]:-}"
notary_profile="${release_options[notary-profile]:-}"
[[ -n "$output" && -n "$sign_identity" ]] || { usage >&2; exit 64; }
[[ "$output" = /* ]] || { print -u2 "release output must be an absolute path"; exit 64; }
[[ ! -e "$output" ]] || { print -u2 "refusing to overwrite existing release output: $output"; exit 73; }
[[ "$sign_identity" != "-" || -z "$notary_profile" ]] || {
  print -u2 "notarization requires a Developer ID Application identity"
  exit 64
}
[[ "$sign_identity" == "-" || -n "$notary_profile" ]] || {
  print -u2 "public Developer ID releases require --notary-profile"
  exit 64
}

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_root/Bridge/Info.plist")"
[[ "$version" == <->.<->.<-> ]] || { print -u2 "invalid bridge version: $version"; exit 65; }
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/Bridge/Info.plist")"
[[ "$minimum_macos" == <->.<-> ]] || { print -u2 "invalid minimum macOS version: $minimum_macos"; exit 65; }

source_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || print unavailable)"
source_state="clean"
git -C "$repo_root" diff --quiet --ignore-submodules -- || source_state="dirty"
git -C "$repo_root" diff --cached --quiet --ignore-submodules -- || source_state="dirty"
[[ -z "$(git -C "$repo_root" ls-files --others --exclude-standard)" ]] || source_state="dirty"
[[ "$source_state" == "clean" ]] || {
  print -u2 "refusing to package a public release from a dirty source checkout"
  exit 65
}

scratch="$(mktemp -d /private/tmp/codex-watch-release.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
build_root="$scratch/build"
"$repo_root/Scripts/build-bridge-app.sh" --output "$build_root"
app="$build_root/CodexWatch.app"

if [[ "$sign_identity" == "-" ]]; then
  signing_mode="ad-hoc"
else
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$sign_identity" \
    "$app"
  signing_mode="developer-id"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$app"

notarization_state="not-requested"
if [[ -n "$notary_profile" ]]; then
  notary_archive="$scratch/CodexWatch-notary.zip"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_archive"
  /usr/bin/xcrun notarytool submit \
    "$notary_archive" \
    --keychain-profile "$notary_profile" \
    --wait
  /usr/bin/xcrun stapler staple "$app"
  /usr/bin/xcrun stapler validate "$app"
  notarization_state="accepted-and-stapled"
fi

architecture="$(/usr/bin/lipo -archs "$app/Contents/MacOS/codex-watch-bridge" | tr ' ' '-')"
release_name="CodexWatch-$version-macos-$architecture"
release_root="$scratch/$release_name"
mkdir -p "$release_root"
cp -R "$app" "$release_root/CodexWatch.app"
cp "$repo_root/Scripts/install-bridge.sh" "$release_root/install-bridge.sh"
cp "$repo_root/Scripts/uninstall-bridge.sh" "$release_root/uninstall-bridge.sh"
cp "$repo_root/LICENSE" "$release_root/LICENSE"
cp "$repo_root/NOTICE" "$release_root/NOTICE"
cp "$repo_root/README.md" "$release_root/README.md"
chmod 755 "$release_root/install-bridge.sh" "$release_root/uninstall-bridge.sh"

mkdir -p "$output"
archive="$output/$release_name.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "$release_root" "$archive"
archive_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if /usr/bin/unzip -Z1 "$archive" | /usr/bin/grep -q '^__MACOSX/'; then
  print -u2 "archive verification failed: Finder metadata is not distributable content"
  exit 66
fi

verification_root="$scratch/verification"
mkdir -p "$verification_root"
/usr/bin/ditto -x -k "$archive" "$verification_root"
verified_release_root="$verification_root/$release_name"
verified_app="$verified_release_root/CodexWatch.app"
[[ -d "$verified_app" ]] || { print -u2 "archive verification failed: app missing"; exit 66; }
for required in install-bridge.sh uninstall-bridge.sh LICENSE NOTICE README.md; do
  [[ -f "$verified_release_root/$required" ]] || {
    print -u2 "archive verification failed: $required missing"
    exit 66
  }
done
/usr/bin/codesign --verify --strict --verbose=2 "$verified_app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$verified_app/Contents/Info.plist")" == "ai.rsitech.codexwatch.bridge" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$verified_app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$verified_app/Contents/Info.plist")" == "$minimum_macos" ]]
if [[ "$notarization_state" == "accepted-and-stapled" ]]; then
  /usr/bin/xcrun stapler validate "$verified_app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$verified_app"
fi

manifest_plist="$scratch/release-manifest.plist"
manifest="$output/release-manifest.json"
/usr/bin/plutil -create xml1 "$manifest_plist"
/usr/bin/plutil -insert schemaVersion -integer 1 "$manifest_plist"
/usr/bin/plutil -insert product -dictionary "$manifest_plist"
/usr/bin/plutil -insert product.name -string "Codex Watch" "$manifest_plist"
/usr/bin/plutil -insert product.bundleIdentifier -string "ai.rsitech.codexwatch.bridge" "$manifest_plist"
/usr/bin/plutil -insert product.version -string "$version" "$manifest_plist"
/usr/bin/plutil -insert product.architecture -string "$architecture" "$manifest_plist"
/usr/bin/plutil -insert product.minimumMacOS -string "$minimum_macos" "$manifest_plist"
/usr/bin/plutil -insert sourceCommit -string "$source_commit" "$manifest_plist"
/usr/bin/plutil -insert sourceState -string "$source_state" "$manifest_plist"
/usr/bin/plutil -insert signingMode -string "$signing_mode" "$manifest_plist"
/usr/bin/plutil -insert signingIdentity -string "$sign_identity" "$manifest_plist"
/usr/bin/plutil -insert notarization -string "$notarization_state" "$manifest_plist"
/usr/bin/plutil -insert archive -dictionary "$manifest_plist"
/usr/bin/plutil -insert archive.name -string "$(basename "$archive")" "$manifest_plist"
/usr/bin/plutil -insert archive.sha256 -string "$archive_sha256" "$manifest_plist"
/usr/bin/plutil -convert json -o "$manifest" "$manifest_plist"

(
  cd "$output"
  shasum -a 256 "$(basename "$archive")" release-manifest.json > SHA256SUMS
  shasum -a 256 -c SHA256SUMS >/dev/null
)

print "release archive: $archive"
print "release manifest: $manifest"
print "release checksums: $output/SHA256SUMS"
