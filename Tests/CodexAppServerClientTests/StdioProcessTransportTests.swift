import Foundation
import Testing
import Darwin
@testable import CodexAppServerClient

@Test func stdioCloseTerminatesOnlyOwnedChild() async throws {
    let recorder = ProcessRecorder()
    let transport = StdioProcessTransport(
        executable: "/usr/bin/env",
        arguments: ["cat"],
        processFactory: recorder.makeProcess
    )

    try await transport.connect()
    await transport.close()

    #expect(recorder.createdCount == 1)
    #expect(recorder.stoppedCreatedProcessCount == 1)
}

@Test func concurrentStdioCloseBoundsHungChildAndFinishesFramesOnce() async throws {
    let recorder = ProcessRecorder()
    let signaling = StdioSignalingRecorder()
    let finishes = StdioFinishRecorder()
    let completions = StdioCloseCompletionProbe()
    let sentinel = try makeStdioSentinel()
    defer { stopStdioFixtureProcess(sentinel) }
    let transport = StdioProcessTransport(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; while :; do :; done"],
        processFactory: recorder.makeProcess,
        shutdown: OwnedChildShutdown(
            policy: OwnedChildShutdownPolicy(
                gracefulTimeout: .milliseconds(80),
                terminateTimeout: .milliseconds(80),
                killTimeout: .milliseconds(500)
            ),
            signaling: signaling
        ),
        onFrameStreamFinish: finishes.record
    )
    var frames = transport.frames().makeAsyncIterator()

    try await transport.connect()
    try await Task.sleep(for: .milliseconds(20))
    let firstClose = Task {
        let outcome = await transport.closeWithOutcome()
        await completions.completeFirst(outcome)
        return outcome
    }
    let signalDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while signaling.terminatedPIDs.isEmpty, ContinuousClock.now < signalDeadline {
        await Task.yield()
    }
    let secondClose = Task {
        let outcome = await transport.closeWithOutcome()
        await completions.completeSecond(outcome, observedFinishCount: finishes.count)
        return outcome
    }
    for _ in 0 ..< 100 { await Task.yield() }

    #expect(!(await completions.secondDidComplete))

    let firstOutcome = await firstClose.value
    let secondOutcome = await secondClose.value

    let childPID = try #require(recorder.createdPIDs.first)
    #expect(firstOutcome == .killed)
    #expect(secondOutcome == .killed)
    #expect(await completions.secondObservedFinishCount == 1)
    #expect(recorder.stoppedCreatedProcessCount == 1)
    #expect(signaling.terminatedPIDs == [childPID])
    #expect(signaling.killedPIDs == [childPID])
    #expect(sentinel.isRunning)
    #expect(finishes.count == 1)
    #expect(try await frames.next() == nil)
    #expect(try await frames.next() == nil)
}

@Test func failedStdioKillRetainsExactChildForRetryAndFinishesFramesWithErrorOnce() async throws {
    let recorder = ProcessRecorder()
    let signaling = RetryableStdioKillSignaling()
    let finishes = StdioFinishRecorder()
    let sentinel = try makeStdioSentinel()
    defer { stopStdioFixtureProcess(sentinel) }
    let transport = StdioProcessTransport(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; while :; do :; done"],
        processFactory: recorder.makeProcess,
        shutdown: OwnedChildShutdown(
            policy: OwnedChildShutdownPolicy(
                gracefulTimeout: .milliseconds(40),
                terminateTimeout: .milliseconds(40),
                killTimeout: .milliseconds(80)
            ),
            signaling: signaling
        ),
        onFrameStreamFinish: finishes.record
    )
    var frames = transport.frames().makeAsyncIterator()
    try await transport.connect()
    try await Task.sleep(for: .milliseconds(20))
    let childPID = try #require(recorder.createdPIDs.first)

    let failed = await transport.closeWithOutcome()

    #expect(failed == .stillRunning(pid: childPID, killResult: -1))
    #expect(recorder.stoppedCreatedProcessCount == 0)
    #expect(sentinel.isRunning)
    await #expect(throws: StdioProcessTransportShutdownError.stillRunning(
        pid: childPID,
        killResult: -1
    )) {
        _ = try await frames.next()
    }
    #expect(finishes.count == 1)

    let retried = await transport.closeWithOutcome()

    #expect(retried == .killed)
    #expect(recorder.stoppedCreatedProcessCount == 1)
    #expect(signaling.killedPIDs == [childPID, childPID])
    #expect(sentinel.isRunning)
    #expect(finishes.count == 1)
}

@Test func stdioEmitsOnlyNonEmptyNewlineDelimitedFrames() async throws {
    let transport = StdioProcessTransport(
        executable: "/bin/sh",
        arguments: ["-c", #"printf '\n{\"id\":1,\"result\":{}}\n\n'"#]
    )
    var frames = transport.frames().makeAsyncIterator()

    try await transport.connect()
    let frame = try await frames.next()
    await transport.close()

    #expect(frame == Data(#"{"id":1,"result":{}}"#.utf8))
}

@Test func stdioDiscardsUnterminatedTailAtEOF() async throws {
    let transport = StdioProcessTransport(
        executable: "/bin/sh",
        arguments: ["-c", #"printf '{"id":1,"result":{}}'"#]
    )
    var frames = transport.frames().makeAsyncIterator()

    try await transport.connect()
    let frame = try await frames.next()
    await transport.close()

    #expect(frame == nil)
}

@Test func stdioRejectsASecondConnectWithoutCreatingAnotherProcess() async throws {
    let recorder = ProcessRecorder()
    let transport = StdioProcessTransport(
        executable: "/usr/bin/env",
        arguments: ["cat"],
        processFactory: recorder.makeProcess
    )

    try await transport.connect()
    do {
        try await transport.connect()
        Issue.record("Expected a second connect to fail")
    } catch {
        #expect(recorder.createdCount == 1)
    }
    await transport.close()
}

private final class ProcessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var createdProcesses: [Process] = []

    var createdCount: Int {
        lock.withLock { createdProcesses.count }
    }

    var stoppedCreatedProcessCount: Int {
        lock.withLock {
            createdProcesses.count { !$0.isRunning }
        }
    }

    var createdPIDs: [pid_t] {
        lock.withLock { createdProcesses.map(\.processIdentifier) }
    }

    func makeProcess() -> Process {
        let process = Process()
        lock.withLock { createdProcesses.append(process) }
        return process
    }
}

private final class StdioSignalingRecorder: OwnedProcessSignaling, @unchecked Sendable {
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
        return Darwin.kill(pid, SIGKILL)
    }
}

private final class RetryableStdioKillSignaling: OwnedProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var killAttempts: [pid_t] = []

    var killedPIDs: [pid_t] { lock.withLock { killAttempts } }

    func terminate(_ process: Process) {
        process.terminate()
    }

    func kill(pid: pid_t) -> Int32 {
        let attempt = lock.withLock {
            killAttempts.append(pid)
            return killAttempts.count
        }
        guard attempt > 1 else { return -1 }
        return Darwin.kill(pid, SIGKILL)
    }
}

private final class StdioFinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var finishCount = 0

    var count: Int { lock.withLock { finishCount } }
    func record() { lock.withLock { finishCount += 1 } }
}

private actor StdioCloseCompletionProbe {
    private(set) var firstDidComplete = false
    private(set) var secondDidComplete = false
    private(set) var secondObservedFinishCount: Int?

    func completeFirst(_ outcome: OwnedChildShutdownOutcome) {
        _ = outcome
        firstDidComplete = true
    }

    func completeSecond(_ outcome: OwnedChildShutdownOutcome, observedFinishCount: Int) {
        _ = outcome
        secondDidComplete = true
        secondObservedFinishCount = observedFinishCount
    }
}

private func makeStdioSentinel() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func stopStdioFixtureProcess(_ process: Process) {
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
}
