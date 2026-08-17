# App E2E Audit Report: Codex Watch

## Scope

- Date: 2026-08-17
- Auditor: agent (rsi-ui-quality-director + rsi-app-e2e-audit-orchestrator)
- App path: `/tmp/codexwatch-e2e2/VoiceInboxBridge.app` (Developer ID, `LSBackgroundOnly=false`)
- Project/workspace/package: SwiftPM `VoiceInboxWatch` / `script/build_and_run.sh`
- Scheme/target: product `codex-watch-bridge`
- Bundle id: `ai.rsitech.voiceinbox.bridge`
- Platform/surfaces: native macOS console + menu bar; LaunchAgent listener left running
- Readiness target: interaction-clean for Mac console; hardware not `physical-watch-proven`
- Forbidden actions without confirmation: uninstall, rotate TLS, revoke Watch, purge delivered, merge/mark-ready PR #4

## Tool Plan

| Surface | Tool | Reason | Status |
| --- | --- | --- | --- |
| Build/test/logs | terminal / `swift test --filter` / `Scripts/build-bridge-app.sh` | compile, focused tests, signed UI bundle | used |
| Native app UI | AppleScript AX + screenshot helper | Computer Use MCP not available in this session | used |
| Browser/local web/webview | n/a | no web surface | not applicable |
| SwiftUI polish | rsi-swiftui-polish-auditor | hierarchy, toolbar labels, native split view | used |
| Production gates | rsi-macos-nextgen-app-builder (readiness only) | no App Store pass | used |
| Product quality | rsi-refine-product-quality | objective defects vs polish | used |

## Commands And Artifacts

| Check | Command / Tool | Result | Evidence path or note |
| --- | --- | --- | --- |
| Build | `Scripts/build-bridge-app.sh --output /tmp/codexwatch-e2e2` + Developer ID sign | ok | bundle `CFBundleName=Codex Watch`, `LSBackgroundOnly=false` |
| Tests | `swift test --filter macConsoleContractKeepsInboxPairingSpeechAndRetryAligned` plus locale/CAF/header filters | pass (3–6 tests per run) | did not rerun 585 |
| Launch | `open /tmp/codexwatch-e2e2/VoiceInboxBridge.app` | visible window titled Codex Watch | process `Codex Watch` |
| Logs | journal JSON state only | existing memo `needsAttention` → `readyForCodex` with local transcript | no user speech quoted here |
| Browser evidence | n/a | n/a | n/a |
| Computer Use evidence | AppleScript clicks | pairing, retry menu, Settings, resize, sidebar | below |
| Screenshots | screenshot skill `--app "Codex Watch"` | temp captures | `/var/folders/.../T/codex-shot-2026-08-17_13-08-28.png` (stalled), `_13-10-00.png` (pairing), `_13-11-53.png` (Settings), `_13-24-52.png` (transcript local) |

## Scenario Matrix

| Surface | Scenario | Steps | Expected | Actual | Status | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Console | first launch of this build | `open` signed UI; LaunchAgent already running | window visible; listener stays up | window Codex Watch; listener pid 14830 unchanged | verified | `ps`, AX window name |
| Console | stalled memo hierarchy | inspect header/sidebar/detail | one dominant headline; Retry once | header “Transcription did not finish.”; sidebar status+age; detail captured/audio/Retry | verified | AX + screenshot 13:08 |
| Console | branding | title, advertised, settings | Codex Watch (space) | title/menu/advertised/settings all “Codex Watch” | verified | AX, Settings dump |
| Toolbar | labeled controls + help | inspect AX help | Refresh / Pairing code / Speech with help | help strings present | verified | AX `help=` |
| Pairing | regenerate while listener online | click Pairing code | phrase+6-digit code; not “install the bridge” | certificate phrase + 6-digit code + expiry | verified | AX 13:10; TLS pin unchanged |
| Inbox | Retry transcription | Bridge menu Retry Transcription | transcribe in Speech-authorized window | journal gained local transcript; UI “Ready for Codex” | verified | journal `has_transcript=true`; AX |
| Settings | open Settings | Codex Watch → Settings… | native form of live runtime | App/Advertised/host/Watch/Listener/Speech | verified | screenshot 13:11 |
| Window | resize | set size 720×520 then 1100×720 | window resizes | size 1100,720 | verified | AppleScript |
| Sidebar | select row | click row 1 | selection remains | single row selected | verified | AX |
| Codex insert | after transcript | Retry Codex insert | Codex confirmed | journal `delivered` rev 19; spine WATCH/MAC/CODEX confirmed | verified | journal + screenshot 13:40 |
| Watch capture | new on-wrist memo this pass | record on Ultra 2 | new capture+delivery | not run this pass | not applicable | existing 17 Aug memo reused |
| Destructive | uninstall/rotate/revoke/purge | — | not clicked | not clicked | not applicable | — |

## Interaction Sweep

| Surface | Control / Gesture / Shortcut | Expected | Actual | Status | Evidence |
| --- | --- | --- | --- | --- | --- |
| Toolbar | Refresh | reloads state | labeled + help | verified | AX |
| Toolbar | Pairing code | live phrase/code | succeeded vs live fingerprint file | verified | AX |
| Toolbar | Speech | Speech CTA | Speech already allowed; not re-prompted | verified | meta row |
| Menu | Bridge → Retry Transcription | in-process retry | transcribed | verified | journal |
| Menu | Codex Watch → Settings… | settings window | opened | verified | screenshot |
| Detail | Retry transcription button | same as menu retry | present, bordered-prominent | verified | screenshot 13:08 |
| Sidebar | row select | select memo | one item | verified | AppleScript |
| Window | resize | split view survives | 1100×720 | verified | AppleScript |
| Hover | toolbar help | tooltips | AX help populated (hover not separately filmed) | verified | AX help |
| Keyboard | Cmd+, / Bridge menu | settings / retry | used | verified | AppleScript |

Coverage notes:

- Menus/toolbars/context menus: Bridge menu exercised; sidebar context Retry not clicked (menu retry used).
- Sidebars/lists/tables/cards: one memo row.
- Forms/search/settings: Settings form only.
- Sheets/popovers/alerts: none shown; no Speech dialog this pass.
- Hover/tooltips/help: AX help on toolbar.
- Keyboard shortcuts: Settings via menu; Retry via Bridge menu.
- Window resize/panel drag: size set; splitter not dragged.
- Destructive cancel/confirm: not present / not used.
- Relaunch/persistence: relaunched UI bundle; LaunchAgent left running; pairing pin unchanged.

## Product Quality Findings

| Category | Severity | Surface | Evidence | Product impact | Remediation | Status | Re-verification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| objective defect | blocker | Pairing | “Install the bridge” while listener online | cannot pair from sidecar UI | generate phrase from fingerprint file | verified | pairing click 13:10 |
| objective defect | blocker | Transcription | `en_PL` + CAF-in-`.m4a` + mailbox ignored by old listener + Speech TCC on sidecar | memo stuck `needsAttention` | locale fallback, CAF `.caf` copy, in-process retry | verified | journal transcript present |
| objective defect | high | Hierarchy | status triple-repeated | unreadable dominant state | one header headline; sidebar age only; detail facts/Retry | verified | screenshot 13:08 vs user shots |
| objective defect | medium | Toolbar | icon-only unlabeled | unknown actions | titleAndIcon + `.help` | verified | AX |
| objective defect | medium | Branding | `CodexWatch` | not requested product name | `Codex Watch` | verified | window/menu/settings |
| objective defect | high | Codex insert | stale `Codex Voice Inbox` thread on `/tmp` cwd made `resolveInbox` throw `targetMismatch` | Inbox never confirmed | skip same-name threads whose cwd is not this Mac’s inbox; retry insert from the memo | verified | journal `delivered` |
| contextual quality risk | polish | Header kicker | small “MAC” beside headline | mild redundancy with spine | deferred | deferred | — |

## Findings

| Severity | Area | Finding | Proof | Fix | Re-verification |
| --- | --- | --- | --- | --- | --- |
| blocker | pairing | sidecar Keychain TLS blocked `pair` | user screenshot | fingerprint file + PairingStore | generated live code |
| blocker | speech | locale `en_PL` unsupported; CAF named `.m4a`; old listener ignores mailbox | journal + `afinfo` caff + strings of installed binary | fallback + `.caf` copy + GUI `retryMemoNow` | transcript local |
| high | Codex | stale named thread on `/tmp` cwd | live `thread/list` | ignore foreign cwd; retry insert | journal `delivered` |
| polish | header | kicker “MAC” | screenshot | deferred | — |

## Blocked Or Risky Actions

| Action | Why blocked / needs confirmation | Next step |
| --- | --- | --- |
| Replace installed LaunchAgent binary | new signature cannot load existing Keychain TLS; no PKCS#12 export | keep pid 14830; persist p12 when a process that can read the identity is running |
| New Watch capture this pass | CoreDevice preflight `SUPPORTING_PHONE_UNAVAILABLE` | hold iPhone tunnel, then capture |
| Merge / mark ready PR #4 | user forbid | leave draft |

## Final Readiness Label

- Label: `unverified`
- Evidence: existing Watch memo transcribed and Codex Inbox insert confirmed (`delivered`) in the Codex Watch window. No new on-wrist capture this pass (`SUPPORTING_PHONE_UNAVAILABLE`). Isolated CLI smoke remains unverified for official-client UX. TLS pin unchanged. Draft PR #4 untouched.
- Remaining blockers: installed listener still old until identity-safe reinstall; new Watch capture blocked on the iPhone CoreDevice tunnel.
- Next audit pass: persist PKCS#12, reinstall listener, new Watch capture.
