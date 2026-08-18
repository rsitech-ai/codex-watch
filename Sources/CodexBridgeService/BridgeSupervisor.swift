import Foundation
import Dispatch
import Security
import CodexBridgeShared

public protocol BridgeIntakeRecovering: Sendable {
    func recoverIntake() async throws
}

public protocol BridgePendingMemoProcessing: Sendable {
    func recoverPendingMemos() async throws
}

public protocol BridgeIntakeRecordSource: Sendable {
    func committedRecord(for memoID: MemoID) async throws -> CommittedIntakeRecord?
    func committedRecordPage(
        maximumEntries: Int,
        afterMemoID: MemoID?
    ) async throws -> CommittedIntakePage
}

extension IntakeStore: BridgeIntakeRecordSource {}

/// An explicitly owned background processor can be stopped without ever
/// deleting its durable intake source.  A later recovery enumerates that
/// source again.
public protocol BridgePendingMemoStopping: Sendable {
    func stopPendingMemos() async
}

public protocol BridgeMemoProcessing: Sendable {
    func process(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome
}

public protocol BridgeMemoRetrying: Sendable {
    func retry(_ request: MemoProcessingRequest) async throws -> MemoProcessingOutcome
}

extension MemoProcessor: BridgeMemoProcessing {}
extension MemoProcessor: BridgeMemoRetrying {}

public protocol BridgeListenerControlling: Sendable {
    func start() async throws
    func waitUntilStopped() async throws
    func stop() async
}

public typealias BridgeListenerFactory = @Sendable () throws -> any BridgeListenerControlling

protocol BridgePauseObservationScheduling: Sendable {
    func start(_ handler: @escaping @Sendable () -> Void)
    func stop()
}

final class DispatchBridgePauseObservationScheduler: BridgePauseObservationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.rsitech.codex-watch.pause-observer")
    private var timer: (any DispatchSourceTimer)?

    func start(_ handler: @escaping @Sendable () -> Void) {
        let replacement = DispatchSource.makeTimerSource(queue: queue)
        replacement.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        replacement.setEventHandler(handler: handler)
        replacement.activate()
        let previous = lock.withLock {
            let previous = timer
            timer = replacement
            return previous
        }
        previous?.cancel()
    }

    func stop() {
        let current = lock.withLock {
            let current = timer
            timer = nil
            return current
        }
        current?.cancel()
    }

    deinit { stop() }
}

public enum BridgeOwnedChildStopOutcome: Equatable, Sendable {
    case stopped
    case stillRunning(pid: pid_t, killResult: Int32)
}

public struct BridgeOwnedChildStopFailure: Equatable, Sendable {
    public let pid: pid_t
    public let killResult: Int32

    public init(pid: pid_t, killResult: Int32) {
        self.pid = pid
        self.killResult = killResult
    }
}

public protocol BridgeOwnedChild: AnyObject, Sendable {
    func stop() async -> BridgeOwnedChildStopOutcome
}

/// Keeps process termination wiring ahead of any recovery that might spawn a
/// transcription or App Server child. The installer closure is injectable so
/// ordering is verified without delivering a real signal in tests.
public enum BridgeRuntimeBootstrap {
    public static func start(
        supervisor: BridgeSupervisor,
        installTerminationHandling: @Sendable () async -> Void
    ) async throws {
        await installTerminationHandling()
        try await supervisor.runWithReconnect()
    }
}

public enum BridgeSupervisorError: Error, Equatable, Sendable {
    case invalidConfiguration
    case paused
    case diskPressure
    case alreadyRunning
    case listenerFailed
    case statePersistenceFailed
}

public enum BridgeSupervisorState: String, Codable, Equatable, Sendable {
    case stopped
    case running
    case paused
    case retryWaiting
    case shutdownBlocked
}

public struct BridgeSupervisorStatus: Equatable, Sendable {
    public let state: BridgeSupervisorState
    public let nextRetryDelaySeconds: Int?
    public let ownedChildCount: Int
    public let ownedChildStopFailures: [BridgeOwnedChildStopFailure]

    public var redactedDescription: String {
        let retry = nextRetryDelaySeconds.map(String.init) ?? "none"
        return "state=\(state.rawValue); retry=\(retry); owned-children=\(ownedChildCount)"
    }
}

/// A per-service advisory lock is the live-process truth. The pause JSON is a
/// control request, not evidence that a process is still running.
public final class BridgeServiceLease: @unchecked Sendable {
    private let lockURL: URL
    private let beforeFinalPathValidation: () throws -> Void
    private var descriptor: Int32 = -1
    private(set) var generation: String?

    public init(stateDirectory: URL) {
        lockURL = stateDirectory.standardizedFileURL.appendingPathComponent("service.lock")
        beforeFinalPathValidation = {}
    }

    init(
        stateDirectory: URL,
        beforeFinalPathValidation: @escaping () throws -> Void
    ) {
        lockURL = stateDirectory.standardizedFileURL.appendingPathComponent("service.lock")
        self.beforeFinalPathValidation = beforeFinalPathValidation
    }

    deinit { release() }

    public func acquire() throws {
        guard descriptor < 0 else { return }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw BridgeSupervisorError.statePersistenceFailed }
        guard let identity = SecureAdvisoryLockFile.descriptorIdentity(fd, normalizeMode: true) else {
            close(fd)
            throw BridgeSupervisorError.statePersistenceFailed
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(fd)
            if lockError == EWOULDBLOCK { throw BridgeSupervisorError.alreadyRunning }
            throw BridgeSupervisorError.statePersistenceFailed
        }
        guard SecureAdvisoryLockFile.path(lockURL, matches: identity) else {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw BridgeSupervisorError.statePersistenceFailed
        }
        do { try beforeFinalPathValidation() }
        catch {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw BridgeSupervisorError.statePersistenceFailed
        }
        guard SecureAdvisoryLockFile.path(lockURL, matches: identity) else {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw BridgeSupervisorError.statePersistenceFailed
        }
        let newGeneration = UUID().uuidString.lowercased()
        let bytes = Data(newGeneration.utf8)
        guard ftruncate(fd, 0) == 0,
              bytes.withUnsafeBytes({ raw in
                  Darwin.write(fd, raw.baseAddress, raw.count) == raw.count
              }),
              fsync(fd) == 0
        else {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw BridgeSupervisorError.statePersistenceFailed
        }
        descriptor = fd
        generation = newGeneration
    }

    public func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
        generation = nil
    }

    public static func isLive(stateDirectory: URL) -> Bool {
        let lockURL = stateDirectory.standardizedFileURL.appendingPathComponent("service.lock")
        let fd = open(lockURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let identity = SecureAdvisoryLockFile.descriptorIdentity(
            fd,
            normalizeMode: false
        ) else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK
                && SecureAdvisoryLockFile.path(lockURL, matches: identity)
        }
        guard SecureAdvisoryLockFile.path(lockURL, matches: identity) else {
            _ = flock(fd, LOCK_UN)
            return false
        }
        _ = flock(fd, LOCK_UN)
        return false
    }

    static func persistedGeneration(stateDirectory: URL) -> String? {
        let lockURL = stateDirectory.standardizedFileURL.appendingPathComponent("service.lock")
        let fd = open(lockURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let identity = SecureAdvisoryLockFile.descriptorIdentity(fd, normalizeMode: false),
              SecureAdvisoryLockFile.path(lockURL, matches: identity)
        else { return nil }
        var storage = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &storage, storage.count)
        guard count > 0,
              SecureAdvisoryLockFile.path(lockURL, matches: identity)
        else { return nil }
        let value = String(decoding: storage.prefix(count), as: UTF8.self)
        return UUID(uuidString: value) == nil ? nil : value.lowercased()
    }
}

public struct BridgeRuntimePaths: Equatable, Sendable {
    public let root: URL
    public let intake: URL
    public let retained: URL
    public let delivery: URL
    public let service: URL
    public let codexInbox: URL

    public init(root: URL) throws {
        let root = root.standardizedFileURL
        guard root.isFileURL, root.path != "/" else { throw BridgeSupervisorError.invalidConfiguration }
        self.root = root
        intake = root.appending(path: "intake", directoryHint: .isDirectory)
        retained = root.appending(path: "retained", directoryHint: .isDirectory)
        delivery = root.appending(path: "delivery", directoryHint: .isDirectory)
        service = root.appending(path: "service", directoryHint: .isDirectory)
        codexInbox = root.appending(path: "codex-inbox", directoryHint: .isDirectory)
    }

    public func prepareRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: root.path
            )
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }

    /// App Server input is deliberately separated from durable bridge data.
    /// It must be a newly-created or already-empty private directory owned by
    /// this user; accepting a link or leftover content could redirect Codex.
    public func prepareCodexInbox() throws {
        do {
            try prepareRoot()
            var metadata = stat()
            if lstat(codexInbox.path, &metadata) != 0 {
                guard errno == ENOENT else { throw BridgeSupervisorError.statePersistenceFailed }
                try FileManager.default.createDirectory(
                    at: codexInbox,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                guard lstat(codexInbox.path, &metadata) == 0 else {
                    throw BridgeSupervisorError.statePersistenceFailed
                }
            }
            let mode = metadata.st_mode
            guard (mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid(),
                  (mode & 0o777) == 0o700,
                  try FileManager.default.contentsOfDirectory(atPath: codexInbox.path).isEmpty
            else { throw BridgeSupervisorError.statePersistenceFailed }
        } catch let error as BridgeSupervisorError {
            throw error
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }
}

public actor BridgeSupervisor {
    private struct PersistedState: Codable {
        let paused: Bool
    }

    private struct ReadinessState: Codable {
        let pid: pid_t
        let generation: String
    }

    private struct OwnedRuntimeDrain {
        let generation: UInt64
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let stateDirectory: URL
    private let pauseURL: URL
    private let readinessURL: URL
    private let minimumFreeBytes: Int64
    private let availableBytes: @Sendable () -> Int64
    private let recovery: any BridgeIntakeRecovering
    private let processor: any BridgePendingMemoProcessing
    private let listenerFactory: BridgeListenerFactory
    private let lease: BridgeServiceLease
    private let sleepSeconds: @Sendable (Int) async -> Void
    private let retryJitterSeconds: @Sendable (Int) -> Int
    private let pauseObserverScheduler: any BridgePauseObservationScheduling
    private let diagnosticSink: @Sendable (BridgeDiagnosticEvent) -> Void
    private var state: BridgeSupervisorState
    private var retryBackoffBaseSeconds: Int?
    private var retryDelaySeconds: Int?
    private var ownedChildren: [ObjectIdentifier: any BridgeOwnedChild] = [:]
    private var ownedChildStopFailures: [ObjectIdentifier: BridgeOwnedChildStopFailure] = [:]
    private var pauseObserverGeneration: UInt64 = 0
    private var pauseObserverPollInFlight = false
    private var listener: (any BridgeListenerControlling)?
    private var shutdownRequested = false
    private var ownedRuntimeNeedsStop = false
    private var ownedRuntimeDrain: OwnedRuntimeDrain?
    private var ownedRuntimeDrainGeneration: UInt64 = 0

    public init(
        stateDirectory: URL,
        minimumFreeBytes: Int64 = 128 * 1_024 * 1_024,
        availableBytes: @escaping @Sendable () -> Int64,
        recovery: any BridgeIntakeRecovering,
        processor: any BridgePendingMemoProcessing,
        listenerFactory: @escaping BridgeListenerFactory,
        sleepSeconds: @escaping @Sendable (Int) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        retryJitterSeconds: @escaping @Sendable (Int) -> Int = { base in
            Int.random(in: 0 ... min(15, max(1, base / 2)))
        },
        diagnosticSink: @escaping @Sendable (BridgeDiagnosticEvent) -> Void = { _ in }
    ) throws {
        try self.init(
            stateDirectory: stateDirectory,
            minimumFreeBytes: minimumFreeBytes,
            availableBytes: availableBytes,
            recovery: recovery,
            processor: processor,
            listenerFactory: listenerFactory,
            sleepSeconds: sleepSeconds,
            retryJitterSeconds: retryJitterSeconds,
            pauseObserverScheduler: DispatchBridgePauseObservationScheduler(),
            diagnosticSink: diagnosticSink
        )
    }

    init(
        stateDirectory: URL,
        minimumFreeBytes: Int64 = 128 * 1_024 * 1_024,
        availableBytes: @escaping @Sendable () -> Int64,
        recovery: any BridgeIntakeRecovering,
        processor: any BridgePendingMemoProcessing,
        listenerFactory: @escaping BridgeListenerFactory,
        sleepSeconds: @escaping @Sendable (Int) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        retryJitterSeconds: @escaping @Sendable (Int) -> Int = { _ in 0 },
        pauseObserverScheduler: any BridgePauseObservationScheduling,
        diagnosticSink: @escaping @Sendable (BridgeDiagnosticEvent) -> Void = { _ in }
    ) throws {
        guard minimumFreeBytes > 0 else { throw BridgeSupervisorError.invalidConfiguration }
        self.stateDirectory = stateDirectory.standardizedFileURL
        pauseURL = stateDirectory.standardizedFileURL.appendingPathComponent("pause-state.json")
        readinessURL = stateDirectory.standardizedFileURL.appendingPathComponent("service.ready")
        self.minimumFreeBytes = minimumFreeBytes
        self.availableBytes = availableBytes
        self.recovery = recovery
        self.processor = processor
        self.listenerFactory = listenerFactory
        self.sleepSeconds = sleepSeconds
        self.retryJitterSeconds = retryJitterSeconds
        self.pauseObserverScheduler = pauseObserverScheduler
        self.diagnosticSink = diagnosticSink
        try Self.prepareStateDirectory(stateDirectory.standardizedFileURL)
        lease = BridgeServiceLease(stateDirectory: stateDirectory)
        state = try Self.loadPausedState(at: pauseURL) ? .paused : .stopped
    }

    public init(
        stateDirectory: URL,
        minimumFreeBytes: Int64 = 128 * 1_024 * 1_024,
        availableBytes: @escaping @Sendable () -> Int64,
        recovery: any BridgeIntakeRecovering,
        processor: any BridgePendingMemoProcessing,
        listener: any BridgeListenerControlling,
        sleepSeconds: @escaping @Sendable (Int) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        retryJitterSeconds: @escaping @Sendable (Int) -> Int = { base in
            Int.random(in: 0 ... min(15, max(1, base / 2)))
        },
        diagnosticSink: @escaping @Sendable (BridgeDiagnosticEvent) -> Void = { _ in }
    ) throws {
        try self.init(
            stateDirectory: stateDirectory,
            minimumFreeBytes: minimumFreeBytes,
            availableBytes: availableBytes,
            recovery: recovery,
            processor: processor,
            listenerFactory: { listener },
            sleepSeconds: sleepSeconds,
            retryJitterSeconds: retryJitterSeconds,
            diagnosticSink: diagnosticSink
        )
    }

    public func start() async throws {
        try await observePersistedPause()
        guard state != .paused else { throw BridgeSupervisorError.paused }
        guard state != .shutdownBlocked else { throw BridgeSupervisorError.invalidConfiguration }
        guard state != .running else { throw BridgeSupervisorError.alreadyRunning }
        guard availableBytes() >= minimumFreeBytes else { throw BridgeSupervisorError.diskPressure }

        try lease.acquire()
        ownedRuntimeNeedsStop = true
        diagnosticSink(.serviceStarting)
        do {
            try clearReadiness()
            try await recovery.recoverIntake()
            try await processor.recoverPendingMemos()
            let listener = try listenerFactory()
            self.listener = listener
            try await listener.start()
            try persistReadiness()
            state = .running
            retryBackoffBaseSeconds = nil
            retryDelaySeconds = nil
            startPauseObserver()
            diagnosticSink(.serviceRunning)
        } catch {
            await stopOwnedRuntime()
            state = ownedChildren.isEmpty ? .retryWaiting : .shutdownBlocked
            diagnosticSink(.serviceFailed)
            if ownedChildren.isEmpty {
                scheduleNextBackoff()
            }
            throw BridgeSupervisorError.listenerFailed
        }
    }

    public func retry() async throws {
        guard state != .paused else { throw BridgeSupervisorError.paused }
        try await start()
    }

    /// Startup failures remain supervised instead of terminating the daemon.
    /// The one-second slices make an externally persisted pause interrupt a
    /// bounded backoff promptly and are injectable for deterministic tests.
    public func runWithReconnect() async throws {
        shutdownRequested = false
        while !shutdownRequested {
            if try await enterPersistedPauseIfRequested() {
                await sleepSeconds(1)
                continue
            }
            if state == .paused { state = .stopped }
            do {
                try await start()
                guard let listener else { throw BridgeSupervisorError.listenerFailed }
                do {
                    try await listener.waitUntilStopped()
                } catch {
                    // A listener that fails after becoming ready is a runtime
                    // failure and must enter the same supervised reconnect path.
                    diagnosticSink(.serviceFailed)
                }
                if shutdownRequested { return }
                if try Self.loadPausedState(at: pauseURL) { continue }
                await stopOwnedRuntime()
                if !ownedChildren.isEmpty {
                    state = .shutdownBlocked
                    return
                }
                state = .retryWaiting
                scheduleNextBackoff()
            } catch BridgeSupervisorError.listenerFailed {
                // start() already records the bounded backoff.
            } catch BridgeSupervisorError.paused {
                continue
            }
            if try await enterPersistedPauseIfRequested() { continue }
            let delay = retryDelaySeconds ?? 1
            for _ in 0 ..< delay where !shutdownRequested {
                await sleepSeconds(1)
                if try Self.loadPausedState(at: pauseURL) { break }
            }
        }
    }

    public func pause() async throws {
        try persistPaused(true)
        await transitionToPaused()
    }

    public func resume() async throws {
        await stopOwnedRuntime()
        guard ownedChildren.isEmpty else {
            state = .shutdownBlocked
            return
        }
        try persistPaused(false)
        state = .stopped
        retryBackoffBaseSeconds = nil
        retryDelaySeconds = nil
    }

    public func shutdown() async {
        shutdownRequested = true
        await stopOwnedRuntime()
        guard ownedChildren.isEmpty else {
            state = .shutdownBlocked
            retryBackoffBaseSeconds = nil
            retryDelaySeconds = nil
            return
        }
        state = .stopped
        retryBackoffBaseSeconds = nil
        retryDelaySeconds = nil
        diagnosticSink(.serviceStopped)
    }

    public func registerOwnedChild(_ child: any BridgeOwnedChild) throws {
        guard state == .running else { throw BridgeSupervisorError.invalidConfiguration }
        let identity = ObjectIdentifier(child)
        ownedChildren[identity] = child
        ownedChildStopFailures.removeValue(forKey: identity)
    }

    public func status() -> BridgeSupervisorStatus {
        BridgeSupervisorStatus(
            state: state,
            nextRetryDelaySeconds: retryDelaySeconds,
            ownedChildCount: ownedChildren.count,
            ownedChildStopFailures: ownedChildStopFailures.values.sorted {
                ($0.pid, $0.killResult) < ($1.pid, $1.killResult)
            }
        )
    }

    public static func persistedStatus(stateDirectory: URL) throws -> BridgeSupervisorStatus {
        let pauseURL = stateDirectory.standardizedFileURL.appendingPathComponent("pause-state.json")
        return BridgeSupervisorStatus(
            state: try loadPausedState(at: pauseURL) ? .paused : (BridgeServiceLease.isLive(stateDirectory: stateDirectory) ? .running : .stopped),
            nextRetryDelaySeconds: nil,
            ownedChildCount: 0,
            ownedChildStopFailures: []
        )
    }

    public static func setPersistedPause(_ paused: Bool, stateDirectory: URL) throws {
        let directory = stateDirectory.standardizedFileURL
        try prepareStateDirectory(directory)
        let pauseURL = directory.appendingPathComponent("pause-state.json")
        do {
            try JSONEncoder().encode(PersistedState(paused: paused)).write(to: pauseURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: pauseURL.path
            )
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }

    public static func isReady(stateDirectory: URL) -> Bool {
        let directory = stateDirectory.standardizedFileURL
        let marker = directory.appendingPathComponent("service.ready")
        var metadata = stat()
        guard lstat(marker.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600,
              BridgeServiceLease.isLive(stateDirectory: directory),
              let data = try? Data(contentsOf: marker),
              let readiness = try? JSONDecoder().decode(ReadinessState.self, from: data),
              readiness.pid > 0,
              kill(readiness.pid, 0) == 0 || errno == EPERM,
              BridgeServiceLease.persistedGeneration(stateDirectory: directory)
                == readiness.generation
        else { return false }
        return true
    }

    private func stopOwnedRuntime() async {
        // The first caller drains inline. Actor-reentrant lifecycle callers
        // join this generation instead of mistaking a claimed drain for a
        // completed one or creating a Task that could await itself.
        if ownedRuntimeDrain != nil {
            await withCheckedContinuation { continuation in
                guard var drain = ownedRuntimeDrain else {
                    continuation.resume()
                    return
                }
                drain.waiters.append(continuation)
                ownedRuntimeDrain = drain
            }
            return
        }
        guard ownedRuntimeNeedsStop else { return }
        ownedRuntimeNeedsStop = false
        ownedRuntimeDrainGeneration &+= 1
        let generation = ownedRuntimeDrainGeneration
        ownedRuntimeDrain = OwnedRuntimeDrain(generation: generation)
        try? clearReadiness()
        stopPauseObserver()
        let currentListener = listener
        listener = nil
        let children = Array(ownedChildren.values)
        ownedChildren.removeAll()
        await currentListener?.stop()
        if let stoppableProcessor = processor as? any BridgePendingMemoStopping {
            await stoppableProcessor.stopPendingMemos()
        }
        var stillRunningChildren: [any BridgeOwnedChild] = []
        for child in children {
            let identity = ObjectIdentifier(child)
            switch await child.stop() {
            case .stopped:
                ownedChildStopFailures.removeValue(forKey: identity)
            case let .stillRunning(pid, killResult):
                stillRunningChildren.append(child)
                ownedChildStopFailures[identity] = BridgeOwnedChildStopFailure(
                    pid: pid,
                    killResult: killResult
                )
            }
        }
        for child in stillRunningChildren {
            ownedChildren[ObjectIdentifier(child)] = child
        }
        if !stillRunningChildren.isEmpty {
            ownedRuntimeNeedsStop = true
        } else {
            lease.release()
        }
        // Keep the generation visible through the last owned-resource await
        // and lease release; only completed drains may release joiners.
        finishOwnedRuntimeDrain(generation: generation)
    }

    private func finishOwnedRuntimeDrain(generation: UInt64) {
        guard let drain = ownedRuntimeDrain,
              drain.generation == generation
        else { return }
        ownedRuntimeDrain = nil
        for continuation in drain.waiters { continuation.resume() }
    }

    private func persistPaused(_ paused: Bool) throws {
        do {
            let data = try JSONEncoder().encode(PersistedState(paused: paused))
            try data.write(to: pauseURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: pauseURL.path
            )
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }

    private func persistReadiness() throws {
        guard let generation = lease.generation else {
            throw BridgeSupervisorError.statePersistenceFailed
        }
        let temporary = readinessURL.deletingLastPathComponent().appending(
            path: ".service.ready.staged-\(UUID().uuidString)"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw BridgeSupervisorError.statePersistenceFailed }
        var published = false
        defer {
            close(descriptor)
            if !published { try? FileManager.default.removeItem(at: temporary) }
        }
        do {
            let data = try JSONEncoder().encode(ReadinessState(
                pid: getpid(), generation: generation
            ))
            let wrote = data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return data.isEmpty }
                return Darwin.write(descriptor, base, raw.count) == raw.count
            }
            guard wrote,
                  fchmod(descriptor, 0o600) == 0,
                  fsync(descriptor) == 0,
                  Darwin.rename(temporary.path, readinessURL.path) == 0
            else { throw BridgeSupervisorError.statePersistenceFailed }
            published = true
        } catch let error as BridgeSupervisorError {
            throw error
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }

    private func clearReadiness() throws {
        var metadata = stat()
        guard lstat(readinessURL.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw BridgeSupervisorError.statePersistenceFailed
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1
        else { throw BridgeSupervisorError.statePersistenceFailed }
        do { try FileManager.default.removeItem(at: readinessURL) }
        catch { throw BridgeSupervisorError.statePersistenceFailed }
    }

    private func observePersistedPause() async throws {
        guard try await enterPersistedPauseIfRequested() else { return }
        throw BridgeSupervisorError.paused
    }

    private func enterPersistedPauseIfRequested() async throws -> Bool {
        guard try Self.loadPausedState(at: pauseURL) else { return false }
        await transitionToPaused()
        // A shutdown may join the same in-flight drain while this pause path
        // is suspended. Shutdown is terminal for this run and must win when
        // both callers resume from the shared drain.
        guard !shutdownRequested else {
            state = ownedChildren.isEmpty ? .stopped : .shutdownBlocked
            retryBackoffBaseSeconds = nil
            retryDelaySeconds = nil
            return true
        }
        return true
    }

    private func transitionToPaused() async {
        await stopOwnedRuntime()
        guard ownedChildren.isEmpty else {
            state = .shutdownBlocked
            return
        }
        guard state != .paused, !shutdownRequested else { return }
        state = .paused
        retryBackoffBaseSeconds = nil
        retryDelaySeconds = nil
        diagnosticSink(.servicePaused)
    }

    private func startPauseObserver() {
        stopPauseObserver()
        pauseObserverGeneration &+= 1
        let generation = pauseObserverGeneration
        pauseObserverScheduler.start { [weak self] in
            Task { await self?.observePauseTick(generation: generation) }
        }
    }

    private func stopPauseObserver() {
        pauseObserverGeneration &+= 1
        pauseObserverScheduler.stop()
    }

    private func observePauseTick(generation: UInt64) async {
        guard generation == pauseObserverGeneration,
              state == .running,
              !pauseObserverPollInFlight
        else { return }
        pauseObserverPollInFlight = true
        defer { pauseObserverPollInFlight = false }
        do {
            try await observePersistedPause()
        } catch BridgeSupervisorError.paused {
            return
        } catch {
            // A corrupt control file fails closed on the next explicit
            // lifecycle command; do not keep an uncontrolled observer.
            await shutdown()
        }
    }

    private static func nextBackoff(after current: Int?) -> Int {
        let current = current ?? 0
        return min(max(1, current * 2), 60)
    }

    private func scheduleNextBackoff() {
        let base = Self.nextBackoff(after: retryBackoffBaseSeconds)
        retryBackoffBaseSeconds = base
        let jitter = min(15, max(0, retryJitterSeconds(base)))
        retryDelaySeconds = min(60, base + jitter)
        diagnosticSink(.retryScheduled)
    }

    private static func prepareStateDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }

    private static func loadPausedState(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url)).paused
        } catch {
            throw BridgeSupervisorError.statePersistenceFailed
        }
    }
}

public struct IntakeStoreRecovery: BridgeIntakeRecovering {
    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func recoverIntake() async throws {
        _ = try IntakeStore(rootURL: rootURL)
    }
}

public struct NoPendingMemoRecovery: BridgePendingMemoProcessing {
    public init() {}
    public func recoverPendingMemos() async throws {}
}

public struct IntakeStorePendingMemoProcessor: BridgePendingMemoProcessing {
    private let intakeStore: IntakeStore
    private let processor: any BridgeMemoProcessing
    private let maximumRecords: Int

    public init(
        intakeStore: IntakeStore,
        processor: any BridgeMemoProcessing,
        maximumRecords: Int = 256
    ) {
        self.intakeStore = intakeStore
        self.processor = processor
        self.maximumRecords = maximumRecords
    }

    public func recoverPendingMemos() async throws {
        let records = try await intakeStore.committedRecords(maximumEntries: maximumRecords)
        for record in records {
            _ = try await processor.process(.init(
                memoID: record.memoID,
                capturedAt: record.receipt.capturedAt,
                localeHint: record.receipt.localeHint,
                committedAudio: record.committedAudio
            ))
        }
    }
}

public struct BoundedIntakeProcessorStatus: Equatable, Sendable {
    public let queuedRecordCount: Int
    public let rescanNeeded: Bool
    public let running: Bool
}

/// Processes only durable intake records. The bounded in-memory queue is an
/// optimization, never the source of truth: if it fills, the actor records a
/// rescan requirement and revisits the intake journal after capacity frees.
public actor BoundedIntakeMemoProcessor: BridgePendingMemoProcessing, BridgePendingMemoStopping {
    private let intakeStore: any BridgeIntakeRecordSource
    private let processor: any BridgeMemoProcessing
    private let onDelivered: @Sendable (MemoID) async throws -> Void
    private let sample: @Sendable () -> Double
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let retryBackoff: FullJitterBackoff
    private let maximumQueuedRecords: Int
    private var queuedIDs: [MemoID] = []
    private var queuedIDSet: Set<MemoID> = []
    private var processedThisRun: Set<MemoID> = []
    private var publishedThisRun: Set<MemoID> = []
    private var rescanNeeded = false
    private var scanCursor: MemoID?
    private var scanEpoch: UInt64 = 0
    private var accepting = false
    private var workerTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var mailboxTask: Task<Void, Never>?
    private var retryableIDs: Set<MemoID> = []
    private var retryAttempt: UInt64 = 0
    private let retryMailbox: OperatorRetryMailbox?

    public init(
        intakeStore: any BridgeIntakeRecordSource,
        processor: any BridgeMemoProcessing,
        maximumQueuedRecords: Int = 128,
        sample: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        retryMailbox: OperatorRetryMailbox? = nil,
        onDelivered: @escaping @Sendable (MemoID) async throws -> Void = { _ in }
    ) {
        self.intakeStore = intakeStore
        self.processor = processor
        self.sample = sample
        self.sleep = sleep
        self.retryMailbox = retryMailbox
        do {
            retryBackoff = try FullJitterBackoff(baseDelay: 5, maximumDelay: 900)
        } catch {
            preconditionFailure("Fixed delivery retry bounds must be valid")
        }
        self.onDelivered = onDelivered
        self.maximumQueuedRecords = max(1, maximumQueuedRecords)
    }

    public func recoverPendingMemos() async throws {
        accepting = true
        processedThisRun.removeAll()
        publishedThisRun.removeAll()
        // Fresh recovery run; do not inherit a prior episode's backoff.
        retryAttempt = 0
        scanCursor = nil
        scanEpoch &+= 1
        await drainRetryMailbox()
        try await refillFromDurableIntake()
        scheduleMailboxPollIfNeeded()
        scheduleWorkerIfNeeded()
    }

    /// Called only after intake commit. This method is intentionally small and
    /// returns before transcription or App Server delivery begin.
    public func admit(_ record: CommittedIntakeRecord) {
        guard accepting else {
            // The record is already durable and will be found at next start.
            rescanNeeded = true
            return
        }
        enqueue(record.memoID)
        scheduleWorkerIfNeeded()
    }

    public func stopPendingMemos() async {
        accepting = false
        let worker = workerTask
        let retry = retryTask
        let mailbox = mailboxTask
        worker?.cancel()
        retry?.cancel()
        mailbox?.cancel()
        await worker?.value
        await retry?.value
        await mailbox?.value
        workerTask = nil
        retryTask = nil
        mailboxTask = nil
        queuedIDs.removeAll()
        queuedIDSet.removeAll()
        retryableIDs.removeAll()
        // Stop ends the retry episode; a later recover must start at attempt 0.
        retryAttempt = 0
        scanCursor = nil
        scanEpoch &+= 1
        // Cancellation cannot lose a committed record; require recovery even
        // if cancellation raced a dequeue.
        rescanNeeded = true
    }

    public func stop() async {
        await stopPendingMemos()
    }

    public func retry(_ memoID: MemoID) async throws {
        guard accepting else { throw BridgeSupervisorError.invalidConfiguration }
        try await retryCommitted(memoID)
    }

    /// Operator retry deliberately bypasses generic recovery: it touches one
    /// durable memo and only after the delivery journal accepts its unresolved
    /// transition.
    public func retryCommitted(_ memoID: MemoID) async throws {
        guard let record = try await intakeStore.committedRecord(for: memoID),
              let retrying = processor as? any BridgeMemoRetrying
        else { throw BridgeSupervisorError.invalidConfiguration }
        let outcome = try await retrying.retry(.init(
            memoID: memoID,
            capturedAt: record.receipt.capturedAt,
            localeHint: record.receipt.localeHint,
            committedAudio: record.committedAudio
        ))
        try await handle(outcome, for: memoID)
    }

    public func status() -> BoundedIntakeProcessorStatus {
        BoundedIntakeProcessorStatus(
            queuedRecordCount: queuedIDs.count,
            rescanNeeded: rescanNeeded,
            running: workerTask != nil || retryTask != nil
        )
    }

    private func enqueue(_ memoID: MemoID) {
        guard !processedThisRun.contains(memoID), !queuedIDSet.contains(memoID) else { return }
        guard queuedIDs.count < maximumQueuedRecords else {
            // A live memo may sort before the current durable page cursor.
            // Restart the scan so overflow cannot strand it until restart.
            scanCursor = nil
            scanEpoch &+= 1
            rescanNeeded = true
            return
        }
        queuedIDs.append(memoID)
        queuedIDSet.insert(memoID)
    }

    private func refillFromDurableIntake() async throws {
        let requestedCursor = scanCursor
        let requestedEpoch = scanEpoch
        let page = try await intakeStore.committedRecordPage(
            maximumEntries: maximumQueuedRecords,
            afterMemoID: requestedCursor
        )
        guard accepting,
              requestedEpoch == scanEpoch,
              requestedCursor == scanCursor
        else {
            rescanNeeded = true
            return
        }
        for record in page.records {
            enqueue(record.memoID)
        }
        guard requestedEpoch == scanEpoch else { return }
        scanCursor = page.records.last?.memoID ?? scanCursor
        rescanNeeded = page.hasMore
    }

    private func scheduleWorkerIfNeeded() {
        guard accepting, workerTask == nil, !queuedIDs.isEmpty || rescanNeeded else { return }
        workerTask = Task { [weak self] in
            await self?.runWorker()
        }
    }

    private func runWorker() async {
        defer {
            workerTask = nil
            scheduleWorkerIfNeeded()
        }

        while accepting, !Task.isCancelled {
            if queuedIDs.isEmpty, rescanNeeded {
                rescanNeeded = false
                do {
                    try await refillFromDurableIntake()
                } catch {
                    rescanNeeded = true
                    return
                }
            }
            guard !queuedIDs.isEmpty else { return }
            let memoID = queuedIDs.removeFirst()
            queuedIDSet.remove(memoID)
            do {
                guard let record = try await intakeStore.committedRecord(for: memoID) else {
                    continue
                }
                let outcome = try await processor.process(.init(
                    memoID: record.memoID,
                    capturedAt: record.receipt.capturedAt,
                    localeHint: record.receipt.localeHint,
                    committedAudio: record.committedAudio
                ))
                try await handle(outcome, for: memoID)
            } catch is CancellationError {
                rescanNeeded = true
                return
            } catch {
                // The delivery journal and durable intake own retry truth. Do
                // not spin an unavailable dependency in the listener task.
                rescanNeeded = true
                return
            }
        }
        rescanNeeded = true
    }

    private func handle(_ outcome: MemoProcessingOutcome, for memoID: MemoID) async throws {
        // Mark before publishing so actor reentrancy cannot publish the same
        // terminal completion more than once in this processing run.
        processedThisRun.insert(memoID)
        switch outcome {
        case .delivered:
            retryableIDs.remove(memoID)
            resetRetryAttemptIfEpisodeEnded()
            guard publishedThisRun.insert(memoID).inserted else { return }
            do {
                try await onDelivered(memoID)
            } catch {
                // Publication did not complete, so release both in-memory
                // claims. Reprocessing a durably delivered memo is safe and
                // must be allowed to retry the idempotent publisher.
                publishedThisRun.remove(memoID)
                processedThisRun.remove(memoID)
                throw error
            }
        case .retryable:
            retryableIDs.insert(memoID)
            scheduleRetryIfNeeded()
        case .needsAttention:
            retryableIDs.remove(memoID)
            resetRetryAttemptIfEpisodeEnded()
        }
    }

    private func scheduleRetryIfNeeded() {
        guard accepting, retryTask == nil, !retryableIDs.isEmpty else { return }
        let delay = retryBackoff.delay(afterAttempt: retryAttempt, sample: sample())
        if retryAttempt < UInt64.max { retryAttempt += 1 }
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.retryDelayElapsed()
        }
    }

    private func retryDelayElapsed() {
        retryTask = nil
        guard accepting else { return }
        guard !retryableIDs.isEmpty else {
            resetRetryAttemptIfEpisodeEnded()
            return
        }
        for memoID in retryableIDs {
            processedThisRun.remove(memoID)
        }
        scanCursor = nil
        scanEpoch &+= 1
        rescanNeeded = true
        scheduleWorkerIfNeeded()
    }

    private func resetRetryAttemptIfEpisodeEnded() {
        guard retryableIDs.isEmpty, retryTask == nil else { return }
        retryAttempt = 0
    }

    private func scheduleMailboxPollIfNeeded() {
        guard retryMailbox != nil, accepting, mailboxTask == nil else { return }
        mailboxTask = Task { [weak self] in
            await self?.runMailboxPoll()
        }
    }

    private func runMailboxPoll() async {
        defer { mailboxTask = nil }
        while accepting, !Task.isCancelled {
            await drainRetryMailbox()
            guard accepting, !Task.isCancelled else { return }
            await sleep(1)
        }
    }

    private func drainRetryMailbox() async {
        guard accepting, let retryMailbox else { return }
        let ids: [MemoID]
        do {
            ids = try retryMailbox.takeAll()
        } catch {
            return
        }
        for memoID in ids {
            do {
                try await retryCommitted(memoID)
            } catch {
                try? retryMailbox.enqueue(memoID)
            }
        }
    }
}

public final class NetworkBridgeListenerController: BridgeListenerControlling, @unchecked Sendable {
    private let listener: NetworkBridgeListener

    public init(listener: NetworkBridgeListener) {
        self.listener = listener
    }

    public func start() async throws {
        _ = try await listener.start()
    }

    public func waitUntilStopped() async throws {
        try await listener.waitUntilStopped()
    }

    public func stop() async {
        await listener.stop()
    }
}

public enum KeychainSecretStoreError: Error, Equatable, Sendable {
    case unavailable
}

public actor KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "ai.rsitech.codexwatch.bridge") {
        self.service = service
    }

    public func readSecret(named name: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: name,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainSecretStoreError.unavailable
        }
        return data
    }

    public func writeSecret(_ data: Data, named name: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: name,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainSecretStoreError.unavailable }
        var inserted = query
        inserted[kSecValueData] = data
        inserted[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(inserted as CFDictionary, nil) == errSecSuccess else {
            throw KeychainSecretStoreError.unavailable
        }
    }

    public func removeSecret(named name: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: name,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unavailable
        }
    }
}

public enum PKCS12TLSIdentityProviderError: Error, Equatable, Sendable {
    case invalidIdentity
}

public enum SecureLocalFileError: Error, Equatable, Sendable {
    case invalidFile
    case unreadable
}

/// Reads runtime secrets through an already-open, owner-only regular file.
/// This rejects symlinks and group/world-readable files before Keychain or TLS
/// import sees any untrusted bytes.
public enum SecureLocalFile {
    public static func readPrivateData(at url: URL, maximumBytes: Int = 8 * 1_024 * 1_024) throws -> Data {
        guard maximumBytes > 0 else { throw SecureLocalFileError.invalidFile }
        var initial = stat()
        guard lstat(url.path, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_uid == getuid(),
              (initial.st_mode & 0o077) == 0,
              initial.st_size >= 0,
              initial.st_size <= off_t(maximumBytes)
        else { throw SecureLocalFileError.invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SecureLocalFileError.unreadable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == initial.st_dev,
              opened.st_ino == initial.st_ino,
              opened.st_uid == getuid(),
              (opened.st_mode & S_IFMT) == S_IFREG,
              (opened.st_mode & 0o077) == 0,
              opened.st_size <= off_t(maximumBytes)
        else { throw SecureLocalFileError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd(), data.count <= maximumBytes else {
            throw SecureLocalFileError.unreadable
        }
        return data
    }

    public static func readUTF8PrivateFile(at url: URL, maximumBytes: Int = 16 * 1_024) throws -> String {
        let data = try readPrivateData(at: url, maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecureLocalFileError.invalidFile
        }
        return value
    }
}

public struct PKCS12TLSIdentityProvider: BridgeTLSIdentityProvider {
    private static let memoryOnlyImportLock = NSLock()
    private let p12URL: URL
    private let password: String

    public init(p12URL: URL, password: String) {
        self.p12URL = p12URL.standardizedFileURL
        self.password = password
    }

    static func importOptions(password: String) -> [String: Any] {
        [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: kCFBooleanTrue as Any,
        ]
    }

    static func extractIdentity(from imported: CFArray?) throws -> SecIdentity {
        guard let imported,
              CFArrayGetCount(imported) > 0,
              let rawItem = CFArrayGetValueAtIndex(imported, 0)
        else { throw PKCS12TLSIdentityProviderError.invalidIdentity }
        let itemValue = unsafeBitCast(rawItem, to: CFTypeRef.self)
        guard CFGetTypeID(itemValue) == CFDictionaryGetTypeID() else {
            throw PKCS12TLSIdentityProviderError.invalidIdentity
        }
        let item = unsafeBitCast(rawItem, to: CFDictionary.self)
        let identityKey = Unmanaged.passUnretained(kSecImportItemIdentity).toOpaque()
        guard let rawIdentity = CFDictionaryGetValue(item, identityKey) else {
            throw PKCS12TLSIdentityProviderError.invalidIdentity
        }
        let identityValue = unsafeBitCast(rawIdentity, to: CFTypeRef.self)
        guard CFGetTypeID(identityValue) == SecIdentityGetTypeID() else {
            throw PKCS12TLSIdentityProviderError.invalidIdentity
        }
        return unsafeBitCast(rawIdentity, to: SecIdentity.self)
    }

    static func importMemoryOnlyIdentity(data: Data, password: String) throws -> SecIdentity {
        try memoryOnlyImportLock.withLock {
            var imported: CFArray?
            guard SecPKCS12Import(
                data as CFData,
                importOptions(password: password) as CFDictionary,
                &imported
            ) == errSecSuccess else { throw PKCS12TLSIdentityProviderError.invalidIdentity }
            return try extractIdentity(from: imported)
        }
    }

    public func loadIdentity() throws -> BridgeTLSIdentity {
        let data: Data
        do {
            data = try SecureLocalFile.readPrivateData(at: p12URL)
        } catch {
            throw PKCS12TLSIdentityProviderError.invalidIdentity
        }
        let identity = try Self.importMemoryOnlyIdentity(data: data, password: password)

        do { return try BridgeTLSIdentity(secIdentity: identity) }
        catch { throw PKCS12TLSIdentityProviderError.invalidIdentity }
    }
}
