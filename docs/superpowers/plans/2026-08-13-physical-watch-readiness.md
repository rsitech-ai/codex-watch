# Physical Watch Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, fixture-tested physical Apple Watch preflight and a usable physical acceptance record that reports the current CoreDevice blocker without exposing private device identifiers.

**Architecture:** A small Swift library decodes only the allow-listed `devicectl` fields and returns an exhaustive readiness result. A thin executable owns `xcrun devicectl`, timeout/error mapping, selection arguments, and redacted text/JSON rendering; it never invokes Xcode or changes device/account state. The acceptance document consumes closed result codes and keeps operator-only physical observations separate from automated evidence.

**Tech Stack:** Swift 6.2, Foundation, Swift Testing, `xcrun devicectl` JSON v5, Swift Package Manager, Markdown.

## Global Constraints

- Support macOS 15+, watchOS 10+, Xcode 26+, and Swift 6.2+.
- Add no external dependency.
- Use these readiness labels literally: `source-inspected`, `preview-reviewed`, `simulator-proven`, `physical-watch-proven`, `package-ready`, `unverified`, `blocked:external`.
- Default execution is read-only: no pairing, unpairing, Developer Mode changes, device registration, profile/certificate changes, service restarts, or `xcodebuild`.
- Human and persisted output may contain public device name, model, and OS only; never serial number, ECID, raw UDID, account data, hostnames, paths, audio, transcript, pairing material, or unrelated inventory.
- Missing, malformed, contradictory, incomplete, or timed-out device state fails closed.
- A visible destination is not ready while its tunnel is disconnected or DDI services are unavailable.

---

## File Structure

- `Sources/WatchDeviceReadiness/DeviceInventory.swift`: narrow Codable projection of allow-listed `devicectl` JSON fields.
- `Sources/WatchDeviceReadiness/WatchReadiness.swift`: exhaustive result codes and pure classification policy.
- `Sources/WatchDeviceReadiness/ReadinessReport.swift`: redacted human and JSON evidence projection.
- `Sources/WatchDevicePreflightCLI/WatchDevicePreflightCommand.swift`: argument parsing and injected process boundary.
- `Sources/WatchDevicePreflightCLI/main.swift`: async executable entry point and exit-code mapping only.
- `Tests/WatchDeviceReadinessTests/Fixtures/*.json`: synthetic inventories; no copied hardware identifiers.
- `Tests/WatchDeviceReadinessTests/WatchReadinessTests.swift`: classifier and redaction tests.
- `Tests/WatchDevicePreflightCLITests/WatchDevicePreflightCommandTests.swift`: tool timeout, exit, argument, and no-mutation contract tests.
- `docs/PHYSICAL-WATCH-ACCEPTANCE.md`: operator scenario matrix and privacy rules.
- `docs/evidence/2026-08-13-physical-watch-preflight.md`: current content-free `blocked:external` evidence.

### Task 1: Pure Device Inventory Classifier

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WatchDeviceReadiness/DeviceInventory.swift`
- Create: `Sources/WatchDeviceReadiness/WatchReadiness.swift`
- Create: `Tests/WatchDeviceReadinessTests/WatchReadinessTests.swift`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/no-devices.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/ready-watch.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/two-watches.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/disconnected-watch-ready-phone.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/ddi-unavailable.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/developer-mode-disabled.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/developer-mode-unknown.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/not-paired.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/no-ready-phone.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/locked-watch.json`
- Create: `Tests/WatchDeviceReadinessTests/Fixtures/truncated.json`

**Interfaces:**
- Consumes: `Data` containing `devicectl list devices --json-output` JSON and an optional exact CoreDevice identifier used only in memory for disambiguation.
- Produces: `DeviceInventory.decode(_:) throws -> DeviceInventory`; `WatchReadinessClassifier.classify(_:selectedIdentifier:) -> WatchReadiness`; `WatchReadiness.Code` as the closed policy enum used by the CLI and documents.

- [ ] **Step 1: Register the focused library and test target**

Add `.library(name: "WatchDeviceReadiness", targets: ["WatchDeviceReadiness"])`, `.target(name: "WatchDeviceReadiness")`, and `.testTarget(name: "WatchDeviceReadinessTests", dependencies: ["WatchDeviceReadiness"], resources: [.copy("Fixtures")])` to `Package.swift`.

- [ ] **Step 2: Write failing decoder and classifier tests**

Use this fixture loader and assert every closed branch explicitly:

```swift
import Foundation
import Testing
@testable import WatchDeviceReadiness

private func fixture(_ name: String) throws -> DeviceInventory {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try DeviceInventory.decode(Data(contentsOf: url))
}

@Test(arguments: [
    ("no-devices", WatchReadiness.Code.noMatchingWatch),
    ("two-watches", .ambiguousWatch),
    ("disconnected-watch-ready-phone", .watchTunnelDisconnected),
    ("ddi-unavailable", .ddiServicesUnavailable),
    ("developer-mode-disabled", .developerModeDisabled),
    ("developer-mode-unknown", .developerModeUnknown),
    ("not-paired", .watchNotPaired),
    ("no-ready-phone", .pairedPhoneUnavailable),
    ("locked-watch", .deviceLocked),
    ("ready-watch", .ready),
])
func classifiesFixture(name: String, expected: WatchReadiness.Code) throws {
    #expect(WatchReadinessClassifier.classify(try fixture(name)).code == expected)
}

@Test func rejectsTruncatedInventory() throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(
        forResource: "truncated", withExtension: "json"
    )))
    #expect(throws: DeviceInventory.DecodingFailure.self) {
        try DeviceInventory.decode(data)
    }
}
```

- [ ] **Step 3: Run the focused tests and confirm RED**

Run: `swift test --no-parallel --filter WatchDeviceReadinessTests`

Expected: build failure because `DeviceInventory`, `WatchReadiness`, and `WatchReadinessClassifier` do not exist.

- [ ] **Step 4: Implement the narrow decoded model**

Implement only allow-listed values and discard the source JSON immediately after decoding:

```swift
public struct DeviceInventory: Sendable {
    public struct Device: Sendable, Equatable {
        public let identifier: String
        public let name: String
        public let model: String
        public let osVersion: String
        public let platform: String
        public let reality: String
        public let deviceType: String
        public let pairingState: String?
        public let tunnelState: String?
        public let transportType: String?
        public let developerModeStatus: String?
        public let bootState: String?
        public let ddiServicesAvailable: Bool?
        public let lockState: LockState
    }

    public enum LockState: Sendable, Equatable {
        case locked, unlocked, unobserved, unknown
    }

    public enum DecodingFailure: Error, Equatable { case malformed, unsuccessfulOutcome }
    public let devices: [Device]
    public static func decode(_ data: Data) throws -> DeviceInventory
}
```

Decode `info.outcome`, `result.devices[].identifier`, `deviceProperties.{name,osVersionNumber,developerModeStatus,bootState,ddiServicesAvailable,isLocked}`, `hardwareProperties.{marketingName,platform,reality,deviceType}`, and `connectionProperties.{pairingState,tunnelState,transportType}`. Map a Boolean `isLocked` to `.locked`/`.unlocked`, an absent field to `.unobserved`, and a present non-Boolean field to `.unknown`. Require `info.outcome == "success"`; map decoding and absent top-level fields to `.malformed`, and a non-success outcome to `.unsuccessfulOutcome`.

- [ ] **Step 5: Implement exhaustive fail-closed classification**

Use this public result shape and evaluation order:

```swift
public struct WatchReadiness: Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        case ready = "READY"
        case noMatchingWatch = "NO_MATCHING_WATCH"
        case ambiguousWatch = "AMBIGUOUS_WATCH"
        case selectedWatchMissing = "SELECTED_WATCH_MISSING"
        case watchNotPaired = "WATCH_NOT_PAIRED"
        case developerModeDisabled = "DEVELOPER_MODE_DISABLED"
        case developerModeUnknown = "DEVELOPER_MODE_UNKNOWN"
        case pairedPhoneUnavailable = "PAIRED_PHONE_UNAVAILABLE"
        case watchTunnelDisconnected = "WATCH_TUNNEL_DISCONNECTED"
        case ddiServicesUnavailable = "DDI_SERVICES_UNAVAILABLE"
        case deviceLocked = "DEVICE_LOCKED"
        case lockStateUnknown = "LOCK_STATE_UNKNOWN"
        case contradictoryState = "CONTRADICTORY_STATE"
    }

    public let code: Code
    public let deviceName: String?
    public let model: String?
    public let osVersion: String?
    public let lockStateObserved: Bool
}
```

Filter physical watchOS devices first. Apply `selectedIdentifier` before ambiguity. Require paired state, enabled Developer Mode, one booted physical supporting iPhone with paired state, connected tunnel, and DDI, then require connected Watch tunnel and Watch DDI. Current `devicectl list devices` JSON does not expose the Watch-to-iPhone association, so this phone check is deliberately conservative and must be described as supporting-phone availability rather than a proven relationship. Map `.locked` to `.deviceLocked`, `.unknown` to `.lockStateUnknown`, and permit `.unobserved` with `lockStateObserved == false`. Reject impossible combinations such as `tunnelState == "connected"` with `bootState != "booted"` as `.contradictoryState`.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter WatchDeviceReadinessTests`

Expected: all classifier and malformed-input cases pass.

- [ ] **Step 7: Commit the pure classifier**

```bash
git add Package.swift Sources/WatchDeviceReadiness Tests/WatchDeviceReadinessTests
git commit -m "feat: classify physical Watch readiness"
```

### Task 2: Read-Only Preflight CLI and Redacted Evidence

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WatchDeviceReadiness/ReadinessReport.swift`
- Create: `Sources/WatchDevicePreflightCLI/WatchDevicePreflightCommand.swift`
- Create: `Sources/WatchDevicePreflightCLI/main.swift`
- Create: `Tests/WatchDeviceReadinessTests/ReadinessReportTests.swift`
- Create: `Tests/WatchDevicePreflightCLITests/WatchDevicePreflightCommandTests.swift`

**Interfaces:**
- Consumes: `WatchReadiness`, explicit `--watch-identifier VALUE`, optional `--json`, and injected `DeviceToolRunning`.
- Produces: executable product `watch-device-preflight`; `WatchDevicePreflightCommand.run(arguments:runner:) async -> ExitCode`; stable tool codes `TOOLS_UNAVAILABLE`, `TOOL_TIMEOUT`, `TOOL_FAILED`, `MALFORMED_INVENTORY` in addition to classifier codes.

- [ ] **Step 1: Write failing privacy and process-boundary tests**

```swift
@Test func reportExcludesPrivateInventory() throws {
    let source = Data(#"{"serialNumber":"SERIAL-SENTINEL","ecid":123,"identifier":"UDID-SENTINEL","potentialHostnames":["HOST-SENTINEL"]}"#.utf8)
    let report = ReadinessReport(
        readiness: .init(code: .watchTunnelDisconnected,
                         deviceName: "Fixture Watch", model: "Apple Watch Ultra 2",
                         osVersion: "26.4", lockStateObserved: false),
        evidenceLabel: "blocked:external"
    ).humanDescription
    #expect(!report.contains("SERIAL-SENTINEL"))
    #expect(!report.contains("UDID-SENTINEL"))
    #expect(!report.contains("HOST-SENTINEL"))
    #expect(!report.contains(String(decoding: source, as: UTF8.self)))
    #expect(report.contains("code=WATCH_TUNNEL_DISCONNECTED"))
}

@Test func commandInvokesOnlyListDevices() async {
    let workspace = FixedPreflightWorkspace(root: URL(fileURLWithPath: "/private/tmp/fixture-preflight"))
    let runner = RecordingDeviceToolRunner(result: .success(readyFixtureData))
    let exit = await WatchDevicePreflightCommand.run(
        arguments: [], runner: runner, workspace: workspace
    )
    #expect(exit == .success)
    #expect(await runner.invocations == [[
        "/usr/bin/xcrun", "devicectl", "list", "devices", "--timeout", "10",
        "--json-output", "/private/tmp/fixture-preflight/devices.json"
    ]])
}
```

Also test missing `/usr/bin/xcrun`, timeout, nonzero status, malformed JSON, unknown option, missing option value, and selection disambiguation. Assert that no invocation contains `pair`, `unpair`, `developer`, `manage`, `restart`, `xcodebuild`, `register`, `profile`, or `certificate`.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `swift test --no-parallel --filter 'ReadinessReport|WatchDevicePreflightCommand'`

Expected: build failure because report and command types are absent.

- [ ] **Step 3: Add the executable target and injected runner**

Add the product/targets:

```swift
.executable(name: "watch-device-preflight", targets: ["WatchDevicePreflightCLI"])
.executableTarget(name: "WatchDevicePreflightCLI", dependencies: ["WatchDeviceReadiness"])
.testTarget(name: "WatchDevicePreflightCLITests", dependencies: ["WatchDevicePreflightCLI", "WatchDeviceReadiness"])
```

Define the boundary without shell interpolation:

```swift
public protocol DeviceToolRunning: Sendable {
    func listDevices(outputURL: URL, timeoutSeconds: Int) async -> DeviceToolResult
}

public enum DeviceToolResult: Sendable, Equatable {
    case success(Data)
    case unavailable
    case timedOut
    case failed(status: Int32)
}

public enum ExitCode: Int32, Sendable { case success = 0, notReady = 2, toolFailure = 3, usage = 64 }
```

The command creates an owner-only temporary directory and supplies its exact `devices.json` path to the runner; no operator path is accepted. The production runner must execute `/usr/bin/xcrun` with the exact fixed arguments from the test, read at most 4 MiB from that output file after a successful exit, and terminate only its owned child after ten seconds. Cleanup must validate and remove only the owned temporary directory. `devicectl --json-output -` is not used because the installed tool does not emit that JSON on stdout.

- [ ] **Step 4: Implement closed rendering and command mapping**

Human output is one line:

```text
label=blocked:external; code=WATCH_TUNNEL_DISCONNECTED; device=Fixture Watch; model=Apple Watch Ultra 2; os=26.4; lock-state=unobserved
```

JSON output is a `Codable` object containing exactly `schemaVersion`, `label`, `code`, `device`, `model`, `osVersion`, and `lockState`. Map `.ready` to exit 0 and `physical-watch-proven` only as readiness for build—not runtime proof—so the actual preflight label must remain `unverified`. Map device blockers to exit 2 and `blocked:external`; map tool/decode failures to exit 3 and `blocked:external`.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter 'ReadinessReport|WatchDevicePreflightCommand'`

Expected: all argument, process, status, and redaction cases pass.

- [ ] **Step 6: Run a live read-only preflight against the connected Watch**

Run:

```bash
swift run watch-device-preflight
```

Expected on the current machine: exit 2 with `code=WATCH_TUNNEL_DISCONNECTED`, public model/OS only, and no raw identifier, serial, ECID, hostname, path, or unrelated device.

- [ ] **Step 7: Commit the CLI**

```bash
git add Package.swift Sources/WatchDeviceReadiness/ReadinessReport.swift Sources/WatchDevicePreflightCLI Tests/WatchDeviceReadinessTests/ReadinessReportTests.swift Tests/WatchDevicePreflightCLITests
git commit -m "feat: add read-only Watch device preflight"
```

### Task 3: Physical Acceptance and Current Blocker Record

**Files:**
- Create: `docs/PHYSICAL-WATCH-ACCEPTANCE.md`
- Create: `docs/evidence/2026-08-13-physical-watch-preflight.md`

**Interfaces:**
- Consumes: closed preflight code and operator observations; does not consume or retain full `devicectl` JSON.
- Produces: reusable acceptance matrix with columns `Scenario`, `Expected`, `Actual`, `Evidence`, `Status`, `Readiness label`; current content-free blocker record.

- [ ] **Step 1: Write the acceptance matrix with every specified scenario**

Create sections for preparation/install/relaunch; microphone grant/deny; recording start/warning/stop/durable queue; bridge offline/reconnect/retry; phrase/invalid/expired code/pairing privacy; upload/ack; Speech grant/deny/local-only transcription; ambiguous Codex acceptance/exactly-once reconciliation/final Watch ack; playback/delete cancel/delete confirm/retention; Watch/Mac/login/sleep/network lifecycle; 40/44/49 mm layout; VoiceOver/larger text/contrast/differentiate-without-color/transparency/motion; and content-free crash/failure/leak/success-log review.

Every row starts with `Actual = Not run`, `Status = Unverified`, and `Readiness label = unverified`. Destructive confirmation rows remain `unverified` until the operator uses synthetic audio and explicitly performs them.

- [ ] **Step 2: Add exact pass/block rules and privacy instructions**

State that lost audio, misleading delivery, primary-action clipping, inaccessible control, crash, credential/content leakage, or duplicate Codex acceptance is a blocker. State that screenshots/log references must not contain identifiers, paths, audio, transcript, credentials, or task IDs. Require synthetic non-confidential speech.

- [ ] **Step 3: Record the current structured external block**

The evidence record must contain: date `2026-08-13`; branch source commit at execution time; model `Apple Watch Ultra 2`; OS `watchOS 26.4`; `WATCH_TUNNEL_DISCONNECTED`; `ddiServicesAvailable=false`; paired iPhone public model/OS and its healthy wired developer-services state; the bounded preparation timeout summary; label `blocked:external`; and next action `Retry the read-only preflight after an Apple/Xcode/CoreDevice update or after the Watch tunnel becomes connected; run no signing or physical workflow until READY.`

Do not include the Watch/iPhone identifiers, serial, ECID, hostnames, Apple account, or private paths.

- [ ] **Step 4: Validate documentation completeness and privacy**

Run:

```bash
rg -n 'Not run|unverified|blocked:external|WATCH_TUNNEL_DISCONNECTED' docs/PHYSICAL-WATCH-ACCEPTANCE.md docs/evidence/2026-08-13-physical-watch-preflight.md
rg -n 'serial|ECID|UDID|coredevice\.local|00008[0-9]' docs/PHYSICAL-WATCH-ACCEPTANCE.md docs/evidence/2026-08-13-physical-watch-preflight.md
```

Expected: the first command covers every row and blocker; the second produces no output.

- [ ] **Step 5: Commit the physical evidence documents**

```bash
git add docs/PHYSICAL-WATCH-ACCEPTANCE.md docs/evidence/2026-08-13-physical-watch-preflight.md
git commit -m "docs: add physical Watch acceptance gate"
```

### Task 4: Regression Gate

**Files:**
- Verify only; modify files only to fix failures introduced by Tasks 1–3.

**Interfaces:**
- Consumes: all preflight and acceptance outputs.
- Produces: fresh non-mutating validation evidence; physical workflow remains blocked unless code is `READY`.

- [ ] **Step 1: Run the full serialized package suite**

Run: `swift test --no-parallel`

Expected: all tests pass with no test touching a physical device or normal Codex home.

- [ ] **Step 2: Run existing release and production-composed gates**

Run:

```bash
Tests/ReleasePackagingTests/package_bridge_release_contract_test.sh
Scripts/run-watch-bridge-smoke.sh
```

Expected: both exit 0.

- [ ] **Step 3: Re-run live preflight and enforce the stop condition**

Run: `swift run watch-device-preflight`

Expected today: `WATCH_TUNNEL_DISCONNECTED`, exit 2, and `blocked:external`. If it returns `READY`, stop before `xcodebuild`; physical provisioning/build/install is a separately reviewed operator action.

- [ ] **Step 4: Review the exact diff and commit any test-only corrections**

Run: `git diff --check && git status --short && git diff --stat`

Expected: no whitespace errors or unrelated changes. If corrective edits were required, stage only their exact paths and commit with `fix: harden Watch readiness evidence`.
