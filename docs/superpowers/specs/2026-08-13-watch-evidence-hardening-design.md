# Codex Watch Evidence Hardening Design

## Status

- Design approved in conversation on 2026-08-13.
- Physical readiness, deterministic simulator selection, and isolated Codex
  compatibility tooling are implemented on the hardening branch. Full
  end-to-end regression and branch review remain in progress.
- Physical Watch execution is currently `blocked:external` by Apple CoreDevice
  preparation, not by a proven Codex Watch defect.

## Outcome

Make physical-device, simulator, package, and Codex compatibility evidence
repeatable and impossible to overstate. An operator should be able to determine
why a Watch cannot be built or installed, run deterministic non-mutating gates,
and complete a documented physical acceptance pass when Apple device services
are available.

The primary user is the project maintainer validating Codex Watch before a
public or Apple distribution decision. The primary wrist job remains unchanged:
record an idea quickly, keep it durable on the Watch, and show truthful delivery
and recovery state.

## Current Evidence

### Proven

- Public source `main` is `636c630047893daa2c7ce691f7fffdf1267cfce9`.
- The exact-main hosted CI run passed the Swift package, Watch simulator,
  production-composed bridge smoke, and packaging gates.
- Fresh local evidence on 2026-08-03 passed 535 Swift package tests, 61 Watch
  tests on a named watchOS 26.5 simulator, 11 production-composed bridge smoke
  scenarios, and the release packaging contract.
- A fresh `v0.1.0` download passed checksums, strict Developer ID signature
  verification, Gatekeeper notarization assessment, and staple validation.
- The physical Apple Watch is paired and reports Developer Mode enabled.
- The paired iPhone establishes a healthy wired CoreDevice tunnel and exposes
  developer services.

### Blocked or unverified

- On 2026-08-03 and again on 2026-08-13, the physical Watch reported
  `tunnelState=disconnected` and `ddiServicesAvailable=false` while paired,
  booted, unlocked, near the Mac, and backed by a wired, developer-ready iPhone.
- `xcodebuild` timed out before provisioning with the recovery text
  `Apple Watch may need to be unlocked to recover from previously reported
  preparation errors`.
- The Watch app has therefore not been built, installed, launched, or operated
  on this physical device from the current checkout.
- Physical microphone capture, direct local-network upload, macOS Speech
  authorization and transcription, login restart, and durable Watch delivery
  acknowledgement remain unverified as one real workflow.
- The installed Codex CLI and App Server are version-sensitive. A current
  isolated read-only compatibility gate has not yet been retained as a durable
  release artifact.
- A visible disposable Codex Inbox insertion is a separate mutation gate and is
  outside this design's automatic authorization.

## Evidence Labels

All scripts, reports, and documentation must use these labels literally:

- `source-inspected`: code or configuration was inspected.
- `preview-reviewed`: rendered previews were reviewed.
- `simulator-proven`: the named path ran on a named simulator and runtime.
- `physical-watch-proven`: the named path ran on an identified physical Watch.
- `package-ready`: the exact downloadable artifact passed its package gate.
- `unverified`: required proof was not performed.
- `blocked:external`: an external device, account, or service condition prevents
  proof, with the exact next action recorded.

No label implies a stronger label. In particular, a simulator build, package
test, or visible Xcode destination must never be reported as physical Watch
proof.

## Scope

### 1. Physical Watch readiness preflight

Add a read-only script that gathers structured device state before invoking a
physical build. It must distinguish at least:

1. required tools unavailable;
2. no matching physical Watch;
3. ambiguous Watch selection;
4. Watch not paired;
5. Developer Mode disabled or unknown;
6. paired iPhone missing or unavailable when required;
7. Watch tunnel disconnected;
8. developer disk-image services unavailable;
9. device locked or device lock state unknown when observable;
10. ready for Xcode build and install.

The preflight consumes `devicectl` JSON through a pure classifier. Tests use
synthetic fixtures only. Human-readable output contains device name, model,
OS, and closed state/error codes but excludes serial numbers, ECIDs, Apple
account data, and unrelated device inventory.

The default command is read-only. It must not pair or unpair devices, toggle
Developer Mode, register devices, modify profiles, create certificates, revoke
certificates, restart services, or invoke `xcodebuild`.

An explicit build command may consume a successful preflight result, but
provisioning updates and device registration remain separate operator flags.
Certificate revocation or replacement is never automated.

### 2. Isolated Codex compatibility smoke

Add an opt-in smoke that records the exact Codex CLI version and exercises the
smallest non-mutating App Server contract in an isolated temporary environment:

1. resolve and validate an explicitly supplied Codex executable;
2. create a private temporary Codex home and neutral working directory;
3. start only the owned App Server child;
4. initialize the protocol;
5. execute `thread/list` against the isolated environment;
6. close and await the owned child within the existing bounded shutdown policy;
7. emit a redacted immutable evidence summary.

The smoke must not connect to a Desktop-owned App Server, inspect an existing
user task, inject items, create a model turn, copy credentials, or reuse the
normal Codex home. Failure is explicit; there is no fallback to the user's live
environment.

One visible disposable Inbox insertion remains a separate manual scenario. It
requires explicit task-specific authority immediately before mutation and must
use synthetic content with a recorded cleanup decision.

### 3. Deterministic Watch simulator selection

Replace first-device selection in hosted CI with an explicit selector that:

- reads the active watchOS simulator SDK version;
- chooses an available physical-size class deliberately, preferring the
  smallest supported display for the hard layout gate;
- requires an exact matching runtime unless the workflow explicitly declares a
  fallback policy;
- fails with a closed diagnostic when no valid destination exists;
- prints the selected simulator name, identifier, runtime, and rationale.

Selection logic must be fixture-tested without depending on a runner's live
simulator inventory. The CI job then runs the existing Watch test suite against
the resolved identifier.

### 4. Physical acceptance and release evidence documents

Add a physical-device acceptance document with a scenario matrix covering:

- preflight and device preparation;
- first install and relaunch;
- microphone permission granted and denied;
- recording start, duration warning, stop, and durable queue visibility;
- bridge absent/offline, recovery after reconnection, and retry timing;
- certificate phrase comparison and invalid/expired pairing code;
- successful pairing without leaking the raw fingerprint or credential;
- local-network upload and bridge acknowledgement;
- macOS Speech permission granted and denied;
- local transcription with no cloud-audio fallback;
- ambiguous Codex acceptance and exactly-once reconciliation;
- final acknowledgement reflected on Watch;
- playback, deletion cancel, deletion confirm with synthetic audio, and
  retention changes;
- Watch and Mac restart, login restart, sleep/wake, and network change;
- smallest supported Watch layout, representative and largest simulator sizes,
  accessibility text, VoiceOver, Increase Contrast, Differentiate Without
  Color, Reduce Transparency, and Reduce Motion;
- log review for crashes, repeated failures, content leakage, and misleading
  success.

Each row records expected result, actual result, evidence method, status, and an
exact readiness label. Unperformed destructive confirmations remain marked
blocked or unverified rather than silently omitted.

Add a release verification document that records the source commit, artifact
tag and digest, signing identity class, notarization and staple results,
supported Codex version evidence, named simulator runtime, physical device
scope, and remaining external gates.

### 5. Documentation truth updates

Update the README only after the new gates exist and have current evidence.
State that `v0.1.0` is `package-ready` because the exact public download has
passed signature, Gatekeeper, notarization, staple, and checksum verification.
Keep physical Watch runtime and App Store distribution explicitly separate.

Do not claim that Codex integration is supported across versions. State the
most recently proven CLI/App Server version and date, and describe later
versions as unverified until the isolated smoke passes.

## Architecture

Keep policy pure and I/O narrow:

- shell wrappers collect tool output and enforce operator flags;
- small fixture-driven classifiers decide readiness and simulator selection;
- existing Swift App Server transport/client code owns protocol behavior;
- reports consume closed result codes and redacted evidence;
- CI invokes the same deterministic selectors used locally.

No new external dependency is required. Prefer shell plus existing Apple tools
and Swift test targets. If JSON classification becomes unsafe or unreadable in
shell, use a small Swift executable target with pure decoding and exhaustive
enums rather than an ad hoc text parser.

## Failure Semantics

- Missing, malformed, contradictory, or incomplete device state fails closed.
- A visible destination is not readiness when the Watch tunnel or DDI service
  is unavailable.
- Tool timeouts are distinct from device rejection and from signing failure.
- Provisioning failure is reported only after a ready destination reaches the
  provisioning boundary.
- The preflight never converts a CoreDevice failure into an app defect.
- Compatibility smoke failure never falls back to a live Codex instance.
- Evidence generation failure never changes product state.
- Logs and reports use closed codes; they do not include transcript content,
  audio, credentials, local task identifiers, or private filesystem paths.

## Test Strategy

All behavior changes follow red-green-refactor.

### Preflight fixtures

- no devices;
- one ready Watch;
- two matching Watches without explicit selection;
- paired Watch with disconnected tunnel;
- paired Watch with DDI unavailable;
- Developer Mode disabled and unknown;
- wired ready iPhone plus disconnected Watch, matching the 2026-08-13 failure;
- malformed and truncated `devicectl` JSON;
- timeout and nonzero tool exit;
- redaction of serial, ECID, and unrelated devices.

### Simulator selector fixtures

- exact active runtime with smallest display available;
- multiple matching destinations with stable selection;
- runtime mismatch;
- only unavailable devices;
- malformed inventory;
- no valid Watch destination.

### Codex compatibility tests

- executable path validation;
- isolated environment creation and permissions;
- exact owned-child launch arguments;
- initialization ordering;
- `thread/list` success and typed protocol failure;
- bounded shutdown on success, error, timeout, and cancellation;
- proof that the normal Codex home and existing task state are never read.

### Regression and realistic smokes

- focused tests for each classifier and wrapper;
- full serialized Swift package suite;
- release packaging contract;
- production-composed fake-Inbox smoke;
- named watchOS simulator test run;
- physical preflight against the connected Watch;
- physical workflow only when the preflight reports ready;
- current isolated Codex compatibility smoke.

## Physical Acceptance Evidence

Physical proof must identify the model and OS but must not retain serial number,
ECID, raw UDID, pairing secret, audio, or transcript. Store only:

- date and source commit;
- public model and OS version;
- scenario identifier;
- pass/fail/blocked status;
- content-free log or screenshot reference;
- operator observation for actions that cannot be automated safely.

Test recordings must contain synthetic, non-confidential speech. A visible
Codex scenario, if later authorized, must use disposable synthetic text and a
dedicated disposable task.

## Watch Experience Proof Matrix

This slice does not redesign the Watch UI. It validates the existing primary
interaction and records findings before any material visual change.

- Smallest simulator: hard layout and accessibility gate.
- Representative simulator: normal interaction and state transitions.
- Largest simulator: use added space without changing semantics.
- Physical Watch: microphone, haptics, playback, network, permissions, energy,
  foreground/background, and wrist readability.
- State scenes: setup/waiting, ready, recording, saved, sending, received,
  adding to Codex, delivered, needs attention, permission denied, and offline.
- Accessibility: VoiceOver order and copy, larger text, non-color status cues,
  Reduce Motion, and destructive confirmation.

Any observed clipping, inaccessible primary action, misleading completion, or
lost audio is a blocker. Material visual redesign requires a separate approved
direction process; it is not smuggled into evidence tooling.

## CI and Release Gates

Hosted CI remains read-only and uses synthetic fixtures. It must not attempt
Apple account provisioning, physical-device registration, certificate changes,
notarization, real Speech permission, or Codex task mutation.

Before a new downloadable bridge release:

1. exact-main CI passes;
2. deterministic Watch simulator selection and tests pass;
3. package contract passes;
4. exact artifact is Developer ID signed, notarized, stapled, checksummed, and
   freshly downloaded for verification;
5. current isolated Codex compatibility evidence is retained;
6. physical Watch gaps are named, not hidden.

Before TestFlight or App Store distribution, separately require Watch signing
assets, archive validation, App Store Connect metadata, review assets, privacy
answers, and physical-device acceptance. Developer ID proof does not satisfy
Watch distribution signing.

## Authority Boundaries

The following are not authorized automatically by this design:

- unpairing, resetting, or erasing a device;
- certificate revocation or replacement;
- Apple account, profile, or App Store Connect mutations beyond an explicitly
  authorized provisioning command;
- persistent bridge installation or data purge;
- Speech permission prompts without the operator present;
- real Codex task creation, turn start, item injection, or deletion;
- public release, TestFlight upload, App Store submission, push, or pull request.

## Completion Criteria

This hardening slice is complete when:

- the preflight and simulator selector pass fixture-driven tests and fail closed
  on the captured CoreDevice condition;
- the isolated Codex smoke proves its non-mutation boundary and records a
  current exact version result;
- CI uses deterministic Watch selection;
- physical acceptance and release evidence documents are complete and usable;
- README readiness language matches current evidence;
- full local and hosted non-mutating gates pass;
- the connected Watch is either `physical-watch-proven` for the named scenarios
  or `blocked:external` with current structured evidence and an exact next
  action.

The slice does not require bypassing an Apple CoreDevice defect or claiming
physical proof when Xcode cannot prepare the Watch.

## Rejected Alternatives

- **Docs-only update:** rejected because it leaves operators dependent on
  ambiguous Xcode text and does not prevent repeated blind retries.
- **Immediate App Store signing work:** rejected because signing cannot repair a
  disconnected Watch tunnel and would conflate independent release gates.
- **Automatic device or certificate repair:** rejected because pairing resets,
  revocation, and account mutations exceed a safe diagnostic tool's authority.
- **Live Codex smoke by default:** rejected because compatibility evidence must
  not mutate or inspect the user's normal Codex state.
- **Broad Watch redesign during hardening:** rejected because no physical UI
  defect has yet been observed and evidence tooling should not expand product
  scope.
