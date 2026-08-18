# App E2E Audit Report: Codex Watch

## Scope

- Date: 2026-08-18 (second pass, same day)
- Auditor: agent (`rsi-app-e2e-audit-orchestrator`, `rsi-watch-experience-director`, `rsi-swiftui-polish-auditor`, `rsi-refine-product-quality`)
- App path: `$HOME/Library/Application Support/CodexWatch/Service/CodexWatch.app` (embedded LaunchAgent binary; not a `/tmp` sidecar)
- Project/workspace/package: `feat/andrzej_signal_spine_watch_ui` / SwiftPM `CodexWatch`
- Scheme/target: product `codex-watch-bridge` / bundle `ai.rsitech.codexwatch.bridge`; Watch `CodexWatch` / `ai.rsitech.codexwatch`
- Platform/surfaces: native macOS operator console + LaunchAgent listener; Watch source + simulator tests; physical Watch blocked
- Readiness target: Mac console smoke-clean; Watch `simulator-proven` for hosted tests; hardware not `physical-watch-proven`
- Forbidden actions without confirmation: uninstall, rotate TLS, revoke Watch Keychain, purge delivered, merge/mark-ready PR #4, execute Reset, click system Speech Allow / Keychain Always Allow

Official docs checked this pass: Apple Speech `requestAuthorization` / `notDetermined` and the on-device note versus `SFSpeechRecognizer`; Network `Creating an Identity for Local Network TLS`; watchOS TN3135 (Watch upload uses `URLSession` HTTPS; Bonjour browse remains existing `NWBrowser`).

## Tool Plan

| Surface | Tool | Reason | Status |
| --- | --- | --- | --- |
| Build/test/logs | `Scripts/build-bridge-app.sh`, `install-bridge.sh`, partitioned `Scripts/run-swift-package-tests.sh`, Watch `xcodebuild test`, `run-watch-bridge-smoke.sh` | rebuild, install without TLS rotate, tests beyond focused filters | used |
| Native app UI | AppleScript AX | Computer Use MCP not available | used |
| Browser/local web | n/a | no web surface | not applicable |
| Product quality | rsi-refine-product-quality / rsi-swiftui-polish-auditor | objective defects vs polish | used |

## Commands And Artifacts

| Check | Command / Tool | Result | Evidence path or note |
| --- | --- | --- | --- |
| Build | `Scripts/build-bridge-app.sh --output /private/tmp/codex-watch-bridge-build.LqB7KU` | ok, adhoc sign | sidecar removed after install |
| Install | `Scripts/install-bridge.sh` bind+advertised current LAN | `install=ok`; TLS pin prefix unchanged | LaunchAgent pid (content-free) |
| Status | `codex-watch-bridge status` | `state=running; listener=online; speech=not-determined; committed=0; retained=1` | production State root |
| Partitioned tests | `Scripts/run-swift-package-tests.sh` | `38` + `297` + `303` passed | PKCS#12 split still isolated |
| Focused tests | presentation/console/processor/installer/pairing/token filters | 97 passed | warnings-as-errors |
| Watch tests | `xcodebuild test` scheme `CodexWatch`, SE 3 40mm, clean derived data | 89 passed | simulator-proven hosted suite |
| Smoke | `Scripts/run-watch-bridge-smoke.sh` | 11 production-path tests passed | local fake Inbox only |
| Launch | `open` installed CodexWatch.app | window `Codex Watch – Allow Speech Recognition.` | UI pid 14471 + agent `run` |
| Logs | content-free `bridge.log` | last events `service-stopped` then `service-starting`/`service-running`; no new faults after this install | no memo IDs or secrets |
| Intake | retained vs intake dirs | still one retained memo from 17 Aug; intake empty | no new Watch upload this session |
| Preflight | `swift run watch-device-preflight --json` | `SUPPORTING_PHONE_UNAVAILABLE` / `blocked:external` | Apple Watch Ultra 2, watchOS 26.4 |
| Screenshots | `/tmp/codex-watch-e2e-*.png` | kept out of git | not retained in `docs/` |

## Scenario Matrix

| Surface | Scenario | Steps | Expected | Actual | Status | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Sync | new Watch memo on Mac | inspect retained/intake | new capture after on-wrist record | still only the 17 Aug retained memo | failed / blocked | intake empty; retained count 1 |
| Console | launch installed app | `open` Application Support bundle | visible Codex Watch window | titled Codex Watch; Speech CTA in chrome | verified | AX |
| Console | live bridge status | status CLI + inspector | listening on current LAN, Bonjour, pin short, pid | LAN bind; TLS pin unchanged | verified | status + launchctl |
| Console | Watch pairing truth | inspector AX | paired; `needsAttention` is not unpaired | `Paired on this Mac` | verified | AX static text |
| Console | Speech | in-app CTA | CTA; do not click system Allow | chrome `Allow Speech Recognition.`; status `not-determined` | blocked | status CLI + window title |
| Toolbar | Refresh | click | reloads | AX click succeeded | verified | AppleScript |
| Toolbar | Pairing code | click, dismiss | sheet; enter on Watch | sheet opened; dismissed with Esc; secrets not copied | verified | AX `sheets=1` then `0` |
| Toolbar | Reset | confirm then Cancel | does not wipe Watch Keychain or rotate TLS | Esc dismissed sheet; pin unchanged; still paired | verified | fingerprint file + AX |
| Destructive | Reset execute | — | not executed | not executed | not applicable | — |
| Watch | on-wrist queue | preflight | inspect queue / upload | preflight `SUPPORTING_PHONE_UNAVAILABLE` | blocked | preflight JSON |
| Codex | ChatGPT.app insert | — | do not invent | remains unverified | not applicable | — |

## Interaction Sweep

| Surface | Control | Expected | Actual | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| Toolbar | Refresh | reload | clicked | verified | AX |
| Toolbar | Reset | confirmation | sheet; dismissed | verified | AX description Reset |
| Toolbar | Pairing code | live challenge | sheet shown | verified | AX |
| Toolbar | Allow Speech Recognition | in-app request | present; system Allow not clicked | blocked | window subtitle |
| Toolbar | Save Spec… / Save HTML… | present when spec exists | both toolbar items present | verified | AX descriptions |
| Inspector | Pairing | Paired on this Mac | paired | verified | AX |
| Keyboard | Esc | dismiss sheets | pairing sheet closed | verified | AX sheets=0 |

Coverage notes:

- Menus/toolbars: Refresh, Reset, Pairing, Speech, Save Spec, Save HTML.
- Destructive execute skipped; Speech Allow skipped.
- Relaunch/persistence: after rebuild+install; TLS pin unchanged; pairing not wiped.
- Physical Watch capture, VoiceOver traversal, and a new memo arriving on Mac remain `blocked:external` / `unverified`.

## Product Quality Findings

| Category | Severity | Surface | Evidence | Product impact | Remediation | Status | Re-verification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| objective defect | high | Watch→Mac sync | no new retained/intake this session | operator never sees a new memo | hold iPhone CoreDevice tunnel; keep Watch foreground on the same LAN | blocked | preflight still `SUPPORTING_PHONE_UNAVAILABLE` |
| objective defect | high | Speech | `not-determined` on this adhoc signature | new audio cannot transcribe until Allow | operator clicks in-app CTA then system Allow | blocked | status CLI |
| contextual quality risk | medium | LaunchAgent Foundation Models | `run` wires on-device spec improvement when available | background agent may spend time on FM before App Server / local wrapper | fallback already catches errors; hang not observed | deferred | processor tests cover fallback |
| refinement | polish | AX of SwiftUI sheets | pairing/reset sheet buttons poorly exposed to AppleScript | automated cancel of Reset is brittle | operator uses Esc; confirmation still required in source | deferred | Esc dismissed pairing sheet |

## Code Review (this uncommitted pass)

Fixed or already guarded in source+tests (no open Critical/Important data-loss issues):

- Stale LAN bind is detected and rebound without rotating TLS.
- Operator Reset requires confirmation and does not wipe Watch Keychain or rotate TLS.
- Watch `needsAttention` is not treated as unpaired; unpaired idle/saved/interrupted still labels **Pair with Mac**.
- Speech stays local: `requiresOnDeviceRecognition = true` and fails if on-device is unavailable.
- Pairing phrase/code stay Mac-display / on-wrist entry.

Open residual risks are hardware/TCC, not merge-blocking source defects.

## Blocked Or Risky Actions

| Action | Why blocked / needs confirmation | Next step |
| --- | --- | --- |
| Execute Reset | regenerates pairing display | not executed |
| System Speech Allow | permission grant | operator must Allow |
| Inspect Watch queue / new capture | CoreDevice phone tunnel disconnected | hold iPhone tunnel; then `watch-device-preflight --json` |
| Merge PR #4 | physical Watch e2e not proven | keep draft; do not merge |
| Rotate TLS | operator instruction | not done; pin unchanged |

## Final Readiness Label

- Label: **`blocked:external`** for Watch→Mac new-memo delivery and physical queue inspect. Mac console is **smoke-clean** for launch/status/toolbar; Speech remains **`unverified`** until Allow. Watch hosted tests are **`simulator-proven`**.
- Evidence: installed app listening on the current LAN, TLS pin prefix unchanged; only the existing 17 Aug retained memo; preflight `SUPPORTING_PHONE_UNAVAILABLE`; Speech not determined; partitioned package tests `38 + 297 + 303` passed.
- Remaining blockers: iPhone CoreDevice tunnel; operator Speech Allow; Watch must stay on the same LAN and in the foreground to upload.
- Next audit pass: after Speech Allow + a new on-wrist capture while the listener stays on the current address; re-check retained for a second memo.
