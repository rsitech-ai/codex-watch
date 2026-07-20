import Darwin
import Foundation
import Testing
@testable import CodexAppServerClient

@Test func productionOwnedChildShutdownPolicyUsesFiveFiveTwoSecondDeadlines() {
    #expect(OwnedChildShutdownPolicy.production == OwnedChildShutdownPolicy(
        gracefulTimeout: .seconds(5),
        terminateTimeout: .seconds(5),
        killTimeout: .seconds(2)
    ))
}

@Test func ownedChildExitsGracefullyWhenItsStdinClosesWithoutReceivingASignal() async throws {
    let fixture = try OwnedChildFixture(behavior: .exitsOnStdinClose)
    defer { fixture.cleanup() }

    let outcome = await fixture.shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    #expect(outcome == .graceful)
    #expect(!fixture.child.isRunning)
    #expect(fixture.signaling.terminatedPIDs.isEmpty)
    #expect(fixture.signaling.killedPIDs.isEmpty)
}

@Test func ownedChildThatIgnoresStdinReceivesExactChildTerminateOnly() async throws {
    let fixture = try OwnedChildFixture(behavior: .exitsOnTerminate)
    defer { fixture.cleanup() }
    try await Task.sleep(for: .milliseconds(20))

    let outcome = await fixture.shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    #expect(outcome == .terminated)
    #expect(!fixture.child.isRunning)
    #expect(fixture.sentinel.isRunning)
    #expect(fixture.signaling.terminatedPIDs == [fixture.child.processIdentifier])
    #expect(fixture.signaling.killedPIDs.isEmpty)
}

@Test func hungExactChildEscalatesWithinBoundWithoutSignalingSentinel() async throws {
    let fixture = try OwnedChildFixture(behavior: .requiresKill)
    defer { fixture.cleanup() }
    try await Task.sleep(for: .milliseconds(20))
    let startedAt = ContinuousClock.now

    let outcome = await fixture.shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    let elapsed = startedAt.duration(to: .now)
    #expect(outcome == .killed)
    #expect(!fixture.child.isRunning)
    #expect(fixture.sentinel.isRunning)
    #expect(fixture.signaling.terminatedPIDs == [fixture.child.processIdentifier])
    #expect(fixture.signaling.killedPIDs == [fixture.child.processIdentifier])
    #expect(elapsed < .seconds(2))
}

@Test func alreadyExitedOwnedChildIsNeverSignaled() async throws {
    let fixture = try OwnedChildFixture(behavior: .alreadyExits)
    defer { fixture.cleanup() }
    try await waitUntilStopped(fixture.child, timeout: .seconds(1))

    let outcome = await fixture.shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    #expect(outcome == .alreadyExited)
    #expect(fixture.signaling.terminatedPIDs.isEmpty)
    #expect(fixture.signaling.killedPIDs.isEmpty)
    #expect(fixture.sentinel.isRunning)
}

@Test func terminationHandlerIsDeliveredExactlyOnceAcrossTimeoutEscalations() async throws {
    let fixture = try OwnedChildFixture(behavior: .requiresKill)
    defer { fixture.cleanup() }
    let terminations = LockedCounter()
    fixture.child.terminationHandler = { _ in terminations.increment() }
    try await Task.sleep(for: .milliseconds(20))

    let outcome = await fixture.shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )
    try await Task.sleep(for: .milliseconds(20))

    #expect(outcome == .killed)
    #expect(terminations.value == 1)
    #expect(fixture.sentinel.isRunning)
}

@Test func failedKillReturnsAfterFinalBookkeepingDeadlineWithoutTouchingSentinel() async throws {
    let fixture = try OwnedChildFixture(behavior: .requiresKill)
    defer { fixture.cleanup() }
    let signaling = RefusingKillSignaling()
    let shutdown = OwnedChildShutdown(
        policy: OwnedChildShutdownPolicy(
            gracefulTimeout: .milliseconds(40),
            terminateTimeout: .milliseconds(40),
            killTimeout: .milliseconds(80)
        ),
        signaling: signaling
    )
    try await Task.sleep(for: .milliseconds(20))
    let startedAt = ContinuousClock.now

    let outcome = await shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    #expect(outcome == .stillRunning(pid: fixture.child.processIdentifier, killResult: -1))
    #expect(startedAt.duration(to: .now) < .seconds(1))
    #expect(fixture.child.isRunning)
    #expect(fixture.sentinel.isRunning)
    #expect(signaling.terminatedPIDs == [fixture.child.processIdentifier])
    #expect(signaling.killedPIDs == [fixture.child.processIdentifier])
}

@Test func successfulKillResultWithoutExitReturnsStillRunningAfterFinalDeadline() async throws {
    let fixture = try OwnedChildFixture(behavior: .requiresKill)
    defer { fixture.cleanup() }
    let signaling = NonDeliveringKillSignaling(killResult: 0)
    let shutdown = OwnedChildShutdown(
        policy: OwnedChildShutdownPolicy(
            gracefulTimeout: .milliseconds(40),
            terminateTimeout: .milliseconds(40),
            killTimeout: .milliseconds(80)
        ),
        signaling: signaling
    )
    try await Task.sleep(for: .milliseconds(20))

    let outcome = await shutdown.stop(
        process: fixture.child,
        stdin: fixture.stdin.fileHandleForWriting
    )

    #expect(outcome == .stillRunning(pid: fixture.child.processIdentifier, killResult: 0))
    #expect(fixture.child.isRunning)
    #expect(fixture.sentinel.isRunning)
}

private enum OwnedChildBehavior {
    case exitsOnStdinClose
    case exitsOnTerminate
    case requiresKill
    case alreadyExits

    var script: String {
        switch self {
        case .exitsOnStdinClose:
            "while IFS= read -r ignored; do :; done"
        case .exitsOnTerminate:
            "trap 'exit 0' TERM; while :; do :; done"
        case .requiresKill:
            "trap '' TERM; while :; do :; done"
        case .alreadyExits:
            "exit 0"
        }
    }

    var requiresStartupReadiness: Bool {
        switch self {
        case .exitsOnTerminate, .requiresKill:
            true
        case .exitsOnStdinClose, .alreadyExits:
            false
        }
    }
}

private final class OwnedChildFixture: @unchecked Sendable {
    let child = Process()
    let stdin = Pipe()
    let sentinel = Process()
    let signaling = RecordingOwnedProcessSignaling()
    let shutdown: OwnedChildShutdown

    init(behavior: OwnedChildBehavior) throws {
        shutdown = OwnedChildShutdown(
            policy: OwnedChildShutdownPolicy(
                gracefulTimeout: .milliseconds(80),
                terminateTimeout: .milliseconds(80),
                killTimeout: .milliseconds(500)
            ),
            signaling: signaling
        )

        sentinel.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sentinel.arguments = ["60"]
        sentinel.standardInput = FileHandle.nullDevice
        sentinel.standardOutput = FileHandle.nullDevice
        sentinel.standardError = FileHandle.nullDevice
        try sentinel.run()

        let readiness = Pipe()
        let childScript = behavior.requiresStartupReadiness
            ? behavior.script.replacingOccurrences(of: "while", with: "printf R; while")
            : behavior.script
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", childScript]
        child.standardInput = stdin
        child.standardOutput = behavior.requiresStartupReadiness
            ? readiness
            : FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        if behavior.requiresStartupReadiness {
            let signal = readiness.fileHandleForReading.readData(ofLength: 1)
            guard signal == Data("R".utf8) else { throw CocoaError(.fileReadUnknown) }
        }
    }

    func cleanup() {
        try? stdin.fileHandleForWriting.close()
        if child.isRunning {
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
        if sentinel.isRunning {
            _ = Darwin.kill(sentinel.processIdentifier, SIGKILL)
        }
    }
}

private final class RecordingOwnedProcessSignaling: OwnedProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTerminatedPIDs: [pid_t] = []
    private var recordedKilledPIDs: [pid_t] = []

    var terminatedPIDs: [pid_t] { lock.withLock { recordedTerminatedPIDs } }
    var killedPIDs: [pid_t] { lock.withLock { recordedKilledPIDs } }

    func terminate(_ process: Process) {
        lock.withLock { recordedTerminatedPIDs.append(process.processIdentifier) }
        process.terminate()
    }

    func kill(pid: pid_t) -> Int32 {
        lock.withLock { recordedKilledPIDs.append(pid) }
        return Darwin.kill(pid, SIGKILL)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class RefusingKillSignaling: OwnedProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var terminations: [pid_t] = []
    private var kills: [pid_t] = []

    var terminatedPIDs: [pid_t] { lock.withLock { terminations } }
    var killedPIDs: [pid_t] { lock.withLock { kills } }

    func terminate(_ process: Process) {
        lock.withLock { terminations.append(process.processIdentifier) }
        process.terminate()
    }

    func kill(pid: pid_t) -> Int32 {
        lock.withLock { kills.append(pid) }
        return -1
    }
}

private final class NonDeliveringKillSignaling: OwnedProcessSignaling, @unchecked Sendable {
    private let killResult: Int32

    init(killResult: Int32) {
        self.killResult = killResult
    }

    func terminate(_ process: Process) {
        process.terminate()
    }

    func kill(pid: pid_t) -> Int32 {
        _ = pid
        return killResult
    }
}

private func waitUntilStopped(_ process: Process, timeout: Duration) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while process.isRunning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!process.isRunning)
}
