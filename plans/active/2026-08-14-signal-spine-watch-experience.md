# Signal Spine Watch Experience

## Goal

- User-visible outcome: Voice Inbox becomes a distinctive Signal Spine relay instrument whose capture action is immediately reachable and whose Watch, Mac, and Codex states never overclaim progress.
- How to see it working: launch deterministic Debug scenarios on the installed watchOS simulator matrix and inspect ready, recording, saved-on-Watch, delivered, needs-attention, queue, and pairing screens.

## Current State

- Relevant paths:
  - approved design: `docs/superpowers/specs/2026-08-14-signal-spine-watch-experience-design.md`;
  - detailed TDD plan: `docs/superpowers/plans/2026-08-14-signal-spine-watch-experience.md`;
  - production Watch UI: `WatchApp/`;
  - Watch tests: `WatchAppTests/VoiceCaptureModelTests.swift`;
  - simulator policy: `Sources/WatchSimulatorSelection/`.
- Existing behavior: state and persistence truth are robust, but the generic home clips the primary action on the 40mm and 44mm baseline and uses perpetual recording pulse motion.
- Constraints:
  - branch `feat/andrzej_signal_spine_watch_ui` is based on evidence-hardening commit `213604fb`;
  - baseline is 578 tests passed, zero failures;
  - watchOS deployment target remains 10.0;
  - no external dependencies, fabricated telemetry, publication, push, or PR;
  - physical-device evidence is separate from simulator evidence.

## Target State

- Desired behavior:
  - pure mapping from authoritative capture, bridge, and memo state to semantic presentation;
  - persistent three-node Watch/Mac/Codex spine;
  - compact-first capture scene with fixed primary action;
  - queue presented as a relay ledger;
  - pairing uses the same step language without weakening identity checks;
  - motion is bounded and has an immediate Reduce Motion path;
  - deterministic Debug scenarios provide content-free runtime renders;
  - one stable simulator destination per installed supported size is captured.
- Non-goals:
  - changing bridge protocol, persistence, transfer, transcription, or delivery semantics;
  - adding waveform/audio metering, sensors, network percentages, cloud audio, or a new visual dependency;
  - claiming physical Watch proof from simulator work.

## Risks and Failure Modes

- Presentation mapping could promote saved or processing states; exhaustive table-driven tests must fail closed.
- Compact composition could clip under system time, accessibility text, or rounded corners; every installed size needs rendered review.
- Timer updates could restart spine animation; animation values must exclude clock ticks.
- Debug scenario plumbing could leak into Release; guard it with `#if DEBUG` and build both configurations.
- Queue redesign could regress playback/deletion concurrency; keep existing tests green.
- Physical Watch readiness may remain externally blocked; retain the closed code and do not overstate proof.

## Milestones

### M1. Truthful presentation layer

- Goal: encode capture, bridge, memo, pairing, action, accessibility, and motion semantics as pure values.
- Files / systems: `WatchExperiencePresentation.swift`, Watch tests.
- Changes: exhaustive mappings with no side effects or payload inspection.
- Verification: focused RED/GREEN tests followed by all Watch tests on 40mm.
- Expected result: saved-on-Watch cannot resolve Mac or Codex nodes.

### M2. Signature components and capture scene

- Goal: ship the Signal Spine, theme, primary action, and adaptive capture hierarchy.
- Files / systems: focused SwiftUI components and `ContentView.swift`.
- Changes: compact-first `ViewThatFits`, elapsed timer, fixed action, removal of repeating pulse.
- Verification: Watch tests plus 40mm and 49mm builds.
- Expected result: capture stays above fold and semantic motion rests.

### M3. Relay ledger, pairing, and retention

- Goal: extend the product language through the core journey.
- Files / systems: queue, ledger row, pairing, and retention views.
- Changes: explicit last-confirmed phase, quieter actions, step-based pairing, exact retention truth.
- Verification: playback, delete, pairing, and retention regressions.
- Expected result: no behavior or security weakening; dense screens remain usable on 40mm.

### M4. Deterministic render and all-size tooling

- Goal: make every required state and installed size repeatable.
- Files / systems: Debug scenario root, simulator selector/CLI, evidence script, tests.
- Changes: seven allowlisted scenarios, stable per-size selection, bounded screenshot capture, content-free manifest.
- Verification: selector, CLI, shell contract, Debug build, and Release build.
- Expected result: current 40/42/44/46/49mm matrix captured without erasing simulators or leaking private data.

### M5. Full proof and documentation

- Goal: retain exact test, render, accessibility, and physical-gate evidence.
- Files / systems: visualization output, evidence summary, physical acceptance, this plan.
- Changes: inspect renders, run regressions and preflight, record exact labels.
- Verification: detailed plan Task 8.
- Expected result: repository and simulator scope are explicit; physical scope is proven only if it runs.

## Verification

- `swift test`
- `xcodebuild test -project CodexWatch.xcodeproj -scheme CodexWatch -destination 'platform=watchOS Simulator,name=Apple Watch SE 3 (40mm)' -only-testing:CodexWatchTests`
- `xcodebuild -quiet build-for-testing -project CodexWatch.xcodeproj -scheme CodexWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO`
- `xcodebuild -quiet build -project CodexWatch.xcodeproj -scheme CodexWatch -configuration Release -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO`
- `bash Tests/CIContractTests/watch_ui_evidence_contract_test.sh`
- `rg -n 'repeatForever|\.repeating|symbolEffect\(.+repeating' WatchApp`
- Manual smoke: inspect all seven scenarios on 40, 42, 44, 46, and 49mm installed simulators.
- Physical smoke: run `watch-device-preflight`; proceed only on `READY` with synthetic speech.

## Decision Log

- 2026-08-14: User selected Signal Spine over Relay Dial and Packet Field.
- 2026-08-14: Preserve tap-to-start/tap-to-stop; reject press-and-hold for accessibility and continuity.
- 2026-08-14: Use explicit state nodes and elapsed time; reject fake waveform or derived progress.
- 2026-08-14: Base on evidence-hardening commit `213604fb`.
- 2026-08-14: Use Debug-only deterministic scenarios for nondefault states without mutating real data.
- 2026-08-14: Validate installed exact-runtime sizes 40/42/44/46/49mm rather than treating three representatives as all-size proof.
- 2026-08-14: Regenerate the Xcode project from `project.yml` after new source files and use selector-resolved UDIDs because duplicate simulator names are present.
- 2026-08-14: In linked worktrees, generate through a temporary symlink named `codex-watch`; XcodeGen otherwise embeds the worktree basename as the local package display name.

## Progress Log

- 2026-08-14: Completed source audit and 40/44/49mm baseline renders.
- 2026-08-14: User selected and approved Signal Spine.
- 2026-08-14: Committed approved design spec at `bcfb146`.
- 2026-08-14: Confirmed inherited baseline: 578 tests passed, zero failures.
- 2026-08-14: Completed Task 1 at `4ac3fd8`: five new truth tests and all 66 Watch tests pass on the selector-resolved 40mm simulator.
- 2026-08-14: Completed Task 2 at `b2cd804`: the accessibility RED failed on the missing helper; the focused GREEN, all 67 Watch tests, and `build-for-testing` passed on the selector-resolved 40mm simulator.
- 2026-08-14: Added semantic tone tokens, one combined Signal Spine accessibility element, shape-redundant node states, bounded presentation-keyed motion, and exact compact action labels.
- 2026-08-14: Completed Task 3 at `f424b65`: all 69 Watch tests pass on 40mm, the 49mm build-for-testing passes, and the repeating-motion scan is empty.
- 2026-08-14: Inspected live 40mm and 49mm renders. The initial system-title composition still clipped 40mm; the accepted compact composition removes that chrome, retains quiet settings/pairing/ledger routes, and shows the full primary action.
- 2026-08-14: Retained Task 3 renders under `/Users/s1kor/.codex/visualizations/2026/08/03/019fc66a-469c-7440-a856-456037ea0845/codex-watch-signal-spine-task3-2026-08-14/`.
- 2026-08-14: Current: Task 4 relay ledger.
- 2026-08-14: Next: write count vocabulary and ledger-row RED tests.

## Rollback / Recovery

- If a scene fails truth, size, accessibility, or performance gates, revert that scene commit only.
- If needs-attention provenance is unavailable, show unknown last remote phase rather than changing persistence.
- If Debug routing affects Release, remove app-level routing and retain production components.
- If all-size tooling cannot identify a destination exactly, fail closed and mark that size `unverified`.
- If physical preflight is not `READY`, stop hardware execution and report simulator evidence separately.
- Preserve user work by reverting only intentional commits; do not reset, stash, or discard unrelated changes.
