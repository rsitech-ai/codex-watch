# Signal Spine Watch Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved Signal Spine capture, relay-ledger, pairing, motion, and accessibility experience while preserving the authoritative Watch-to-Mac-to-Codex state model and producing named simulator evidence for every installed supported display size.

**Architecture:** Add a pure presentation layer that maps existing capture, bridge, and memo states into semantic copy, tones, actions, and three-node spine states. SwiftUI components render those immutable presentations; `VoiceCaptureModel` remains the workflow owner. A Debug-only scenario router renders production components with deterministic data, and the simulator selector gains an all-display-sizes mode for repeatable 40/42/44/46/49mm evidence.

**Tech Stack:** Swift 6, SwiftUI, watchOS 10+, XCTest, Swift Testing, Xcode/watchOS Simulator, `simctl`, and the existing XcodeGen project structure.

## Global Constraints

- Preserve watchOS 10.0 and add no external dependency.
- Keep `VoiceCaptureModel`, `WatchMemoStore`, and transfer coordinators authoritative; presentation code must not create workflow state.
- `Saved on Watch` never implies Mac receipt or Codex delivery.
- Advance nodes only from authoritative state; no waveform, sensor value, network percentage, or estimated progress.
- Recording remains tap-to-start and tap-to-stop.
- Keep the primary action visible without scrolling on every installed supported size.
- Motion is bounded and has a Reduce Motion replacement; idle has no perpetual animation.
- Color is redundant with copy, symbols, fill, or position.
- Debug scenarios compile out of Release and contain no transcript, audio, credential, identifier, or private-path content.
- After adding a Watch source file, run `xcodegen generate --spec project.yml` and review the generated project diff; never hand-edit generated project membership.
- Resolve the smallest test destination through `watch-simulator-selector --format shell` and use its validated UDID because simulator names may be duplicated.
- Simulator evidence remains separate from physical microphone, haptic, energy, Always On, and paired-device proof.
- Do not push, publish, open a pull request, or mutate external services.

## File Structure

- Create `WatchExperiencePresentation.swift`, `WatchExperienceTheme.swift`, `SignalSpineView.swift`, `WatchPrimaryActionView.swift`, `CaptureScene.swift`, `RelayLedgerRow.swift`, and `WatchRenderScenario.swift` under `WatchApp/`.
- Modify `ContentView.swift`, `QueueView.swift`, `PairingView.swift`, `RetentionSettingsView.swift`, and `CodexWatchApp.swift`.
- Modify `VoiceCaptureModelTests.swift` for pure presentation and behavior regressions.
- Extend `WatchSimulatorSelector` and its CLI/tests with stable all-size selection.
- Create `Scripts/capture-watch-ui-evidence.sh` and its shell contract test.
- Add the simulator evidence summary and update physical acceptance without overclaiming hardware proof.

---

### Task 1: Pure presentation contract

**Files:**
- Create: `WatchApp/WatchExperiencePresentation.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Consumes: `WatchCaptureState`, `WatchCaptureFailure`, `WatchBridgeConnectionState`, `WatchQueueItem`, and `MemoState`.
- Produces: `WatchExperienceTone`, `SignalNodeVisualState`, `SignalSpinePresentation`, `WatchPrimaryAction`, `CaptureScenePresentation.make(captureState:bridgeState:)`, `RelayItemPresentation.make(item:)`, and `SignalMotionStyle.forTransition(reduceMotion:)`.

- [x] **Step 1: Write the failing capture-truth test**

```swift
func testCapturePresentationNeverPromotesLocalSaveToMacOrCodex() throws {
    let memoID = try MemoID("11111111-1111-1111-1111-111111111111")
    let value = CaptureScenePresentation.make(
        captureState: .savedOnWatch(memoID),
        bridgeState: .waiting("Studio Mac")
    )
    XCTAssertEqual(value.spine.watch, .confirmed)
    XCTAssertEqual(value.spine.mac, .pending)
    XCTAssertEqual(value.spine.codex, .pending)
    XCTAssertEqual(value.spine.accessibilityValue, "Saved on Watch; waiting for Mac")
}
```

Add table rows for idle, preparing, recording, saving, permission denied, interrupted recording, and every capture failure.

- [x] **Step 2: Run the focused test and verify RED**

```bash
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'id=33E70F70-2895-4F8E-8CFB-AFD04684631D' \
  -only-testing:CodexWatchTests/VoiceCaptureModelTests/testCapturePresentationNeverPromotesLocalSaveToMacOrCodex
```

Expected: compilation fails because `CaptureScenePresentation` is undefined.

The shown UDID is the selector result observed on 2026-08-14. Re-resolve it before execution and use the current validated identifier if inventory changes.

- [x] **Step 3: Implement exhaustive capture mapping**

Use exact approved copy. Recording activates only Watch; saving activates only Watch; saved confirms only Watch. Remote bridge copy remains secondary and never changes local-capture provenance.

After adding the file, run `xcodegen generate --spec project.yml` so the Watch target and test host compile the new source.

- [x] **Step 4: Write and implement the failing memo-state table**

Test all nine memo states. Watch is confirmed for stored items; Mac becomes confirmed at `.received`; Codex becomes confirmed only at `.delivered`. Because `.needsAttention` does not retain its predecessor, expose `Needs attention; last remote phase unavailable` instead of inventing provenance.

- [x] **Step 5: Add and test motion policy**

Assert Reduce Motion maps to `.immediate` and normal motion maps to `.bounded(duration: 0.24)`.

- [x] **Step 6: Run all Watch tests and commit**

```bash
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' \
  -only-testing:CodexWatchTests
git add WatchApp/WatchExperiencePresentation.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "feat: define truthful Watch experience presentation"
```

Expected: all Watch tests pass and the commit contains only the pure contract and tests.

### Task 2: Semantic components

**Files:**
- Create: `WatchApp/WatchExperienceTheme.swift`
- Create: `WatchApp/SignalSpineView.swift`
- Create: `WatchApp/WatchPrimaryActionView.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Consumes: Task 1 presentation types.
- Produces: semantic tone colors, `SignalSpineView(presentation:reduceMotion:)`, `WatchPrimaryActionView(action:tone:disabled:handler:)`, and pure `SignalSpineAccessibility` helpers.

- [x] **Step 1: Write the failing accessibility test**

```swift
func testSignalSpineAccessibilityCombinesDecorativeNodes() {
    let spine = SignalSpinePresentation(
        watch: .confirmed, mac: .active, codex: .pending,
        accessibilityValue: "Saved on Watch; sending to Mac; Codex pending"
    )
    XCTAssertEqual(SignalSpineAccessibility.label, "Delivery path")
    XCTAssertEqual(SignalSpineAccessibility.value(for: spine), spine.accessibilityValue)
}
```

- [x] **Step 2: Verify RED, then implement components**

Hide line segments and individual nodes from accessibility and combine the spine into one element. Apply animation only with `presentation` as the value. Map primary actions to exact labels: `Tap to record`, `Stop & save`, `Pair with Mac`, `Retry relay`, and `Record another`.

- [x] **Step 3: Build the smallest destination and commit**

```bash
xcodebuild -quiet build-for-testing -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' CODE_SIGNING_ALLOWED=NO
git add WatchApp/WatchExperienceTheme.swift WatchApp/SignalSpineView.swift \
  WatchApp/WatchPrimaryActionView.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "feat: add Signal Spine Watch components"
```

Expected: build succeeds without availability warnings below watchOS 10.

Completed at `b2cd804`. The focused RED failed on the missing accessibility
helper, the focused GREEN passed, all 67 Watch tests passed on the
selector-resolved 40mm simulator, and `build-for-testing` completed without
warnings. XcodeGen was run through the canonical `codex-watch` symlink so the
local package identity did not inherit the linked-worktree basename.

### Task 3: Adaptive capture scene

**Files:**
- Create: `WatchApp/CaptureScene.swift`
- Modify: `WatchApp/ContentView.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Consumes: production presentation, model timer/action APIs, spine, primary control, navigation closures, and SwiftUI `isLuminanceReduced`.
- Produces: `CaptureScene`, pure `CaptureElapsedTime.text(start:now:maximumDuration:)`, `CapturePrivacyMode`, and compact/regular variants selected by `ViewThatFits`.

- [x] **Step 1: Write failing elapsed-time and action tests**

```swift
func testCaptureElapsedTimeClampsAtProtocolLimit() {
    let start = Date(timeIntervalSince1970: 100)
    XCTAssertEqual(
        CaptureElapsedTime.text(start: start, now: start.addingTimeInterval(901), maximumDuration: 900),
        "15:00"
    )
}
```

Also assert recording uses `.stopAndSave` while Mac and Codex nodes remain pending. Add a pure privacy test that reduced-luminance mode retains only state, elapsed duration, a dim spine, and the essential action label while suppressing secondary detail.

- [x] **Step 2: Verify RED, then build the compact-first scene**

Both `ViewThatFits` variants include state header, spine plus hero/timer, fixed primary action, and compact ledger link. Keep retention outside the capture hierarchy. Remove the repeating symbol pulse. Keep the one-second timeline only while recording; numeric transition becomes identity under Reduce Motion. Read `isLuminanceReduced`; dim the spine and omit secondary detail in that mode without adding memo content or transcript text.

- [x] **Step 3: Wire actions without new workflow APIs**

Record/stop/record-another call `toggleRecording()`. Pairing navigates. Retry calls the existing foreground refresh path. Do not add transfer side effects to the view.

- [x] **Step 4: Test, build 40mm and 49mm, and commit**

```bash
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -only-testing:CodexWatchTests
xcodebuild -quiet build-for-testing -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 3 (49mm)' CODE_SIGNING_ALLOWED=NO
git add WatchApp/CaptureScene.swift WatchApp/ContentView.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "feat: redesign Watch capture around Signal Spine"
```

Expected: tests/builds pass and `rg` finds no repeating symbol effect.

Completed at `f424b65`. The elapsed-time/privacy RED failed on the missing pure
types; all 69 Watch tests passed on the selector-resolved 40mm simulator, the
49mm build-for-testing passed, and the repeating pulse scan was empty. Live
40mm/49mm renders were inspected at
`codex-watch-signal-spine-task3-2026-08-14/`; the first render exposed clipped
system chrome, and the accepted render keeps the complete primary action above
the rounded lower edge on 40mm while preserving all three utility routes.

### Task 4: Relay ledger

**Files:**
- Create: `WatchApp/RelayLedgerRow.swift`
- Modify: `WatchApp/QueueView.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Consumes: relay presentation, playback state, existing playback/delete actions, and deletion copy.
- Produces: `RelayLedgerRow` and `RelayLedgerSummary(count:)`.

- [x] **Step 1: Write failing ledger tests**

Assert one/plural count accessibility, all nine memo-state labels, and that needs-attention does not invent its previous remote phase.

- [x] **Step 2: Verify RED, then implement the ledger**

Use a chronological connecting rule, explicit status, and relative capture time. Do not invent duration because `WatchQueueItem` does not expose it. Keep playback in row details and destructive deletion behind the current confirmation dialog.

- [x] **Step 3: Run playback/deletion regressions and commit**

```bash
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -only-testing:CodexWatchTests
git add WatchApp/RelayLedgerRow.swift WatchApp/QueueView.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "feat: present saved ideas as a relay ledger"
```

Expected: playback serialization, deletion cancellation, retention, and attention tests remain green.

Completed at `914521d`. The count-vocabulary RED failed on the missing ledger
summary; all 70 Watch tests then passed on the selector-resolved 40mm
simulator. The chronological rule, exact relative capture time, presentation
status/detail, playback action, and existing confirmation dialog are retained
without adding a duration field or guessing the last remote phase.

### Task 5: Pairing and retention

**Files:**
- Modify: `WatchApp/WatchExperiencePresentation.swift`
- Modify: `WatchApp/PairingView.swift`
- Modify: `WatchApp/RetentionSettingsView.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Produces: `PairingVisualStep` and `PairingStepsPresentation.make(selectedBridge:fingerprintConfirmed:paired:)`.

- [x] **Step 1: Write the failing identity-step test**

```swift
func testPairingStepsNeverSkipIdentityConfirmation() {
    XCTAssertEqual(
        PairingStepsPresentation.make(selectedBridge: true, fingerprintConfirmed: false, paired: false).current,
        .identity
    )
    XCTAssertEqual(
        PairingStepsPresentation.make(selectedBridge: true, fingerprintConfirmed: true, paired: false).current,
        .code
    )
}
```

- [x] **Step 2: Verify RED, then implement step composition**

Keep bridge discovery, exact phrase comparison, explicit `Fingerprint Matches`, sanitized six-digit code, pairing, failure, and forget behavior. Raw fingerprints never enter combined accessibility summaries.

- [x] **Step 3: Polish retention without policy changes**

Keep the platform picker and existing choices. State that only confirmed delivered audio is eligible and unresolved recordings remain on Watch.

- [x] **Step 4: Run all Watch tests and commit**

```bash
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -only-testing:CodexWatchTests
git add WatchApp/WatchExperiencePresentation.swift WatchApp/PairingView.swift \
  WatchApp/RetentionSettingsView.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "feat: extend Signal Spine through pairing"
```

Expected: Pair again, saved-credential escape hatch, rejected upload, and retention regressions pass.

Completed at `7bd1375`. The identity-gate RED failed on the missing pairing
presentation; all 71 Watch tests passed on 40mm after implementation. The
visual rail advances from Mac discovery to identity, code, and paired without
skipping explicit fingerprint confirmation. The exact phrase remains exposed
only in its dedicated comparison element, not the combined progress summary.
Retention keeps the same picker and policy while stating the delivered-only
cleanup boundary explicitly.

### Task 6: Deterministic Debug render scenarios

**Files:**
- Create: `WatchApp/WatchRenderScenario.swift`
- Modify: `WatchApp/CodexWatchApp.swift`
- Modify: `WatchApp/SignalSpineView.swift`
- Modify: `WatchAppTests/VoiceCaptureModelTests.swift`

**Interfaces:**
- Produces: allowlisted `WatchRenderScenario` cases `ready`, `recording`, `savedOnWatch`, `delivered`, `needsAttention`, `queue`, and `pairing`; Debug-only `WatchRenderScenarioRoot`.

- [x] **Step 1: Write the failing parser test**

```swift
func testRenderScenarioParserAcceptsOnlyAllowlistedValues() {
    XCTAssertEqual(
        WatchRenderScenario.parse(environment: ["CODEX_WATCH_RENDER_SCENARIO": "recording"]),
        .recording
    )
    XCTAssertNil(WatchRenderScenario.parse(environment: ["CODEX_WATCH_RENDER_SCENARIO": "../../private"]))
    XCTAssertEqual(WatchRenderScenario.allCases.count, 7)
}
```

- [x] **Step 2: Verify RED, then implement Debug-only routing**

If the variable is absent or invalid, launch normal `ContentView`. Fixtures use only `Studio Mac`, fixed `0:18`, fixed `10:10`, and public status copy. Release does not reference the environment key or scenario root.

- [x] **Step 3: Prove bounded motion and both configurations**

```bash
rg -n 'repeatForever|\.repeating|symbolEffect\(.+repeating' WatchApp
xcodebuild -quiet build-for-testing -project CodexWatch.xcodeproj -scheme CodexWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild -quiet build -project CodexWatch.xcodeproj -scheme CodexWatch \
  -configuration Release -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: no perpetual-motion match and both configurations build.

- [x] **Step 4: Commit render support**

```bash
git add WatchApp/WatchRenderScenario.swift WatchApp/CodexWatchApp.swift \
  WatchApp/SignalSpineView.swift WatchAppTests/VoiceCaptureModelTests.swift
git commit -m "test: add deterministic Watch render scenarios"
```

Completed at `0bf637d`. The parser RED failed on the missing allowlisted type;
all 72 Watch tests then passed on 40mm. Debug build-for-testing and Release
build both passed, the perpetual-motion scan was empty, and the Release
executable contained neither the environment key nor scenario-root symbol.
Recording, queue, and pairing fixtures were launched through `simctl` on 40mm
and visually inspected under `codex-watch-signal-spine-scenario-smoke-2026-08-14/`.
Fixtures contain only fixed public copy, `Studio Mac`, `0:18`, and `10:10`.

### Task 7: All-size selection and screenshot capture

**Files:**
- Modify: `Sources/WatchSimulatorSelection/WatchSimulatorSelector.swift`
- Modify: `Sources/WatchSimulatorSelectorCLI/WatchSimulatorSelectorCommand.swift`
- Modify: `Tests/WatchSimulatorSelectionTests/WatchSimulatorSelectorTests.swift`
- Modify: `Tests/WatchSimulatorSelectorCLITests/WatchSimulatorSelectorCommandTests.swift`
- Create: `Scripts/capture-watch-ui-evidence.sh`
- Create: `Tests/CIContractTests/watch_ui_evidence_contract_test.sh`

**Interfaces:**
- Produces: `selectEachDisplaySize(activeSDK:runtimes:devices:)`, CLI `--all-sizes --format json`, and script arguments `--app <absolute .app> --output <absolute absent-or-empty directory>`.

- [x] **Step 1: Write failing stable-size tests**

```swift
func testSelectEachDisplaySizeReturnsOneStableDestinationPerSize() throws {
    let values = try WatchSimulatorSelector.selectEachDisplaySize(
        activeSDK: "26.5", runtimes: exactRuntimeFixtures,
        devices: devicesFor40_42_44_46_49WithDuplicates
    )
    XCTAssertEqual(values.map(\.displayMillimeters), [40, 42, 44, 46, 49])
}
```

Also cover duplicate UDID, unknown size, unavailable device, runtime mismatch, and stable ties.

- [x] **Step 2: Verify RED and implement shared exact-runtime selection**

Keep existing `select` output unchanged. Group validated destinations by millimeters, choose name then identifier stably, and return ascending sizes with rationale `one-stable-destination-per-display-on-exact-active-runtime`.

- [x] **Step 3: Add strict JSON CLI mode and tests**

Accept only the new exact argument list or existing `--format shell`. JSON contains public name, UDID, runtime, size, and rationale. Extra or reordered flags return usage 64.

- [x] **Step 4: Write the failing shell contract, then the script**

The test proves the script rejects relative paths, non-app inputs, and nonempty outputs; covers all seven scenarios per size; uses bounded waits; never erases a simulator; and emits content-free filenames/manifests. The script boots if required, installs the app, launches through `SIMCTL_CHILD_CODEX_WATCH_RENDER_SCENARIO`, captures with `simctl io screenshot`, terminates only this app, hashes images, and fails on any missing cell.

- [x] **Step 5: Run contracts and commit**

```bash
swift test --filter WatchSimulatorSelectionTests
swift test --filter WatchSimulatorSelectorCLITests
bash Tests/CIContractTests/watch_ui_evidence_contract_test.sh
git add Sources/WatchSimulatorSelection Sources/WatchSimulatorSelectorCLI \
  Tests/WatchSimulatorSelectionTests Tests/WatchSimulatorSelectorCLITests \
  Scripts/capture-watch-ui-evidence.sh Tests/CIContractTests/watch_ui_evidence_contract_test.sh
git commit -m "test: capture Watch UI across every display size"
```

Expected: existing shell mode remains compatible and all new contracts pass.

Completed at `cadb0b8`. Fifteen focused selector/CLI tests pass, including
duplicate identifiers, unknown sizes, unavailable devices, stable ties, exact
runtime matching, and strict/reordered argument rejection. The dynamic shell
contract produces 35 content-free fixture images, rejects unsafe inputs and
nonempty outputs, bounds a hung simulator command, and confirms no destructive
simulator operation. Live selection resolves one stable watchOS 26.5 device
for each installed 40/42/44/46/49mm size.

### Task 8: Full proof and documentation

**Files:**
- Create: `docs/evidence/2026-08-14-signal-spine-simulator-matrix.md`
- Modify: `docs/PHYSICAL-WATCH-ACCEPTANCE.md`
- Modify: `plans/active/2026-08-14-signal-spine-watch-experience.md`

- [x] **Step 1: Run complete regressions**

```bash
git diff --check
swift test
xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch \
  -destination 'platform=watchOS Simulator,id=<selector-resolved-watchOS-26.5-40mm-identifier>' -only-testing:CodexWatchTests
xcodebuild -quiet build-for-testing -project CodexWatch.xcodeproj -scheme CodexWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild -quiet build -project CodexWatch.xcodeproj -scheme CodexWatch \
  -configuration Release -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass and both configurations build.

- [x] **Step 2: Capture and inspect the matrix**

Write into a new directory under `/Users/s1kor/.codex/visualizations/2026/08/14/signal-spine-<short-sha>/`. On the current watchOS 26.5 inventory, expect 35 PNGs: seven scenarios on 40, 42, 44, 46, and 49mm. Inspect every image for clipping, truncation, system-time/corner overlap, redundant state encoding, action density, secrets, and fabricated data. Repair and recapture failed cells.

- [x] **Step 3: Exercise accessibility**

On 40mm and 49mm inspect Reduce Motion, Increase Contrast, Differentiate Without Color, Reduce Transparency, VoiceOver order, bold text, and largest available accessibility text. Record observation or `unverified`; never infer a pass.

- [x] **Step 4: Run physical readiness**

```bash
swift run watch-device-preflight
```

On `READY`, run only authorized non-destructive install, launch, synthetic capture, haptic, and Always On checks. Otherwise retain the closed code and label hardware scope `blocked:external` or `unverified`.

- [x] **Step 5: Write evidence, update progress, and re-run final checks**

Record source SHA, SDK/runtime, public device names/sizes, scenario count, command results, screenshot directory, accessibility observations, and remaining physical gates. Then run `swift test`, `git diff --check`, `git status --short`, and review the branch diff.

- [x] **Step 6: Commit documentation**

```bash
git add docs/evidence/2026-08-14-signal-spine-simulator-matrix.md \
  docs/PHYSICAL-WATCH-ACCEPTANCE.md plans/active/2026-08-14-signal-spine-watch-experience.md
git commit -m "docs: retain Signal Spine Watch evidence"
```

Expected: repository/test, simulator, accessibility, and physical layers are reported separately with no push or PR.

## Plan Self-Review Checklist

- [x] Every approved design section maps to a task.
- [x] Interface names are consistent across tasks.
- [x] Views never own workflow truth.
- [x] Local save, Mac receipt, and Codex delivery remain distinct.
- [x] All five installed display sizes and seven scenarios are covered.
- [x] Motion, Reduce Motion, accessibility, privacy, and physical boundaries have explicit gates.
- [x] Scene commits can roll back without queue or credential migration.
