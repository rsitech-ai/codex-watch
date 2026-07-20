import Darwin
import Foundation

public struct OwnedChildShutdownPolicy: Equatable, Sendable {
    public let gracefulTimeout: Duration
    public let terminateTimeout: Duration
    public let killTimeout: Duration

    public init(
        gracefulTimeout: Duration,
        terminateTimeout: Duration,
        killTimeout: Duration
    ) {
        self.gracefulTimeout = gracefulTimeout
        self.terminateTimeout = terminateTimeout
        self.killTimeout = killTimeout
    }

    public static let production = Self(
        gracefulTimeout: .seconds(5),
        terminateTimeout: .seconds(5),
        killTimeout: .seconds(2)
    )
}

public protocol OwnedProcessSignaling: Sendable {
    func terminate(_ process: Process)
    func kill(pid: pid_t) -> Int32
}

public struct DarwinOwnedProcessSignaling: OwnedProcessSignaling {
    public init() {}

    public func terminate(_ process: Process) {
        process.terminate()
    }

    public func kill(pid: pid_t) -> Int32 {
        Darwin.kill(pid, SIGKILL)
    }
}

public enum OwnedChildShutdownOutcome: Equatable, Sendable {
    case alreadyExited
    case graceful
    case terminated
    case killed
    case stillRunning(pid: pid_t, killResult: Int32)
}

public struct OwnedChildShutdown: Sendable {
    private let policy: OwnedChildShutdownPolicy
    private let signaling: any OwnedProcessSignaling

    public init(
        policy: OwnedChildShutdownPolicy = .production,
        signaling: any OwnedProcessSignaling = DarwinOwnedProcessSignaling()
    ) {
        self.policy = policy
        self.signaling = signaling
    }

    public func stop(process: Process, stdin: FileHandle?) async -> OwnedChildShutdownOutcome {
        let capturedIdentity = ObjectIdentifier(process)
        let capturedPID = process.processIdentifier
        let wasRunning = process.isRunning
        let termination = OwnedProcessTerminationObserver(process: process)

        try? stdin?.close()
        guard wasRunning else { return .alreadyExited }
        if await termination.wait(upTo: policy.gracefulTimeout) { return .graceful }

        guard isSameProcess(process, identity: capturedIdentity, pid: capturedPID) else {
            return .stillRunning(pid: capturedPID, killResult: ESRCH)
        }
        guard process.isRunning else { return .graceful }
        signaling.terminate(process)
        if await termination.wait(upTo: policy.terminateTimeout) { return .terminated }

        guard isSameProcess(process, identity: capturedIdentity, pid: capturedPID) else {
            return .stillRunning(pid: capturedPID, killResult: ESRCH)
        }
        guard process.isRunning else { return .terminated }
        let killResult = signaling.kill(pid: capturedPID)
        if await termination.wait(upTo: policy.killTimeout) { return .killed }
        if !process.isRunning { return .killed }
        return .stillRunning(pid: capturedPID, killResult: killResult)
    }

    private func isSameProcess(
        _ process: Process,
        identity: ObjectIdentifier,
        pid: pid_t
    ) -> Bool {
        ObjectIdentifier(process) == identity
            && process.processIdentifier == pid
            && pid > 0
    }
}

private final class OwnedProcessTerminationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var didTerminate = false
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]

    init(process: Process) {
        let previousHandler = process.terminationHandler
        process.terminationHandler = { [weak self] process in
            self?.markTerminated()
            previousHandler?(process)
        }

        if !process.isRunning {
            markTerminated()
        }
    }

    func wait(upTo timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiterID: UInt64? = lock.withLock {
                guard !didTerminate else { return nil }
                nextWaiterID &+= 1
                waiters[nextWaiterID] = continuation
                return nextWaiterID
            }

            guard let waiterID else {
                continuation.resume(returning: true)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.timeOut(waiterID)
            }
        }
    }

    private func markTerminated() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            guard !didTerminate else { return [] }
            didTerminate = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    private func timeOut(_ waiterID: UInt64) {
        let continuation = lock.withLock { waiters.removeValue(forKey: waiterID) }
        continuation?.resume(returning: false)
    }
}
