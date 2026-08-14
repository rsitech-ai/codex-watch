# Physical Apple Watch Acceptance

This checklist is the hardware acceptance gate for Voice Inbox. It does not
promote source inspection, previews, simulator tests, or bridge packaging into
physical-Watch proof. Use synthetic, non-confidential speech and test data.

## Evidence rules

- Allowed readiness labels are `source-inspected`, `preview-reviewed`,
  `simulator-proven`, `physical-watch-proven`, `package-ready`, `unverified`,
  and `blocked:external`.
- Record public Watch model and OS only. Do not retain device identifiers,
  serial numbers, ECIDs, hostnames, Apple account data, pairing secrets,
  fingerprints, credentials, audio, transcripts, Codex task identifiers, or
  private filesystem paths.
- A screenshot or log reference must be content-free and privacy-reviewed
  before it is retained.
- Lost audio, a misleading delivery claim, duplicate Codex acceptance, a crash,
  inaccessible primary control, primary-action clipping, or private-content
  leakage is a blocker.
- Destructive confirmations use disposable synthetic audio. If the operator
  does not perform the confirmation, record it as `unverified` rather than
  silently omitting it.

## Device and preparation

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Read-only device preflight | One physical Watch is paired, Developer Mode is enabled, supporting iPhone is ready, Watch tunnel is connected, and DDI is available | Watch and iPhone visible, paired, and Developer Mode enabled; both CoreDevice tunnels disconnected; Watch lock state unobserved | `watch-device-preflight`, 2026-08-14; code `SUPPORTING_PHONE_UNAVAILABLE` plus redacted inventory review | Blocked | `blocked:external` |
| First signed development build | Xcode reaches the signing/provisioning boundary only after preflight `READY` | Not run | Operator build log | Unverified | `unverified` |
| First install | Exact branch build installs on the named public model/OS | Not run | Xcode device log plus operator observation | Unverified | `unverified` |
| Cold launch | App launches without crash and shows truthful setup/ready state | Not run | Content-free device log plus observation | Unverified | `unverified` |
| Relaunch | State remains truthful after force-quit and relaunch | Not run | Content-free device log plus observation | Unverified | `unverified` |

## Capture and durable queue

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Microphone permission granted | Prompt appears only from the user action; granting permits capture | Not run | Operator observation | Unverified | `unverified` |
| Microphone permission denied | No recording or saved claim appears; safe recovery guidance is visible | Not run | Operator observation | Unverified | `unverified` |
| Recording start | Primary action starts capture with truthful recording state and haptic response | Not run | Observation plus content-free log | Unverified | `unverified` |
| Duration warning | Final-minute warning and bounded duration remain legible on wrist | Not run | Observation | Unverified | `unverified` |
| Recording stop | Stop commits the synthetic recording before showing saved state | Not run | Observation plus queue state | Unverified | `unverified` |
| Durable queue visibility | Saved synthetic item remains visible after relaunch while bridge is absent | Not run | Relaunch observation | Unverified | `unverified` |
| Interrupted capture recovery | Relaunch recovers a safely recoverable interrupted recording without inventing success | Not run | Observation plus content-free log | Unverified | `unverified` |

## Pairing and network recovery

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Bridge absent or offline | Audio remains queued and status explains that delivery is waiting | Not run | Watch observation | Unverified | `unverified` |
| Bridge reconnect | Queue resumes safely without duplicate upload or lost audio | Not run | Watch and bridge content-free logs | Unverified | `unverified` |
| Retry timing | Backoff prevents a tight retry loop and resumes after the expected window | Not run | Timestamp-only diagnostic codes | Unverified | `unverified` |
| Certificate phrase comparison | Watch and bridge show the same human phrase before code entry | Not run | Operator comparison; no raw fingerprint retained | Unverified | `unverified` |
| Invalid pairing code | Invalid code is rejected without revealing credential state | Not run | Operator observation | Unverified | `unverified` |
| Expired pairing code | Expired code is rejected and recovery requests a new code | Not run | Operator observation | Unverified | `unverified` |
| Successful pairing | Pairing succeeds without printing or retaining the token or raw fingerprint | Not run | Redacted status plus observation | Unverified | `unverified` |
| Local-network upload | Synthetic audio reaches the selected bridge over authenticated local HTTPS | Not run | Content-free bridge/Watch status | Unverified | `unverified` |
| Bridge acknowledgement | Watch advances only to received after the durable bridge acknowledgement | Not run | Watch state plus diagnostic code | Unverified | `unverified` |

## Speech, Codex reconciliation, and final acknowledgement

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| macOS Speech permission granted | Explicit operator prompt grants local recognition | Not run | Operator observation | Unverified | `unverified` |
| macOS Speech permission denied | Bridge keeps recoverable audio and exposes the safe System Settings action | Not run | Content-free bridge status | Unverified | `unverified` |
| Local transcription | Synthetic audio is transcribed locally; raw audio is never sent to Codex | Not run | Local status and privacy-reviewed observation | Unverified | `unverified` |
| No cloud-audio fallback | Unsupported/failed local recognition remains a recoverable failure | Not run | Network/log review without content | Unverified | `unverified` |
| Ambiguous Codex acceptance | Possible acceptance enters reconciliation and does not blindly resubmit | Not run | Closed journal/diagnostic state | Unverified | `unverified` |
| Exactly-once reconciliation | Authoritative history yields one marker and no duplicate insertion | Not run | Disposable-task observation, separately authorized | Unverified | `unverified` |
| Final acknowledgement | Verified delivery appears on Watch only after bridge terminal truth | Not run | Watch state plus bridge diagnostic code | Unverified | `unverified` |

## Playback, deletion, and retention

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Local playback | Synthetic queued/delivered audio plays without changing delivery truth | Not run | Operator observation | Unverified | `unverified` |
| Delete cancellation | Cancelling preserves audio and metadata | Not run | Before/after observation | Unverified | `unverified` |
| Delete confirmation | Confirming removes only the selected disposable synthetic item | Not run | Before/after observation | Unverified | `unverified` |
| Retention change | 1/7/30-day choice persists and immediately reconsiders delivered items only | Not run | Relaunch observation | Unverified | `unverified` |

## Lifecycle and environment changes

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Watch restart | Queue and pairing barrier survive restart; maintenance resumes safely | Not run | Observation plus content-free status | Unverified | `unverified` |
| Mac restart | Durable intake/journal recover before listener admission | Not run | Content-free bridge status | Unverified | `unverified` |
| Login restart | Installed bridge returns healthy without duplicate delivery | Not run | LaunchAgent and bridge status | Unverified | `unverified` |
| Sleep and wake | Pending work resumes without spin, loss, or false success | Not run | Timestamp-only diagnostics | Unverified | `unverified` |
| Network change | Address loss/change preserves queued audio and requires truthful recovery | Not run | Watch/bridge status | Unverified | `unverified` |

## Layout and accessibility

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Smallest supported Watch | Primary action/status never clips at the smallest supported display | Seven deterministic scenes reviewed without observed core-state or primary-action clipping; physical observation not run | [Simulator matrix evidence](evidence/2026-08-14-signal-spine-simulator-matrix.md) | Passed in simulator | `simulator-proven` |
| Representative Watch | Core capture, delivery, attention, queue, and pairing scenes remain coherent | Seven deterministic scenes reviewed on 42, 44, and 46 mm; physical observation not run | [Simulator matrix evidence](evidence/2026-08-14-signal-spine-simulator-matrix.md) | Passed in simulator | `simulator-proven` |
| Largest Watch | Added space improves readability without changing semantics | Seven deterministic scenes reviewed on 49 mm; physical observation not run | [Simulator matrix evidence](evidence/2026-08-14-signal-spine-simulator-matrix.md) | Passed in simulator | `simulator-proven` |
| Accessibility text sizes | Essential state and primary controls remain usable at supported larger text sizes | Not run | Simulator plus physical observation | Unverified | `unverified` |
| VoiceOver | Order, labels, values, hints, adjustable controls, and destructive confirmation are understandable | State, relay path, primary action, and secondary navigation sort policy verified in code/tests; runtime focus traversal not run | Watch tests plus physical VoiceOver observation | Partially proven | `unverified` |
| Increase Contrast | Controls and status remain distinguishable | Not run | Simulator plus physical observation | Unverified | `unverified` |
| Differentiate Without Color | State never depends on color alone | Shape-redundant nodes verified by code/tests; setting-specific runtime observation not run | Watch tests; later physical observation required | Partially proven | `unverified` |
| Reduce Transparency | Content remains legible without material transparency | Not run | Simulator observation | Unverified | `unverified` |
| Reduce Motion | State remains clear and no essential meaning depends on animation | Immediate motion policy verified by test; setting-specific runtime observation not run | Watch tests; later physical observation required | Partially proven | `unverified` |

## Runtime and privacy review

| Scenario | Expected | Actual | Evidence | Status | Readiness label |
| --- | --- | --- | --- | --- | --- |
| Crash review | No Watch or bridge crash occurs during the complete workflow | Not run | Content-free crash log review | Unverified | `unverified` |
| Repeated-failure review | No tight loop or unbounded repeated failure appears | Not run | Closed diagnostic codes and timestamps | Unverified | `unverified` |
| Content-leakage review | Logs contain no audio, transcript, identifiers, credentials, or private paths | Not run | Privacy-reviewed logs | Unverified | `unverified` |
| Success-truth review | Saved, received, and delivered copy matches the durable state boundary exactly | Not run | State-by-state observation | Unverified | `unverified` |

## Completion rule

Physical acceptance is `physical-watch-proven` only for rows actually exercised
on the recorded public Watch model/OS. Open rows retain `unverified` or
`blocked:external`; completing one row does not promote another.
