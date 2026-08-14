# Signal Spine End-to-End Release Audit

## Goal

- User-visible outcome: validate the complete Signal Spine branch against current Apple documentation, repository standards, runtime behavior, integration boundaries, and GitHub review gates; repair verified defects; merge to `main` only if every required gate is green.
- How to see it working: reproducible tests/builds, clean simulator and service restarts, retained logs and Watch renders, an evidence-backed PR review, green required checks, and an exact merged `main` SHA. If hardware or another external boundary remains blocked, stop before merge and report the precise gate.

## Current State

- Relevant paths: `WatchApp/`, `WatchAppTests/`, `Sources/`, `Tests/`, `Scripts/`, `docs/evidence/`, `docs/PHYSICAL-WATCH-ACCEPTANCE.md`.
- Existing behavior: Signal Spine UI source is `0166cb1`; documentation head is `6294170`; 35 simulator renders and prior local tests are retained, but physical preflight last returned `SUPPORTING_PHONE_UNAVAILABLE`.
- Constraints: branch `feat/andrzej_signal_spine_watch_ui` is a linked worktree; preserve the main checkout and unrelated work; fetched topology proves HEAD is 36 commits ahead and 0 behind `origin/main` at merge base `636c630`; no App Store/TestFlight publication is authorized.
- Authority: local fixes, commits, branch push, PR creation/review, and merge/push to `main` are authorized only after all applicable gates pass. Do not bypass branch protection, force-push, or promote simulator evidence to hardware evidence.

## Target State

- Desired behavior: source architecture and state truth match the specification; boundaries fail closed; Debug fixtures cannot enter Release; Watch UI adapts and remains accessible; bridge/service and Codex compatibility paths restart cleanly; logs contain no unexpected errors or private payloads; the PR is reviewable and green.
- Non-goals: redesigning the approved visual direction, changing protocol/product scope without a verified defect, App Store release, notarization, or weakening hardware acceptance.

## Risks and Failure Modes

- The feature branch may omit or conflict with changes now on `main`, or may accidentally include the full unintegrated hardening stack.
- Existing tests may miss state-mapping, concurrency, lifecycle, logging, privacy, or Release-only defects.
- Simulator proof may hide physical Watch, accessibility, signing, haptic, Always On, or phone-connectivity failures.
- Service restart or Codex compatibility probes may mutate user state unless run in isolated temporary roots.
- GitHub checks or review may expose failures that require another local repair cycle; merging before those resolve is prohibited.

## Milestones

### M1. Establish exact scope and authoritative requirements

- Goal: prove repository topology, branch ancestry, remote state, supported targets, specifications, and current Apple guidance.
- Files / systems: Git graph, project configuration, repository instructions, official Apple documentation.
- Changes: record findings and update this plan only.
- Verification: fetch remote refs; inspect `origin/main...HEAD`; confirm Xcode/watchOS targets; cite current primary documentation.
- Expected result: exact comparison point and a requirements checklist with no guessed availability or semantics.

### M2. Line-by-line source and architecture audit

- Goal: review the complete branch diff and affected parent flows for correctness, maintainability, privacy, security, performance, and dead code.
- Files / systems: Watch presentation/views/model, simulator tooling, device readiness, bridge/service/compatibility code, tests, scripts, project files.
- Changes: document severity-ranked findings; implement only verified in-scope fixes with focused tests.
- Verification: compiler diagnostics, strict source/script scans, test-to-requirement mapping, boundary and concurrency analysis.
- Expected result: no open blocker/high-severity code finding.

### M3. Fresh build, test, and runtime verification

- Goal: exceed existing tests with clean builds, scenario matrix, service lifecycle, isolated integration, restart/replay, log, privacy, and performance checks.
- Files / systems: SwiftPM, Xcode Watch scheme, simulators, bridge smoke/service harnesses, evidence scripts.
- Changes: repair reproducible failures and retain evidence.
- Verification: full serial tests, Watch tests, Debug/Release builds with warnings treated as errors where compatible, shell contracts, deterministic render matrix, isolated bridge/Codex smoke, restart checks, crash/log scan, and bounded performance observation.
- Expected result: exact commands exit zero, logs are privacy-reviewed, and limitations are separately labeled.

### M4. Physical and accessibility gate

- Goal: prove real hardware paths when preflight returns `READY`, otherwise preserve the external blocker.
- Files / systems: physical Watch acceptance checklist, Xcode/devicectl, Watch/iPhone, synthetic speech only.
- Changes: update evidence; no secrets, identifiers, recordings, or transcripts retained.
- Verification: preflight, signed install/launch, permissions, haptics, reduced-luminance/Always On, VoiceOver/accessibility settings, restart and relay path only when authorized and ready.
- Expected result: either evidence-backed physical rows or an exact `blocked:external` stop condition.

### M5. PR hardening, review, and integration

- Goal: create a coherent PR to `main`, inspect the remote patch/checks/comments, resolve issues, and merge only on a green decision.
- Files / systems: GitHub remote, PR diff, checks, review threads, `main`.
- Changes: intentional commits and PR metadata; no unrelated files.
- Verification: fresh pre-push suite, clean tree, pushed SHA matches local SHA, PR patch matches intended diff, required checks pass, no unresolved blocking review, merged SHA is on updated `origin/main`, post-merge smoke passes.
- Expected result: merged `main` only if ship decision is `ready`; otherwise PR remains open with explicit blockers.

## Verification

- `/Users/s1kor/.codex/scripts/session-bootstrap.sh check`
- `git diff --check <comparison>..HEAD`
- `swift test --parallel false`
- `xcodebuild test` on selector-resolved exact-runtime Watch simulator
- Debug build-for-testing and Release build with `CODE_SIGNING_ALLOWED=NO`
- Project shell contracts and privacy/claim/release gates discovered from repository scripts
- Deterministic seven-state/five-size render capture and hash validation
- Isolated bridge/service/Codex compatibility smoke and bounded restart/log review
- `watch-device-preflight`; physical continuation only on `READY`
- `gh pr checks --watch` and PR patch/review inspection before merge
- Post-merge full suite and exact `origin/main` ancestry check

## Decision Log

- 2026-08-14: Treat physical Watch evidence as a separate mandatory gate for hardware claims; simulator success alone cannot authorize that claim.
- 2026-08-14: Compare against freshly fetched `origin/main`, not the historical feature base, before deciding PR scope.
- 2026-08-14: User authorized GitHub publication and merge only after correctness, runtime, review, and stability gates pass; force operations remain out of scope.
- 2026-08-14: Signal Spine nodes report only phases proven by `MemoState`: local transcription is Mac-active/Codex-pending, ready-for-Codex is Mac-confirmed/Codex-pending, and phase-ambiguous attention leaves both remote nodes pending.
- 2026-08-14: SwiftFormat reported 127 of 141 files under its defaults, but the repository has no SwiftFormat configuration. Treat that output as non-authoritative advisory evidence and avoid whole-repository style churn.

## Progress Log

- 2026-08-14: Completed session bootstrap, skill routing, and initial clean-worktree/remote inspection.
- 2026-08-14: Established exact topology: source head `6294170`, merge base/current `origin/main` `636c630`, 36 commits ahead, 0 behind; reviewed the 80-file branch delta and repository contracts.
- 2026-08-14: Reviewed current Apple guidance for glanceable Watch composition, Always On/reduced luminance, `ViewThatFits`, `TimelineView`, non-color differentiation, and accessibility sort priority.
- 2026-08-14: Confirmed RED subprocess regression: `ProcessCodexVersionRunner` deadlocked on 128 KiB stderr and required a 12-second external watchdog (`exit 142`). Implemented simultaneous bounded drains and owned-child cancellation; focused tests now finish in 0.172 seconds and cancellation in 0.111 seconds.
- 2026-08-14: Corrected relay truth mapping, pairing discovery restart after forgetting credentials, accessibility reading priority, render fixture truth, and CI execution of the Watch UI evidence contract. Focused Watch tests pass on the selector-resolved 40 mm simulator.
- 2026-08-14: Final render review found the regular 49 mm delivered composition clipping the leading confirmed node. Changed `ViewThatFits` to validate both horizontal and vertical fit before selecting the roomier composition; focused layout-policy test passes. The first `c1d9f5b` render matrix is rejected evidence and will not be cited as final proof.
- 2026-08-14: Final local gates at `c8f0bc3`: 585 package tests, 75 Watch tests, Debug/Release builds, analyzer, 11-scenario production bridge restart smoke, XcodeGen byte comparison, shell/release/CI contracts, and Release fixture exclusion all passed. Warnings were errors.
- 2026-08-14: Accepted 35-cell render matrix at `/Users/s1kor/.codex/visualizations/2026/08/14/signal-spine-c8f0bc3/`; 35/35 hashes matched and the exact capture-window error/fault scan was empty.
- 2026-08-14: Isolated current-Codex smoke passed `initialize` plus `thread/list` on `codex-cli 0.148.0-alpha.9`; retained evidence is private, allow-listed, and labeled `unverified`.
- 2026-08-14: Physical preflight remains `blocked:external / SUPPORTING_PHONE_UNAVAILABLE`. Both physical Watch and iPhone are visible, paired, and Developer Mode enabled, but both CoreDevice tunnels are disconnected; do not merge while this required gate remains closed.
- 2026-08-14: Current: commit evidence documentation, push the branch, and perform remote PR/check/review inspection.
- 2026-08-14: Next: leave the PR unmerged unless physical preflight becomes `READY` and physical acceptance completes.

## Rollback / Recovery

- If a local fix regresses behavior, revert only its intentional commit after retaining the failure evidence; never reset or discard user work.
- If service/runtime verification mutates temporary state, stop the isolated process and remove only its proven temporary workspace.
- If GitHub checks or review fail, leave the PR open and the worktree intact; do not merge.
- If physical preflight is not `READY`, stop hardware work, retain `blocked:external`, and continue only gates that do not depend on hardware.
- If post-merge verification fails, do not force-rewrite `main`; report and prepare a normal corrective/revert PR.
