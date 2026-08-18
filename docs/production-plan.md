# Production Plan: CodexWatch

## Product Brief

- Target user: the person who already captures thoughts on Apple Watch and needs the Mac to receive, transcribe, and hand them to local Codex Inbox.
- Primary job: pair the Watch, allow Speech, and see whether a memo arrived on this Mac.
- Core workflow: open the app → compare phrase/code on Watch → grant Speech → confirm the uploaded memo and retry if transcription is blocked.
- Business model: local utility for the existing Codex Watch project. Not App Store in this pass.
- Supported macOS versions: 15.0 and later, Apple silicon as already required by the bridge.
- Offline behavior: pairing, inbox listing, and Speech prompts are local. Codex insertion still needs the installed Codex executable used by the LaunchAgent.
- Data handled: pairing secrets in Keychain, audio and transcripts under `~/Library/Application Support/CodexWatch/State`. The UI reads those files; it does not create a second network stack.
- Privacy posture: on-device Speech only. No analytics. Logs are content-free.
- V1 scope: window, menu bar, pairing phrase/code, Speech authorization, inbox + retry, listener/advertised-name/paired-Watch status, Signal Spine visual language.
- Explicitly out of scope: App Store, iCloud, extra chat client, TLS/queue rewrite, second daemon, installer bind-host UI, memo playback.

## Architecture

- Scene model: `WindowGroup` + `MenuBarExtra` + `Settings`. Finder/open with no CLI args launches the UI. LaunchAgent still starts `codex-watch-bridge run`.
- Window roles: one console window. Settings shows install paths only.
- Layout model: spine header + inbox sidebar + memo detail.
- State ownership: `BridgeAppModel` polls the existing state root. The LaunchAgent process holds `service.lock`.
- Persistence: existing intake, journal, retained, Keychain pairing. Operator retry writes `service/retry-requested.json`.
- Services: `CodexBridgeService` / `CodexBridgeDelivery` / `PairingStore` / `AppleSpeechTranscriber`. No parallel networking.
- App Intents / Foundation Models / advanced capabilities: none.
- Folder/module structure: UI lives in `Sources/CodexWatchBridgeCLI` so the existing app executable remains `codex-watch-bridge`.

## Build And Run

- Project type: SwiftPM executable packaged by `Scripts/build-bridge-app.sh`.
- Build command: `Scripts/build-bridge-app.sh --output /absolute/dir`
- Run command: `open "$HOME/Library/Application Support/CodexWatch/Service/CodexWatch.app"` after install.
- `script/build_and_run.sh --verify` builds a throwaway bundle and refuses to open it as a sidecar.
- Codex Run action status: skipped (`.codex/` is gitignored in this repo).

## Design System

- Apple Design Resources checked: macOS 27 UI Kit / SF Symbols 8 listed by the local skill reference (last checked 2026-07-07); implementation uses native SwiftUI, SF Symbols, and system materials.
- Platform UI kit/version: macOS 15+ SwiftUI.
- SF Symbols/Icon Composer status: SF Symbols only. No custom icon in this pass.
- Native structures: `NavigationSplitView`, toolbar, Settings, menu commands, menu bar extra, context menus.
- Adaptive states: empty inbox, not installed, listener offline/paused, unpaired, Speech not determined/denied/restricted, needs-attention memo.
- Visual style: Signal Spine family (WATCH / MAC / CODEX nodes, rounded kickers, cyan/lime/amber tokens). Horizontal spine on Mac.
- Motion rules: 0.24s easeOut on spine changes; identity/opacity when Reduce Motion is on.
- Accessibility requirements: node shape plus label (not color-only), Reduce Transparency solids, VoiceOver labels on phrase/code.
- Empty/loading/error/offline/permission states: covered in `BridgeConsoleHeaderPresentation`.

## Test Strategy

- Unit tests: presentation, launch-mode routing, LaunchAgent argument parse, pairing expiry copy, retry mailbox.
- Integration tests or mocks: bounded processor drains the retry mailbox.
- UI/manual smoke: build the `.app`, open it, grant Speech. Label: `unverified` until opened on the operator Mac.
- Release smoke: existing `Scripts/build-bridge-app.sh` + InstallManifest tests. Not App Store.
- Commands:
  - `swift test --filter BridgeAppPresentationTests`
  - `swift test --filter OperatorRetryMailbox`
  - `swift test --filter boundedProcessorDrainsOperatorRetryMailbox`
  - `swift test --filter InstallManifestTests`

## Observability

- Logger subsystem: `ai.rsitech.codexwatch.bridge`
- Categories: `app`
- Key lifecycle/action events: refresh, pairing generated/failed, speech finished, retry queued/failed.
- Sensitive logging exclusions: no pairing code, phrase, transcript, audio, or memo IDs.

## App Store Readiness

- Out of scope for this pass. Bundle ID remains `ai.rsitech.codexwatch.bridge`.

## Iteration Log

| Date | Gate | Change | Verification | Next blocker |
| --- | --- | --- | --- | --- |
| 2026-08-17 | 0-3 | Promote existing bridge bundle to a Signal Spine Mac console without a second daemon | focused Swift tests + `Scripts/build-bridge-app.sh` | Operator must open the app to grant Speech; Mac UI is `unverified` |
