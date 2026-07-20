import Foundation

public enum StdioProcessTransportShutdownError: Error, Equatable, Sendable {
    case stillRunning(pid: pid_t, killResult: Int32)
}

public actor StdioProcessTransport: AppServerTransport {
    private struct CloseAttempt {
        let generation: UInt64
        var waiters: [CheckedContinuation<OwnedChildShutdownOutcome, Never>] = []
    }

    private enum StateError: Error {
        case alreadyConnected
        case notConnected
    }

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectory: URL?
    private let processFactory: @Sendable () -> Process
    private let shutdown: OwnedChildShutdown
    private let frameEmitter: NewlineFrameEmitter

    public nonisolated let frameStream: AsyncThrowingStream<Data, Error>
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var didConnect = false
    private var isConnected = false
    private var closeAttempt: CloseAttempt?
    private var closeGeneration: UInt64 = 0

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        processFactory: @escaping @Sendable () -> Process = Process.init,
        shutdown: OwnedChildShutdown = OwnedChildShutdown(),
        onFrameStreamFinish: @escaping @Sendable () -> Void = {}
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.processFactory = processFactory
        self.shutdown = shutdown

        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        frameStream = frames.stream
        frameEmitter = NewlineFrameEmitter(
            continuation: frames.continuation,
            onFinish: onFrameStreamFinish
        )
    }

    public func connect() async throws {
        guard !didConnect else {
            throw StateError.alreadyConnected
        }
        didConnect = true

        let child = processFactory()
        let input = Pipe()
        let output = Pipe()

        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        if !environment.isEmpty {
            child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, supplied in supplied }
        }
        child.currentDirectoryURL = currentDirectory
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.standardError

        output.fileHandleForReading.readabilityHandler = { [frameEmitter] handle in
            frameEmitter.receive(handle.availableData)
        }

        process = child
        stdinPipe = input
        stdoutPipe = output

        do {
            try child.run()
            isConnected = true
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            frameEmitter.finish(throwing: error)
            throw error
        }
    }

    public func send(_ frame: Data) async throws {
        guard isConnected, let input = stdinPipe else {
            throw StateError.notConnected
        }

        var line = frame
        if line.last != 0x0A {
            line.append(0x0A)
        }
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        frameStream
    }

    public func close() async {
        _ = await closeWithOutcome()
    }

    public func closeWithOutcome() async -> OwnedChildShutdownOutcome {
        guard didConnect else {
            frameEmitter.finish()
            return .alreadyExited
        }
        if closeAttempt != nil {
            return await withCheckedContinuation { continuation in
                guard var attempt = closeAttempt else {
                    continuation.resume(returning: .alreadyExited)
                    return
                }
                attempt.waiters.append(continuation)
                closeAttempt = attempt
            }
        }

        isConnected = false
        let ownedProcess = process
        let ownedStdin = stdinPipe?.fileHandleForWriting
        let ownedStdout = stdoutPipe?.fileHandleForReading
        ownedStdout?.readabilityHandler = nil

        guard let ownedProcess else {
            try? ownedStdin?.close()
            process = nil
            stdinPipe = nil
            stdoutPipe = nil
            try? ownedStdout?.close()
            frameEmitter.finish()
            return .alreadyExited
        }

        let capturedPID = ownedProcess.processIdentifier
        closeGeneration &+= 1
        let generation = closeGeneration
        closeAttempt = CloseAttempt(generation: generation)
        let outcome = await shutdown.stop(process: ownedProcess, stdin: ownedStdin)

        if let attempt = closeAttempt, attempt.generation == generation {
            closeAttempt = nil
            switch outcome {
            case .alreadyExited, .graceful, .terminated, .killed:
                if process === ownedProcess,
                   ownedProcess.processIdentifier == capturedPID
                {
                    process = nil
                    stdinPipe = nil
                    stdoutPipe = nil
                }
                try? ownedStdout?.close()
                frameEmitter.finish()
            case let .stillRunning(pid, killResult):
                frameEmitter.finish(throwing: StdioProcessTransportShutdownError.stillRunning(
                    pid: pid,
                    killResult: killResult
                ))
            }
            for continuation in attempt.waiters {
                continuation.resume(returning: outcome)
            }
        }
        return outcome
    }
}

private final class NewlineFrameEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let onFinish: @Sendable () -> Void
    private var buffer = Data()
    private var isFinished = false

    init(
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func receive(_ data: Data) {
        var frames: [Data] = []
        var reachedEnd = false

        lock.lock()
        if !isFinished {
            if data.isEmpty {
                buffer.removeAll()
                isFinished = true
                reachedEnd = true
            } else {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if isNonEmptyFrame(line) {
                        frames.append(trimCarriageReturn(line))
                    }
                }
            }
        }
        lock.unlock()

        for frame in frames {
            continuation.yield(frame)
        }
        if reachedEnd {
            continuation.finish()
            onFinish()
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        buffer.removeAll()
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        onFinish()
    }

    private func isNonEmptyFrame(_ data: Data) -> Bool {
        data.contains { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0D
        }
    }

    private func trimCarriageReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}
