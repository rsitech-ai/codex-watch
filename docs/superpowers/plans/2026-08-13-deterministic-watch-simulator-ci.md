# Deterministic Watch Simulator CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace CI's first-matching Watch simulator with a fixture-tested selector that chooses the smallest available Watch on the exact active watchOS runtime and fails closed on ambiguity or drift.

**Architecture:** A pure Swift selector receives the active SDK version plus decoded `simctl` inventory and returns a stable destination or a closed error. A narrow executable collects the SDK/runtime/device JSON from fixed `xcrun` commands and prints machine-readable fields. CI captures the selected identifier from a GitHub output file while preserving public selection diagnostics in the log.

**Tech Stack:** Swift 6.2, Foundation, Swift Testing, `xcrun simctl` JSON, `xcrun --sdk watchsimulator --show-sdk-version`, GitHub Actions, Xcode 26.5.

## Global Constraints

- Support macOS 15+, watchOS 10+, Xcode 26+, and Swift 6.2+.
- Add no external dependency.
- Hosted CI is read-only and must not provision accounts, register devices, modify certificates/profiles, request permissions, or touch a physical device.
- Select the smallest supported Watch display as the hard layout gate.
- Require an exact runtime matching the active watchOS simulator SDK; no implicit fallback.
- Missing, malformed, unavailable, or contradictory inventory fails closed with a closed code.
- Print selected simulator name, identifier, runtime, and rationale; this is `simulator-proven` only after tests run successfully.

---

## File Structure

- `Sources/WatchSimulatorSelection/SimulatorInventory.swift`: narrow decoders for runtime and device JSON.
- `Sources/WatchSimulatorSelection/WatchSimulatorSelector.swift`: pure exact-runtime and smallest-display policy.
- `Sources/WatchSimulatorSelectorCLI/WatchSimulatorSelectorCommand.swift`: fixed tool calls and output rendering.
- `Sources/WatchSimulatorSelectorCLI/main.swift`: executable entry and exit codes.
- `Tests/WatchSimulatorSelectionTests/Fixtures/*.json`: synthetic simctl inventories.
- `Tests/WatchSimulatorSelectionTests/WatchSimulatorSelectorTests.swift`: stable-selection and fail-closed tests.
- `Tests/WatchSimulatorSelectorCLITests/WatchSimulatorSelectorCommandTests.swift`: process arguments and output contract.
- `.github/workflows/ci.yml`: use selected identifier for Watch tests.

### Task 1: Exact-Runtime Smallest-Watch Selector

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WatchSimulatorSelection/SimulatorInventory.swift`
- Create: `Sources/WatchSimulatorSelection/WatchSimulatorSelector.swift`
- Create: `Tests/WatchSimulatorSelectionTests/WatchSimulatorSelectorTests.swift`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/exact-runtime.json`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/stable-tie.json`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/runtime-mismatch.json`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/unavailable-only.json`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/malformed.json`
- Create: `Tests/WatchSimulatorSelectionTests/Fixtures/no-watch.json`

**Interfaces:**
- Consumes: active SDK string such as `26.5`, simctl runtime JSON, and simctl available-device JSON.
- Produces: `WatchSimulatorSelector.select(activeSDK:runtimes:devices:) throws -> WatchSimulatorDestination` with exact `name`, `identifier`, `runtimeIdentifier`, `runtimeVersion`, `displayMillimeters`, and `rationale`.

- [ ] **Step 1: Register the library and resource-backed test target**

Add `.library(name: "WatchSimulatorSelection", targets: ["WatchSimulatorSelection"])`, `.target(name: "WatchSimulatorSelection")`, and `.testTarget(name: "WatchSimulatorSelectionTests", dependencies: ["WatchSimulatorSelection"], resources: [.copy("Fixtures")])`.

- [ ] **Step 2: Write the failing selector tests**

```swift
import Foundation
import Testing
@testable import WatchSimulatorSelection

@Test func choosesSmallestDisplayOnExactActiveRuntime() throws {
    let inventory = try fixture("exact-runtime")
    let selected = try WatchSimulatorSelector.select(
        activeSDK: "26.5", runtimes: inventory.runtimes, devices: inventory.devices
    )
    #expect(selected.name == "Apple Watch SE 3 (40mm)")
    #expect(selected.runtimeVersion == "26.5")
    #expect(selected.displayMillimeters == 40)
    #expect(selected.rationale == "smallest-available-display-on-exact-active-runtime")
}

@Test func stableTieUsesNameThenIdentifier() throws {
    let inventory = try fixture("stable-tie")
    let selected = try WatchSimulatorSelector.select(
        activeSDK: "26.5", runtimes: inventory.runtimes, devices: inventory.devices
    )
    #expect(selected.identifier == "00000000-0000-0000-0000-000000000001")
}

@Test(arguments: [
    ("runtime-mismatch", WatchSimulatorSelectionError.exactRuntimeUnavailable),
    ("unavailable-only", .noAvailableWatch),
    ("no-watch", .noAvailableWatch),
    ("malformed", .malformedInventory),
])
func failsClosed(name: String, expected: WatchSimulatorSelectionError) throws {
    #expect(throws: expected) { try selectFixture(name, sdk: "26.5") }
}
```

- [ ] **Step 3: Run focused tests and confirm RED**

Run: `swift test --no-parallel --filter WatchSimulatorSelectionTests`

Expected: build failure because selector types do not exist.

- [ ] **Step 4: Implement narrow inventory types and closed errors**

```swift
public struct SimulatorRuntime: Sendable, Equatable {
    public let identifier: String
    public let version: String
    public let platform: String
    public let isAvailable: Bool
}

public struct SimulatorDevice: Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let runtimeIdentifier: String
    public let isAvailable: Bool
}

public struct WatchSimulatorDestination: Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let runtimeIdentifier: String
    public let runtimeVersion: String
    public let displayMillimeters: Int
    public let rationale: String
}

public enum WatchSimulatorSelectionError: String, Error, Equatable, Sendable {
    case invalidSDKVersion = "INVALID_SDK_VERSION"
    case malformedInventory = "MALFORMED_INVENTORY"
    case exactRuntimeUnavailable = "EXACT_RUNTIME_UNAVAILABLE"
    case noAvailableWatch = "NO_AVAILABLE_WATCH"
    case unknownDisplaySize = "UNKNOWN_DISPLAY_SIZE"
    case contradictoryInventory = "CONTRADICTORY_INVENTORY"
}
```

Decode `simctl list runtimes --json` and `simctl list devices available --json`. Accept only runtime identifiers beginning `com.apple.CoreSimulator.SimRuntime.watchOS-`. Parse display size with the anchored suffix regex `\(([0-9]{2})mm\)$`; reject a candidate whose size cannot be established. Match normalized SDK `major.minor` exactly to runtime `version`. Sort candidates by `(displayMillimeters, name, identifier)`.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter WatchSimulatorSelectionTests`

Expected: all exact-runtime, availability, parsing, and stable-order cases pass.

- [ ] **Step 6: Commit the pure selector**

```bash
git add Package.swift Sources/WatchSimulatorSelection Tests/WatchSimulatorSelectionTests
git commit -m "feat: select deterministic Watch simulator"
```

### Task 2: Selector CLI Contract

**Files:**
- Modify: `Package.swift`
- Create: `Sources/WatchSimulatorSelectorCLI/WatchSimulatorSelectorCommand.swift`
- Create: `Sources/WatchSimulatorSelectorCLI/main.swift`
- Create: `Tests/WatchSimulatorSelectorCLITests/WatchSimulatorSelectorCommandTests.swift`

**Interfaces:**
- Consumes: injected `SimulatorToolRunning`; production uses three fixed `xcrun` calls and no user-provided shell fragments.
- Produces: executable `watch-simulator-selector`; `--format shell` output keys `name`, `identifier`, `runtime`, `runtime_identifier`, `display_mm`, `rationale`; exit 0 on selection, 2 on no destination, 3 on tool/decode error, 64 on usage.

- [ ] **Step 1: Write failing fixed-command and output tests**

```swift
@Test func invokesOnlyFixedReadOnlyCommands() async {
    let runner = RecordingSimulatorToolRunner.successFixture
    let result = await WatchSimulatorSelectorCommand.run(arguments: ["--format", "shell"], runner: runner)
    #expect(result.exitCode == 0)
    #expect(await runner.invocations == [
        ["/usr/bin/xcrun", "--sdk", "watchsimulator", "--show-sdk-version"],
        ["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"],
        ["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"],
    ])
    #expect(result.stdout.contains("identifier=00000000-0000-0000-0000-000000000001"))
    #expect(result.stdout.contains("rationale=smallest-available-display-on-exact-active-runtime"))
}
```

Add cases for any tool nonzero/timeout, empty SDK output, JSON above 4 MiB, malformed JSON, invalid format, runtime mismatch, and safe shell quoting. Assert no invocation contains `boot`, `shutdown`, `erase`, `delete`, `pair`, `xcodebuild`, or provisioning flags.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --no-parallel --filter WatchSimulatorSelectorCLITests`

Expected: build failure because the command does not exist.

- [ ] **Step 3: Add executable/test targets and implement the runner**

Add:

```swift
.executable(name: "watch-simulator-selector", targets: ["WatchSimulatorSelectorCLI"])
.executableTarget(name: "WatchSimulatorSelectorCLI", dependencies: ["WatchSimulatorSelection"])
.testTarget(name: "WatchSimulatorSelectorCLITests", dependencies: ["WatchSimulatorSelectorCLI", "WatchSimulatorSelection"])
```

Define `SimulatorToolRunning.run(_ arguments: [String], timeout: Duration) async -> SimulatorToolResult`. The production implementation must execute only `/usr/bin/xcrun`, bound each call to ten seconds, cap stdout at 4 MiB, and terminate only its owned child.

- [ ] **Step 4: Implement stable shell output**

Emit one `key=value` pair per line. Encode `name` using single-quote shell escaping; emit identifier/runtime/display/rationale only from validated alphanumeric, period, hyphen, underscore, parenthesis, and space fields. Print a public diagnostic to stderr:

```text
selected Watch simulator: Apple Watch SE 3 (40mm); watchOS 26.5; 40mm; smallest-available-display-on-exact-active-runtime
```

- [ ] **Step 5: Run focused tests and a live selector smoke**

Run:

```bash
swift test --no-parallel --filter WatchSimulatorSelectorCLITests
swift run watch-simulator-selector --format shell
```

Expected: tests pass; live output selects an available 40 mm Watch on the exact active SDK runtime or fails with one closed diagnostic.

- [ ] **Step 6: Commit the CLI**

```bash
git add Package.swift Sources/WatchSimulatorSelectorCLI Tests/WatchSimulatorSelectorCLITests
git commit -m "feat: expose deterministic simulator selector"
```

### Task 3: Hosted CI Integration

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `Tests/CIContractTests/watch_destination_contract_test.sh`

**Interfaces:**
- Consumes: `watch-simulator-selector --format shell` output.
- Produces: GitHub step output `destination_id` and existing `xcodebuild test` invocation bound to that exact identifier.

- [ ] **Step 1: Write a failing workflow contract test**

The test must load `.github/workflows/ci.yml` and require all of these strings:

```zsh
[[ "$workflow" == *'swift run watch-simulator-selector --format shell'* ]]
[[ "$workflow" == *'destination_id='* ]]
[[ "$workflow" == *'platform=watchOS Simulator,id=${{ steps.watch-destination.outputs.destination_id }}'* ]]
[[ "$workflow" != *'sed -nE'* ]]
[[ "$workflow" != *'simctl list devices available |'* ]]
```

- [ ] **Step 2: Run the contract test and confirm RED**

Run: `Tests/CIContractTests/watch_destination_contract_test.sh`

Expected: failure because CI still uses first-match `sed` selection.

- [ ] **Step 3: Replace first-match selection with the selector**

Add a step with `id: watch-destination` that runs the selector, parses only the validated `identifier=` line, requires exactly one value, writes `destination_id` to `$GITHUB_OUTPUT`, and leaves the selector diagnostic visible. Change the Xcode destination to:

```yaml
- name: Run Watch app tests
  run: |
    xcodebuild \
      -project CodexWatch.xcodeproj \
      -scheme CodexWatch \
      -configuration Debug \
      -destination "platform=watchOS Simulator,id=${{ steps.watch-destination.outputs.destination_id }}" \
      CODE_SIGNING_ALLOWED=NO \
      test
```

Add the contract test to the `swift-package` job before `swift test` so workflow drift is tested on both supported runners.

- [ ] **Step 4: Run contract and focused tests and confirm GREEN**

Run:

```bash
Tests/CIContractTests/watch_destination_contract_test.sh
swift test --no-parallel --filter 'WatchSimulatorSelectionTests|WatchSimulatorSelectorCLITests'
```

Expected: all pass; no first-match pipeline remains.

- [ ] **Step 5: Run the named simulator test locally**

Run:

```bash
selection="$(swift run watch-simulator-selector --format shell)"
destination_id="$(printf '%s\n' "$selection" | sed -n 's/^identifier=//p')"
test -n "$destination_id"
xcodebuild -project CodexWatch.xcodeproj -scheme CodexWatch -configuration Debug -destination "platform=watchOS Simulator,id=$destination_id" CODE_SIGNING_ALLOWED=NO test
```

Expected: Watch tests pass on the selector-reported exact runtime and smallest display. Record the public simulator name/runtime in the verification notes; do not call this physical proof.

- [ ] **Step 6: Commit CI integration**

```bash
git add .github/workflows/ci.yml Tests/CIContractTests/watch_destination_contract_test.sh
git commit -m "ci: pin Watch tests to deterministic destination"
```

### Task 4: Full Non-Mutating Regression

**Files:**
- Verify only; modify only failures introduced by this plan.

**Interfaces:**
- Consumes: new selector and CI workflow.
- Produces: fresh `simulator-proven` local evidence for the named runtime only.

- [ ] **Step 1: Run the full package suite**

Run: `swift test --no-parallel`

Expected: all tests pass.

- [ ] **Step 2: Run existing production and packaging gates**

Run: `Tests/ReleasePackagingTests/package_bridge_release_contract_test.sh && Scripts/run-watch-bridge-smoke.sh`

Expected: both pass.

- [ ] **Step 3: Review CI safety and diff**

Run:

```bash
rg -n 'allowProvisioning|register|certificate|profile|devicectl|platform=watchOS,' .github/workflows/ci.yml
git diff --check
git status --short
```

Expected: no provisioning/account/device mutation appears; only the simulator destination appears; no whitespace or unrelated changes.

