# Voice Inbox

[![CI](https://github.com/rsitech-ai/voice-inbox-watch/actions/workflows/ci.yml/badge.svg)](https://github.com/rsitech-ai/voice-inbox-watch/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Voice Inbox is an open-source project by [RSI Tech](https://rsitech.ai),
maintained at [info@rsitech.ai](mailto:info@rsitech.ai).

Voice Inbox is a standalone Apple Watch voice-capture app. It records an idea,
keeps the audio durably on the Watch while the Mac is unavailable, and sends it
over authenticated local HTTPS to an invisible macOS bridge. The bridge
transcribes locally and prepares the transcript for a dedicated `Codex Voice
Inbox` through a separately owned local Codex App Server.

There is no iPhone target, WatchConnectivity relay, visible Mac application,
menu-bar item, settings window, or cloud-audio fallback. The macOS component is
background infrastructure packaged with `LSBackgroundOnly=true`; raw audio is
never submitted to Codex. This project is not affiliated with or endorsed by
OpenAI.

## Release status

- `repo-ready` means package tests, the Watch simulator build, bridge smokes,
  privacy metadata, and release packaging pass for the published source.
- The exact `v0.1.0` macOS bridge download is `package-ready`: its published
  checksum, Developer ID signature, Gatekeeper notarization assessment, and
  stapled ticket were verified. This does not prove the Watch app on hardware.
- Physical Apple Watch capture and the complete Watch-to-Mac workflow remain
  `blocked:external` while the connected Watch's CoreDevice tunnel is
  disconnected; simulator evidence is not physical-device evidence.
- The Watch app is currently distributed as source. App Store signing,
  App Store Connect metadata, TestFlight, and review are separate release gates.
- Codex App Server compatibility is version-specific. The latest retained
  isolated `thread/list` smoke and date are recorded in
  [`docs/RELEASE-VERIFICATION.md`](docs/RELEASE-VERIFICATION.md); other versions
  remain `unverified`. This is not an OpenAI support guarantee or proof that an
  official Codex client will render an inserted item.

## Requirements

- Apple Watch running watchOS 10 or later.
- Apple silicon Mac running macOS 15 or later for the downloadable bridge.
- Xcode 26 and Swift 6.2 or later when building from source.
- The official Codex app and its local App Server. Using the bridge submits each
  completed transcript through that App Server.

## Repository layout

- `WatchApp/` and `CodexWatch.xcodeproj`: the only user-visible product and its
  Watch-hosted tests. The Xcode project has no iOS application target.
- `Sources/CodexWatchCore`: durable Watch queue and transfer state machine.
- `Sources/CodexBridgeService` and `Sources/CodexBridgeDelivery`: authenticated
  intake, local Speech transcription, recovery journal, and Codex Inbox adapter.
- `Sources/CodexWatchBridgeCLI`: the headless bridge commands and lifecycle.
- `Bridge/` and `Scripts/`: background-only bundle metadata, lifecycle
  delegates, and release packaging.

## Local build and verification

These commands do not create or mutate a real Codex task:

```bash
swift test --no-parallel

xcodebuild \
  -project CodexWatch.xcodeproj \
  -scheme CodexWatch \
  -sdk watchsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

bridge_output="$(mktemp -d /private/tmp/codex-watch-bridge-build.XXXXXX)"
Scripts/build-bridge-app.sh --output "$bridge_output"
plutil -lint "$bridge_output/VoiceInboxBridge.app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' \
  "$bridge_output/VoiceInboxBridge.app/Contents/Info.plist")" = true

Scripts/run-watch-bridge-smoke.sh

# Read-only physical readiness; never invokes Xcode or changes device state.
swift run watch-device-preflight

# Read-only exact-runtime selector used by hosted CI.
swift run watch-simulator-selector --format shell

# Non-mutating compatibility probe. Supply an explicit executable; there is no
# PATH, Desktop App Server, normal Codex home, or existing-task fallback.
mkdir -p docs/evidence
swift run codex-compatibility-smoke \
  --codex /opt/homebrew/bin/codex \
  --evidence-directory "$PWD/docs/evidence" \
  --source-commit "$(git rev-parse HEAD)" \
  --timeout-seconds 20
```

Installer tests inject temporary paths plus fake launchctl, signature, identity,
and health adapters. They never execute the production lifecycle wrappers or
write the real LaunchAgents directory. Developer ID signing, notarization, and
physical-Watch proof remain explicit external release/device gates.

## Download the Mac bridge

Download the latest bridge package, `release-manifest.json`, and `SHA256SUMS` from
[GitHub Releases](https://github.com/rsitech-ai/voice-inbox-watch/releases/latest).
Verify the package before unzipping:

```bash
shasum -a 256 -c SHA256SUMS
unzip VoiceInboxBridge-*.zip
```

The architecture is encoded in the archive filename. The archive contains
`VoiceInboxBridge.app`, the install/uninstall delegates, this README, the
Apache-2.0 license, and the project NOTICE. The Watch app is not sideloaded
from this archive; build it from source with Xcode until an App Store release
exists.

## Bridge installation

The built bundle owns installation and rollback; the shell scripts only locate
that executable and delegate. This is an operator action that writes the exact
per-user application, state, and LaunchAgent paths:

```bash
# Install with the same signed app binary that will serve (Keychain private-key
# ACLs bind to the creating code signature). Homebrew's `codex` symlink is OK;
# the installer resolves it to a regular executable for launchd.
# Replace 192.168.1.42 with this Mac's current Wi-Fi or Ethernet address.
# Loopback addresses are rejected because an Apple Watch cannot reach them.
cd /absolute/path/VoiceInboxBridge-0.1.0-macos-arm64
./install-bridge.sh \
  --bundle "$PWD/VoiceInboxBridge.app" \
  --codex /opt/homebrew/bin/codex \
  --bind-host 192.168.1.42 \
  --advertised-host 192.168.1.42

"$HOME/Library/Application Support/VoiceInboxBridge/Service/VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge" status
./uninstall-bridge.sh
./uninstall-bridge.sh --purge-data # explicitly removes installer-owned state
```

Update failure restores the prior app, LaunchAgent, and public identity
fingerprint, then re-bootstraps the prior loaded service. Default uninstall
preserves all state; only `--purge-data` removes the installer-owned State root.

## Watch flow

1. Open Voice Inbox and tap the microphone to record; stopping first commits the
   `.m4a` and metadata to the Watch queue. A recording is bounded to the shared
   15-minute protocol limit, with a visible countdown during the final minute.
2. Open **Mac Bridge**, choose the discovered Mac, compare the certificate
   phrase, and enter the bridge's one-time six-digit code.
3. The Watch uploads saved memos when the paired bridge is available and polls
   authenticated delivery status. Foreground maintenance and best-effort
   background refresh revisit the durable queue; audio remains queued through
   failures.
4. The Watch shows `Saved to local Inbox` only after the bridge journal reports
   verified local delivery. The Watch defaults to retaining delivered audio for
   seven days. In **Keep delivered audio**, choose `1 day`, `7 days`, or
   `30 days`; changing the choice immediately revisits delivered audio only.
   Waiting and attention items stay on the Watch, and a failed maintenance pass
   keeps both the selected preference and queued audio for the next lifecycle
   retry. The bridge retains its separate seven-day recovery copy.

The repository-side flow is continuously tested against a fake Inbox. Each
real delivery starts and waits for a Codex App Server model turn. The turn asks
for a read-only sandbox with network disabled and approvals set to `never`, but
read-only sandboxing can still permit filesystem reads. The prompt instructs
the model not to inspect files or execute the captured idea; that instruction
is not a technical no-tools boundary. Use the bridge only with a trusted Codex
installation and review the privacy boundary below.

## Pairing from the headless bridge

The installed bridge reads its per-user identity directly from Keychain. No
PKCS#12 path or password file is used for production pairing. The command prints
the human-comparable phrase first and the one-time code second; the Watch must
show that exact phrase before the code is entered.

```bash
"$HOME/Library/Application Support/VoiceInboxBridge/Service/VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge" pair \
  --state-root "$HOME/Library/Application Support/VoiceInboxBridge/State"
```

If the installed executable is absent while repairing a source checkout, build
the executable and invoke that source-built path with the same `pair` and
`--state-root` arguments. The `--identity-p12` and
`--identity-password-file` options are fixture/compatibility inputs only; they
are not the installed production flow.

The raw 256-bit fingerprint and identity password are not printed. The code
expires after ten minutes and is accepted once.

## Delivered-memo retention

After verified Inbox delivery, the bridge atomically moves the committed audio
and receipt into its private recoverable retention directory. The matching
delivered journal remains available for the same seven-day interval. Startup,
delivery, and six-hour maintenance passes remove both layers only after the
cutoff; a maintenance failure keeps the archive intact, emits a content-free
local diagnostic, and retries later.

To remove all verified delivered material immediately, first stop the resident
bridge and run:

```bash
VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge purge-delivered \
  --state-root /absolute/private/bridge-state
```

The command holds the same exclusive service lease as the bridge and the same
retention-maintenance lease as startup, delivery, and periodic cleanup. It
refuses to race a running bridge or another cleanup pass, never purges an
unresolved memo, and prints only the number of purged records.

## Bridge diagnostics

The private service directory holds a bounded local diagnostic log for bridge
lifecycle and retention health. `bridge.log` is limited to 256 KiB and rotates
through at most `bridge.log.1`, `bridge.log.2`, and `bridge.log.3`. Lines have
only an integral Unix timestamp and one closed event code; they cannot contain
memo IDs, transcript text, audio, paths, pairing data, hosts, or Codex
identifiers. A diagnostic write failure never interrupts intake, retention, or
delivery, and the existing content-free stderr warning remains available for
retention maintenance failures.

## Local Speech permission

The bridge never falls back to cloud transcription. Check permission without
showing a prompt:

```bash
VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge speech-status \
  --state-root /absolute/private/bridge-state
```

On first setup, explicitly request the macOS Speech Recognition permission:

```bash
VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge authorize-speech \
  --state-root /absolute/private/bridge-state
```

`authorize-speech` is the only bridge command that requests this permission.
If access is denied, the bridge reports the System Settings action and keeps
the committed recording for recovery instead of using a network recognizer.

## Operational status

The read-only status command does not create a service lock or request system
permission:

```bash
VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge status \
  --state-root /absolute/private/bridge-state
```

It reports the bridge and protocol versions, persisted service state, listener
health, Speech authorization state, and counts of committed and retained memos.
It never prints memo IDs, paths, transcript text, audio, pairing material, or
Codex thread identifiers.

## Project governance

- Public maintainer: [RSI Tech](https://rsitech.ai)
- Public and confidential contact: [info@rsitech.ai](mailto:info@rsitech.ai)
- Contributions: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reports: [SECURITY.md](SECURITY.md)
- Community standard: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## License

Copyright 2026 Rafal Sikora.

Licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for
project attribution.
