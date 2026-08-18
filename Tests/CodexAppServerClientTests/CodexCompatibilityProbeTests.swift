import CodexAppServerProtocol
import Foundation
import Testing
@testable import CodexAppServerClient

@Test func compatibilityProbeUsesOnlyIsolatedInitializeAndThreadListThenCloses() async throws {
    let fixture = try ProbeFixture()
    defer { fixture.close() }
    let session = RecordingCompatibilitySession(result: .object([
        "data": .array([]),
        "nextCursor": .null,
    ]))
    let probe = CodexCompatibilityProbe(
        executable: fixture.executable,
        workspace: fixture.workspace,
        versionRunner: StubVersionRunner(value: "codex-cli 0.144.5"),
        sessionFactory: { executable, arguments, environment, cwd in
            #expect(executable == fixture.executable)
            #expect(arguments == ["app-server"])
            #expect(environment == [
                "CODEX_HOME": fixture.workspace.codexHome.path,
                "HOME": fixture.workspace.codexHome.path,
            ])
            #expect(cwd == fixture.workspace.neutralDirectory)
            return session
        },
        timeout: .seconds(2)
    )

    let result = await probe.run()

    #expect(result == .passed(version: "codex-cli 0.144.5"))
    #expect(await session.methods == ["initialize", "initialized", "thread/list"])
    #expect(await session.closeCount == 1)
}

@Test func compatibilityProbeRejectsThreadDataShapeWithoutInspectingEntries() async throws {
    let fixture = try ProbeFixture()
    defer { fixture.close() }
    let session = RecordingCompatibilitySession(result: .object(["data": .object([:])]))
    let probe = fixture.probe(session: session)

    #expect(await probe.run() == .failed(
        version: "codex-cli 0.144.5",
        reason: .invalidThreadListResponse
    ))
    #expect(await session.closeCount == 1)
}

@Test func compatibilityProbeMapsVersionAndProtocolFailuresAndAlwaysCloses() async throws {
    let fixture = try ProbeFixture()
    defer { fixture.close() }

    let versionSession = RecordingCompatibilitySession(result: .object(["data": .array([])]))
    let versionProbe = fixture.probe(
        session: versionSession,
        versionRunner: StubVersionRunner(error: ProbeTestError.injected)
    )
    #expect(await versionProbe.run() == .failed(version: nil, reason: .versionUnavailable))
    #expect(await versionSession.closeCount == 1)

    let initSession = RecordingCompatibilitySession(
        result: .object(["data": .array([])]),
        initializeError: ProbeTestError.injected
    )
    #expect(await fixture.probe(session: initSession).run() == .failed(
        version: "codex-cli 0.144.5",
        reason: .initializationFailed
    ))
    #expect(await initSession.closeCount == 1)

    let listSession = RecordingCompatibilitySession(
        result: .object(["data": .array([])]),
        callError: ProbeTestError.injected
    )
    #expect(await fixture.probe(session: listSession).run() == .failed(
        version: "codex-cli 0.144.5",
        reason: .threadListFailed
    ))
    #expect(await listSession.closeCount == 1)
}

@Test func compatibilityProbeFailsWhenOwnedChildRemains() async throws {
    let fixture = try ProbeFixture()
    defer { fixture.close() }
    let session = RecordingCompatibilitySession(
        result: .object(["data": .array([])]),
        shutdown: .stillRunning
    )

    #expect(await fixture.probe(session: session).run() == .failed(
        version: "codex-cli 0.144.5",
        reason: .shutdownFailed
    ))
    #expect(await session.closeCount == 1)
}

@Test func compatibilityProbeTimesOutAndClosesTheOwnedSession() async throws {
    let fixture = try ProbeFixture()
    defer { fixture.close() }
    let session = SuspendingCompatibilitySession()
    let probe = CodexCompatibilityProbe(
        executable: fixture.executable,
        workspace: fixture.workspace,
        versionRunner: StubVersionRunner(value: "codex-cli 0.144.5"),
        sessionFactory: { _, _, _, _ in session },
        timeout: .milliseconds(10)
    )

    #expect(await probe.run() == .failed(version: nil, reason: .timedOut))
    #expect(await session.closeCount == 1)
}

@Test func processVersionRunnerDrainsLargeStderrWithoutBlocking() async throws {
    let fixture = try ExecutableFixture(script: """
    #!/bin/sh
    head -c 131072 /dev/zero >&2
    printf 'codex-cli 1.2.3\\n'
    """)
    defer { fixture.close() }

    let version = try await ProcessCodexVersionRunner().version(
        executable: fixture.executable,
        environment: [:],
        cwd: fixture.root
    )

    #expect(version == "codex-cli 1.2.3")
}

@Test func processVersionRunnerCancelsAndStopsItsOwnedChildPromptly() async throws {
    let fixture = try ExecutableFixture(script: """
    #!/bin/sh
    trap '' TERM
    while :; do sleep 1; done
    """)
    defer { fixture.close() }
    let task = Task {
        try await ProcessCodexVersionRunner().version(
            executable: fixture.executable,
            environment: [:],
            cwd: fixture.root
        )
    }
    try await Task.sleep(for: .milliseconds(100))

    let cancelledAt = ContinuousClock.now
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(cancelledAt.duration(to: .now) < .seconds(1))
}

@Test func processVersionRunnerDoesNotWaitForDescendantRetainedPipes() async throws {
    let fixture = try ExecutableFixture(script: """
    #!/bin/sh
    sleep 10 &
    printf 'codex-cli 1.2.3\\n'
    """)
    defer { fixture.close() }

    let startedAt = ContinuousClock.now
    let version = try await ProcessCodexVersionRunner().version(
        executable: fixture.executable,
        environment: [:],
        cwd: fixture.root
    )

    #expect(version == "codex-cli 1.2.3")
    #expect(startedAt.duration(to: .now) < .seconds(1))
}

private enum ProbeTestError: Error { case injected }

private struct StubVersionRunner: CodexVersionRunning {
    let value: String?
    let error: (any Error)?

    init(value: String) {
        self.value = value
        error = nil
    }

    init(error: any Error) {
        value = nil
        self.error = error
    }

    func version(
        executable: ValidatedCodexExecutable,
        environment: [String: String],
        cwd: URL
    ) async throws -> String {
        if let error { throw error }
        return value!
    }
}

private actor RecordingCompatibilitySession: CodexCompatibilitySession {
    private let result: JSONValue
    private let initializeError: (any Error)?
    private let callError: (any Error)?
    private let shutdown: CompatibilityShutdownResult
    private(set) var methods: [String] = []
    private(set) var closeCount = 0

    init(
        result: JSONValue,
        initializeError: (any Error)? = nil,
        callError: (any Error)? = nil,
        shutdown: CompatibilityShutdownResult = .ownedChildExited
    ) {
        self.result = result
        self.initializeError = initializeError
        self.callError = callError
        self.shutdown = shutdown
    }

    func initialize(clientName: String, title: String, version: String) async throws {
        methods.append("initialize")
        if let initializeError { throw initializeError }
        methods.append("initialized")
    }

    func call(_ method: AppServerMethod) async throws -> JSONValue {
        methods.append(method.name)
        if let callError { throw callError }
        return result
    }

    func closeAndAwaitOwnedChild() async -> CompatibilityShutdownResult {
        closeCount += 1
        return shutdown
    }
}

private actor SuspendingCompatibilitySession: CodexCompatibilitySession {
    private(set) var closeCount = 0

    func initialize(clientName: String, title: String, version: String) async throws {
        try await Task.sleep(for: .seconds(10))
    }

    func call(_ method: AppServerMethod) async throws -> JSONValue {
        .object(["data": .array([])])
    }

    func closeAndAwaitOwnedChild() async -> CompatibilityShutdownResult {
        closeCount += 1
        return .ownedChildExited
    }
}

private final class ProbeFixture: @unchecked Sendable {
    let root: URL
    let executable: ValidatedCodexExecutable
    let workspace: IsolatedCodexWorkspace

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("compatibility-probe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        executable = try ValidatedCodexExecutable(executableURL)
        workspace = try IsolatedCodexWorkspace.create(baseDirectory: root)
    }

    func probe(
        session: RecordingCompatibilitySession,
        versionRunner: any CodexVersionRunning = StubVersionRunner(value: "codex-cli 0.144.5")
    ) -> CodexCompatibilityProbe {
        CodexCompatibilityProbe(
            executable: executable,
            workspace: workspace,
            versionRunner: versionRunner,
            sessionFactory: { _, _, _, _ in session },
            timeout: .seconds(2)
        )
    }

    func close() {
        workspace.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ExecutableFixture: @unchecked Sendable {
    let root: URL
    let executable: ValidatedCodexExecutable

    init(script: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "compatibility-version-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appendingPathComponent("codex")
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )
        executable = try ValidatedCodexExecutable(executableURL)
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
