# Isolated Codex Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in compatibility smoke that launches an explicitly supplied Codex CLI in a private empty home, performs only initialize plus `thread/list`, closes its owned child, and writes redacted immutable evidence for release truth.

**Architecture:** The existing `StdioProcessTransport` and `AppServerClient` remain the protocol and bounded-shutdown owners. A new probe service validates the executable, creates owner-only isolation directories, launches `codex app-server` with a replaced `CODEX_HOME`, performs `initialize` then `thread/list`, validates only the response shape, and closes in `defer`. A small CLI writes an exclusive-create evidence file and never falls back to Desktop or the user's normal Codex environment.

**Tech Stack:** Swift 6.2, Foundation, Swift Testing, existing `CodexAppServerClient` and `CodexAppServerProtocol`, Codex CLI App Server over stdio, Markdown.

## Global Constraints

- Support macOS 15+, watchOS 10+, Xcode 26+, and Swift 6.2+.
- Add no external dependency.
- Require an explicit absolute Codex executable path; never search PATH as fallback.
- Use a private temporary `CODEX_HOME` and neutral cwd with mode `0700`; never copy credentials or read normal Codex state.
- Exercise only protocol `initialize`, `initialized`, and `thread/list`; never `thread/read`, `thread/start`, `turn/start`, `thread/inject_items`, or Desktop-owned endpoints.
- Close and await only the owned App Server child using the existing bounded shutdown policy.
- Evidence excludes credentials, task/thread IDs, task content, environment, private paths, stdout/stderr payloads, and normal home data.
- Use literal readiness labels and never generalize one exact Codex version result to other versions.
- A visible disposable Inbox insertion is outside this automated plan and requires fresh mutation authority.

---

## File Structure

- `Sources/CodexAppServerClient/IsolatedCodexWorkspace.swift`: executable validation and private temporary directory lifecycle.
- `Sources/CodexAppServerClient/CodexCompatibilityProbe.swift`: initialize/list/close orchestration with injectable session and version runners.
- `Sources/CodexAppServerClient/CodexCompatibilityEvidence.swift`: redacted schema and exclusive-create writer.
- `Sources/CodexCompatibilitySmokeCLI/CodexCompatibilitySmokeCommand.swift`: CLI arguments and status rendering.
- `Sources/CodexCompatibilitySmokeCLI/main.swift`: async entry and exit mapping.
- `Tests/CodexAppServerClientTests/IsolatedCodexWorkspaceTests.swift`: permissions/path/no-normal-home tests.
- `Tests/CodexAppServerClientTests/CodexCompatibilityProbeTests.swift`: protocol order, response, timeout, cancellation, and close tests.
- `Tests/CodexAppServerClientTests/CodexCompatibilityEvidenceTests.swift`: redaction and immutable write tests.
- `Tests/CodexCompatibilitySmokeCLITests/CodexCompatibilitySmokeCommandTests.swift`: argument and no-fallback contract.
- `docs/RELEASE-VERIFICATION.md`: exact source/artifact/signing/notary/simulator/Codex/physical gates.
- `docs/evidence/`: one uniquely named redacted JSON result retained for each executed smoke.
- `README.md`: evidence-bounded package and compatibility wording after the smoke exists.

### Task 1: Private Workspace and Executable Boundary

**Files:**
- Create: `Sources/CodexAppServerClient/IsolatedCodexWorkspace.swift`
- Create: `Tests/CodexAppServerClientTests/IsolatedCodexWorkspaceTests.swift`

**Interfaces:**
- Consumes: explicit absolute executable `URL`, injected base temporary directory for tests.
- Produces: `ValidatedCodexExecutable`; `IsolatedCodexWorkspace.create(baseDirectory:) throws`; public read-only `codexHome` and `neutralDirectory`; idempotent owned cleanup.

- [ ] **Step 1: Write failing path, permission, and separation tests**

```swift
@Test func createsPrivateEmptyDirectoriesOutsideNormalCodexHome() throws {
    let fixture = try WorkspaceFixture()
    let workspace = try IsolatedCodexWorkspace.create(baseDirectory: fixture.root)
    defer { workspace.close() }

    #expect(workspace.codexHome != fixture.normalCodexHome)
    #expect(workspace.neutralDirectory != fixture.normalCodexHome)
    #expect(try posixMode(workspace.codexHome) == 0o700)
    #expect(try posixMode(workspace.neutralDirectory) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.codexHome.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.neutralDirectory.path).isEmpty)
}

@Test(arguments: ["relative/codex", "/missing/codex", "/tmp/codex-directory", "/tmp/non-executable-codex"])
func rejectsInvalidExecutable(path: String) {
    #expect(throws: CodexExecutableValidationError.self) {
        try ValidatedCodexExecutable(URL(fileURLWithPath: path))
    }
}
```

Also test symlink resolution, regular-file ownership by current uid, executable bits, and that cleanup cannot escape the workspace root even if a child is replaced by a symlink.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --no-parallel --filter 'IsolatedCodexWorkspace|ValidatedCodexExecutable'`

Expected: build failure because the types are absent.

- [ ] **Step 3: Implement fail-closed validation and private creation**

```swift
public struct ValidatedCodexExecutable: Sendable, Equatable {
    public let url: URL
    public init(_ candidate: URL) throws
}

public final class IsolatedCodexWorkspace: @unchecked Sendable {
    public let root: URL
    public let codexHome: URL
    public let neutralDirectory: URL
    public static func create(baseDirectory: URL = FileManager.default.temporaryDirectory) throws -> IsolatedCodexWorkspace
    public func close()
}

public enum CodexExecutableValidationError: Error, Equatable {
    case notAbsolute, missing, notRegularFile, wrongOwner, notExecutable
}
```

Open/inspect with `lstat`/`stat`; resolve symlinks once; require absolute standardized path, regular file, current uid, and at least one executable bit. Create a UUID root plus `home` and `cwd` using `FileManager`, immediately set POSIX permissions `0700`, verify ownership/mode with `lstat`, and clean only the captured root after confirming its device/inode identity.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter 'IsolatedCodexWorkspace|ValidatedCodexExecutable'`

Expected: all boundary and cleanup cases pass.

- [ ] **Step 5: Commit the workspace boundary**

```bash
git add Sources/CodexAppServerClient/IsolatedCodexWorkspace.swift Tests/CodexAppServerClientTests/IsolatedCodexWorkspaceTests.swift
git commit -m "feat: isolate Codex compatibility workspace"
```

### Task 2: Non-Mutating Compatibility Probe

**Files:**
- Create: `Sources/CodexAppServerClient/CodexCompatibilityProbe.swift`
- Create: `Tests/CodexAppServerClientTests/CodexCompatibilityProbeTests.swift`

**Interfaces:**
- Consumes: `ValidatedCodexExecutable`, `IsolatedCodexWorkspace`, injected `CodexVersionRunning`, and injected `CompatibilitySessionFactory` for tests.
- Produces: `CodexCompatibilityProbe.run() async -> CodexCompatibilityResult`; only `initialize` and `.threadList` are sent; `CodexCompatibilitySession.closeAndAwaitOwnedChild()` always occurs and reports whether the owned child is gone.

- [ ] **Step 1: Write failing ordering, isolation, and shutdown tests**

```swift
@Test func initializesListsAndClosesExactlyOnce() async throws {
    let session = RecordingCompatibilitySession(threadListResult: .object([
        "data": .array([]), "nextCursor": .null
    ]))
    let probe = CodexCompatibilityProbe(
        executable: fixtureExecutable,
        workspace: fixtureWorkspace,
        versionRunner: StubVersionRunner("codex-cli 0.144.5"),
        sessionFactory: { _, arguments, environment, cwd in
            #expect(arguments == ["app-server"])
            #expect(environment == [
                "CODEX_HOME": fixtureWorkspace.codexHome.path,
                "HOME": fixtureWorkspace.codexHome.path,
            ])
            #expect(cwd == fixtureWorkspace.neutralDirectory)
            return session
        },
        timeout: .seconds(2)
    )

    let result = await probe.run()
    #expect(result == .passed(version: "codex-cli 0.144.5"))
    #expect(await session.methods == ["initialize", "initialized", "thread/list"])
    #expect(await session.closeCount == 1)
    #expect(await session.lastShutdown == .ownedChildExited)
}
```

Add tests for invalid thread/list shape, server error, version-command failure, initialization timeout, list timeout, cancellation, and owned-child shutdown error. In every case assert close count one and assert no forbidden method name was sent.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --no-parallel --filter CodexCompatibilityProbeTests`

Expected: build failure because probe types are absent.

- [ ] **Step 3: Implement the session and version boundaries**

```swift
public enum CodexCompatibilityFailure: String, Error, Equatable, Sendable {
    case versionUnavailable = "VERSION_UNAVAILABLE"
    case initializationFailed = "INITIALIZATION_FAILED"
    case threadListFailed = "THREAD_LIST_FAILED"
    case invalidThreadListResponse = "INVALID_THREAD_LIST_RESPONSE"
    case timedOut = "TIMED_OUT"
    case shutdownFailed = "SHUTDOWN_FAILED"
    case cancelled = "CANCELLED"
}

public enum CodexCompatibilityResult: Sendable, Equatable {
    case passed(version: String)
    case failed(version: String?, reason: CodexCompatibilityFailure)
}

public protocol CodexVersionRunning: Sendable {
    func version(executable: ValidatedCodexExecutable, environment: [String: String], cwd: URL) async throws -> String
}

public protocol CodexCompatibilitySession: Sendable {
    func initialize(clientName: String, title: String, version: String) async throws
    func call(_ method: AppServerMethod) async throws -> JSONValue
    func closeAndAwaitOwnedChild() async -> CompatibilityShutdownResult
}

public enum CompatibilityShutdownResult: Sendable, Equatable {
    case ownedChildExited
    case stillRunning
}
```

The production version runner invokes the same executable with `--version`, the isolated `CODEX_HOME`, and neutral cwd. Cap version output at 4 KiB, require one nonempty printable line, and never preserve stderr. The session factory constructs:

```swift
let transport = StdioProcessTransport(
    executable: executable.url.path,
    arguments: ["app-server"],
        environment: [
            "CODEX_HOME": workspace.codexHome.path,
            "HOME": workspace.codexHome.path,
        ],
    currentDirectory: workspace.neutralDirectory
)
return OwnedCodexCompatibilitySession(
    client: AppServerClient(transport: transport),
    transport: transport
)
```

Wrap that client and transport in a production `OwnedCodexCompatibilitySession`. Its close method first calls `client.close()`, then calls `transport.closeWithOutcome()` once more: `.alreadyExited`, `.graceful`, `.terminated`, or `.killed` maps to `.ownedChildExited`; `.stillRunning` maps to `.stillRunning`. The second call is an intentional bounded retry only for the exact owned process retained by `StdioProcessTransport`; it never signals any Desktop or unrelated process.

- [ ] **Step 4: Implement the bounded protocol sequence**

Call `initialize(clientName: "voice-inbox-compatibility-smoke", title: "Voice Inbox Compatibility Smoke", version: BridgeCommand.bridgeVersion)` through a local constant `"0.1.0"` to avoid introducing a dependency on the CLI target. Then call `.threadList`. Accept only an object containing `data` as an array and `nextCursor` as string or null/absent. Never inspect array entries. Wrap the whole operation in a throwing task group timeout and close in an unconditional `defer`-equivalent async path.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter CodexCompatibilityProbeTests`

Expected: protocol ordering, forbidden-method, timeout, cancellation, response, and close cases pass.

- [ ] **Step 6: Commit the probe**

```bash
git add Sources/CodexAppServerClient/CodexCompatibilityProbe.swift Tests/CodexAppServerClientTests/CodexCompatibilityProbeTests.swift
git commit -m "feat: probe isolated Codex compatibility"
```

### Task 3: Redacted Immutable Evidence CLI

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CodexAppServerClient/CodexCompatibilityEvidence.swift`
- Create: `Sources/CodexCompatibilitySmokeCLI/CodexCompatibilitySmokeCommand.swift`
- Create: `Sources/CodexCompatibilitySmokeCLI/main.swift`
- Create: `Tests/CodexAppServerClientTests/CodexCompatibilityEvidenceTests.swift`
- Create: `Tests/CodexCompatibilitySmokeCLITests/CodexCompatibilitySmokeCommandTests.swift`

**Interfaces:**
- Consumes: `--codex /absolute/path`, `--evidence-directory /absolute/existing/directory`, required `--source-commit` containing 40 lowercase hexadecimal characters, and optional `--timeout-seconds 1...60`.
- Produces: executable `codex-compatibility-smoke`; exclusive-create JSON named `codex-compatibility-YYYYMMDDTHHMMSSZ-UUID.json`; stdout contains label/code/version/evidence filename only.

- [ ] **Step 1: Write failing schema, immutability, and CLI tests**

```swift
@Test func evidenceContainsOnlyAllowListedFields() throws {
    let evidence = CodexCompatibilityEvidence(
        schemaVersion: 1,
        observedAt: Date(timeIntervalSince1970: 1_786_572_000),
        sourceCommit: "0123456789abcdef0123456789abcdef01234567",
        codexVersion: "codex-cli 0.144.5",
        method: "thread/list",
        result: "PASS",
        label: "unverified"
    )
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
    #expect(Set(object.keys) == ["schemaVersion", "observedAt", "sourceCommit", "codexVersion", "method", "result", "label"])
}

@Test func refusesToOverwriteEvidence() throws {
    let writer = CodexCompatibilityEvidenceWriter()
    let target = fixtureDirectory.appending(path: "existing.json")
    try Data("sentinel".utf8).write(to: target)
    #expect(throws: CodexCompatibilityEvidenceWriteError.alreadyExists) {
        try writer.write(evidence, to: target)
    }
    #expect(try String(contentsOf: target) == "sentinel")
}
```

CLI tests must reject missing/relative executable, missing/relative evidence directory, unknown options, out-of-range timeout, and a normal Codex-home path as evidence directory. Assert no fallback executable lookup and no method beyond `thread/list`.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `swift test --no-parallel --filter 'CodexCompatibilityEvidence|CodexCompatibilitySmokeCommand'`

Expected: build failure because evidence and CLI types are absent.

- [ ] **Step 3: Register executable targets and implement exclusive evidence writes**

Add:

```swift
.executable(name: "codex-compatibility-smoke", targets: ["CodexCompatibilitySmokeCLI"])
.executableTarget(name: "CodexCompatibilitySmokeCLI", dependencies: ["CodexAppServerClient", "CodexAppServerProtocol"])
.testTarget(name: "CodexCompatibilitySmokeCLITests", dependencies: ["CodexCompatibilitySmokeCLI", "CodexAppServerClient", "CodexAppServerProtocol"])
```

Use `open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)` and write canonical pretty/sorted JSON. If writing fails, unlink only the exact newly created file descriptor/path after verifying it remains inside the caller-supplied directory. Never overwrite or reuse a filename.

- [ ] **Step 4: Implement exact status semantics**

On pass, write `result=PASS`, `label=unverified`, method `thread/list`, exact version line, UTC time, and the validated explicit source commit. The result proves only that exact compatibility method; `unverified` prevents promotion to a stronger package, simulator, or physical-device layer. On failure, write the exact raw value from `CodexCompatibilityFailure`, `label=unverified`, and version only if it was obtained. Exit 0 on pass, 2 on compatibility failure, 3 on evidence/tool failure, and 64 on usage.

Do not use `physical-watch-proven` or `package-ready` for this smoke.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run: `swift test --no-parallel --filter 'CodexCompatibilityEvidence|CodexCompatibilitySmokeCommand'`

Expected: all schema, exclusive-create, argument, status, and no-fallback cases pass.

- [ ] **Step 6: Commit the CLI and evidence writer**

```bash
git add Package.swift Sources/CodexAppServerClient/CodexCompatibilityEvidence.swift Sources/CodexCompatibilitySmokeCLI Tests/CodexAppServerClientTests/CodexCompatibilityEvidenceTests.swift Tests/CodexCompatibilitySmokeCLITests
git commit -m "feat: record isolated Codex compatibility evidence"
```

### Task 4: Current Smoke, Release Record, and README Truth

**Files:**
- Create: `docs/RELEASE-VERIFICATION.md`
- Create on successful smoke: one new `docs/evidence/codex-compatibility-YYYYMMDDTHHMMSSZ-UUID.json` file whose exact path is returned by the command.
- Modify: `README.md`

**Interfaces:**
- Consumes: current exact package/signing/notary/staple/checksum evidence, deterministic simulator result, physical preflight result, and successful isolated Codex smoke evidence.
- Produces: evidence-bounded release record and README language that does not promote unverified layers.

- [ ] **Step 1: Run the current isolated compatibility smoke**

Resolve the installed executable explicitly, then run without PATH fallback:

```bash
codex_path="$(command -v codex)"
test -n "$codex_path"
mkdir -p docs/evidence
source_commit="$(git rev-parse HEAD)"
smoke_output="$(swift run codex-compatibility-smoke --codex "$codex_path" --evidence-directory "$PWD/docs/evidence" --source-commit "$source_commit" --timeout-seconds 20)"
printf '%s\n' "$smoke_output"
evidence_file="$(printf '%s\n' "$smoke_output" | sed -n 's/^evidence=//p')"
test -n "$evidence_file"
test -f "$evidence_file"
```

Expected: exit 0; exactly one new JSON file with method `thread/list`, `PASS`, exact version, no thread data, and no private path. If it fails, retain the closed failure evidence, keep README compatibility as `unverified`, and do not proceed to claim a proven version.

- [ ] **Step 2: Write the release verification document**

Use a table containing `Source commit`, `Artifact tag`, `Artifact SHA-256`, `Signing identity class`, `Gatekeeper`, `Notarization`, `Staple`, `Codex CLI/App Server`, `Watch simulator`, `Physical Watch`, `App Store/TestFlight`. Record the already verified `v0.1.0` download as `package-ready` only when its exact digest and signing/notary/staple evidence are copied from retained verification output. Record the selected simulator name/runtime and test result as `simulator-proven`. Record the physical Watch as `blocked:external` with `WATCH_TUNNEL_DISCONNECTED`. Record App Store/TestFlight as `unverified`.

- [ ] **Step 3: Update README release truth only from retained evidence**

Replace the generic package wording with these bounded statements:

```markdown
- The exact `v0.1.0` macOS bridge download is `package-ready`: its published
  checksum, Developer ID signature, Gatekeeper notarization assessment, and
  stapled ticket were verified. This does not prove the Watch app on hardware.
- Physical Apple Watch capture and the complete Watch-to-Mac workflow remain
  `blocked:external` while the connected Watch's CoreDevice tunnel is
  disconnected; simulator evidence is not physical-device evidence.
- Codex App Server compatibility is version-specific. The latest retained
  isolated `thread/list` smoke and date are recorded in
  `docs/RELEASE-VERIFICATION.md`; other versions remain `unverified`.
```

Insert the exact proven Codex version/date in `docs/RELEASE-VERIFICATION.md`, not as a cross-version support promise. Add local commands for `watch-device-preflight`, `watch-simulator-selector`, and `codex-compatibility-smoke`, each with its non-mutation boundary.

- [ ] **Step 4: Validate evidence privacy and wording**

Run:

```bash
jq -e 'keys == ["codexVersion","label","method","observedAt","result","schemaVersion","sourceCommit"]' docs/evidence/*codex-compatibility*.json
rg -n 'package-ready|blocked:external|simulator-proven|unverified|thread/list' README.md docs/RELEASE-VERIFICATION.md
rg -n 'threadId|taskId|CODEX_HOME|/Users/|serial|ECID|UDID|credential|transcript' docs/evidence/*codex-compatibility*.json docs/RELEASE-VERIFICATION.md
```

Expected: JSON key check passes; readiness wording is present; privacy scan produces no output.

- [ ] **Step 5: Commit evidence and documentation**

Stage the exact filename returned by the smoke, not a wildcard:

```bash
git add README.md docs/RELEASE-VERIFICATION.md "$evidence_file"
git commit -m "docs: record release compatibility evidence"
```

If the smoke failed, use the exact failure-evidence path emitted as `evidence=...` and commit with message `docs: record Codex compatibility blocker`.

### Task 5: Full Verification and Stop Conditions

**Files:**
- Verify only; modify only failures introduced by this plan.

**Interfaces:**
- Consumes: all three hardening subsystems and docs.
- Produces: fresh local non-mutating gate evidence and an exact remaining-gates list.

- [ ] **Step 1: Run all package tests serially**

Run: `swift test --no-parallel`

Expected: all tests pass, including proof that normal Codex state is never read.

- [ ] **Step 2: Run existing production-composed and packaging gates**

Run: `Tests/ReleasePackagingTests/package_bridge_release_contract_test.sh && Scripts/run-watch-bridge-smoke.sh`

Expected: both pass without a real Codex task mutation.

- [ ] **Step 3: Run deterministic simulator tests**

Use `watch-simulator-selector` to resolve the exact identifier and run the existing Watch test suite as specified in the simulator plan.

Expected: named exact-runtime smallest-Watch tests pass and are labeled only `simulator-proven`.

- [ ] **Step 4: Re-run physical preflight without crossing authority**

Run: `swift run watch-device-preflight`

Expected today: `blocked:external`. If `READY`, stop before provisioning/build/install and request the separate physical execution gate. Do not create/revoke certificates, register devices, prompt Speech permission, install the bridge, create Codex tasks, push, publish, or upload.

- [ ] **Step 5: Review diff and evidence claims**

Run:

```bash
git diff --check
git status --short
git log --oneline --decorate -8
rg -n 'physical-watch-proven|package-ready|simulator-proven|blocked:external|unverified' README.md docs
```

Expected: no unsupported `physical-watch-proven` claim; `package-ready` applies only to the exact bridge artifact; current external and App Store gates remain explicit.
