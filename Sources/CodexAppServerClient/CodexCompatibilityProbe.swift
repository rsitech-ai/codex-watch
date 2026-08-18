import CodexAppServerProtocol
import Foundation

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
    func version(
        executable: ValidatedCodexExecutable,
        environment: [String: String],
        cwd: URL
    ) async throws -> String
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

public typealias CompatibilitySessionFactory = @Sendable (
    ValidatedCodexExecutable,
    [String],
    [String: String],
    URL
) -> any CodexCompatibilitySession

public struct CodexCompatibilityProbe: Sendable {
    private static let clientVersion = "0.1.0"

    private let executable: ValidatedCodexExecutable
    private let workspace: IsolatedCodexWorkspace
    private let versionRunner: any CodexVersionRunning
    private let sessionFactory: CompatibilitySessionFactory
    private let timeout: Duration

    public init(
        executable: ValidatedCodexExecutable,
        workspace: IsolatedCodexWorkspace,
        versionRunner: any CodexVersionRunning = ProcessCodexVersionRunner(),
        sessionFactory: @escaping CompatibilitySessionFactory = Self.productionSession,
        timeout: Duration = .seconds(20)
    ) {
        self.executable = executable
        self.workspace = workspace
        self.versionRunner = versionRunner
        self.sessionFactory = sessionFactory
        self.timeout = timeout
    }

    public func run() async -> CodexCompatibilityResult {
        let environment = [
            "CODEX_HOME": workspace.codexHome.path,
            "HOME": workspace.codexHome.path,
        ]
        let session = sessionFactory(
            executable,
            ["app-server"],
            environment,
            workspace.neutralDirectory
        )

        let operationResult = await raceAgainstTimeout(session: session, environment: environment)
        let shutdown = await session.closeAndAwaitOwnedChild()
        guard shutdown == .ownedChildExited else {
            return .failed(version: operationResult.version, reason: .shutdownFailed)
        }
        return operationResult.result
    }

    private func raceAgainstTimeout(
        session: any CodexCompatibilitySession,
        environment: [String: String]
    ) async -> OperationOutcome {
        if Task.isCancelled {
            return OperationOutcome(version: nil, result: .failed(version: nil, reason: .cancelled))
        }

        return await withTaskGroup(of: OperationOutcome.self) { group in
            group.addTask {
                await perform(session: session, environment: environment)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return OperationOutcome(version: nil, result: .failed(version: nil, reason: .timedOut))
                } catch {
                    return OperationOutcome(version: nil, result: .failed(version: nil, reason: .cancelled))
                }
            }
            let first = await group.next() ?? OperationOutcome(
                version: nil,
                result: .failed(version: nil, reason: .cancelled)
            )
            group.cancelAll()
            return first
        }
    }

    private func perform(
        session: any CodexCompatibilitySession,
        environment: [String: String]
    ) async -> OperationOutcome {
        let version: String
        do {
            version = try await versionRunner.version(
                executable: executable,
                environment: environment,
                cwd: workspace.neutralDirectory
            )
        } catch is CancellationError {
            return OperationOutcome(version: nil, result: .failed(version: nil, reason: .cancelled))
        } catch {
            return OperationOutcome(version: nil, result: .failed(version: nil, reason: .versionUnavailable))
        }

        do {
            try await session.initialize(
                clientName: "codex-watch-compatibility-smoke",
                title: "Codex Watch Compatibility Smoke",
                version: Self.clientVersion
            )
        } catch is CancellationError {
            return OperationOutcome(version: version, result: .failed(version: version, reason: .cancelled))
        } catch {
            return OperationOutcome(version: version, result: .failed(version: version, reason: .initializationFailed))
        }

        let response: JSONValue
        do {
            response = try await session.call(.threadList)
        } catch is CancellationError {
            return OperationOutcome(version: version, result: .failed(version: version, reason: .cancelled))
        } catch {
            return OperationOutcome(version: version, result: .failed(version: version, reason: .threadListFailed))
        }

        guard Self.isValidThreadListResponse(response) else {
            return OperationOutcome(version: version, result: .failed(
                version: version,
                reason: .invalidThreadListResponse
            ))
        }
        return OperationOutcome(version: version, result: .passed(version: version))
    }

    private static func isValidThreadListResponse(_ response: JSONValue) -> Bool {
        guard case let .object(object) = response,
              case .array? = object["data"]
        else { return false }
        guard let cursor = object["nextCursor"] else { return true }
        switch cursor {
        case .null, .string:
            return true
        default:
            return false
        }
    }

    public static func productionSession(
        executable: ValidatedCodexExecutable,
        arguments: [String],
        environment: [String: String],
        cwd: URL
    ) -> any CodexCompatibilitySession {
        let transport = StdioProcessTransport(
            executable: executable.url.path,
            arguments: arguments,
            environment: environment,
            inheritEnvironment: false,
            currentDirectory: cwd
        )
        return OwnedCodexCompatibilitySession(
            client: AppServerClient(transport: transport),
            transport: transport
        )
    }
}

private struct OperationOutcome: Sendable {
    let version: String?
    let result: CodexCompatibilityResult
}

public actor OwnedCodexCompatibilitySession: CodexCompatibilitySession {
    private let client: AppServerClient
    private let transport: StdioProcessTransport
    private var didClose = false

    public init(client: AppServerClient, transport: StdioProcessTransport) {
        self.client = client
        self.transport = transport
    }

    public func initialize(clientName: String, title: String, version: String) async throws {
        try await client.initialize(clientName: clientName, title: title, version: version)
    }

    public func call(_ method: AppServerMethod) async throws -> JSONValue {
        try await client.call(method)
    }

    public func closeAndAwaitOwnedChild() async -> CompatibilityShutdownResult {
        guard !didClose else { return .ownedChildExited }
        didClose = true
        await client.close()
        switch await transport.closeWithOutcome() {
        case .alreadyExited, .graceful, .terminated, .killed:
            return .ownedChildExited
        case .stillRunning:
            return .stillRunning
        }
    }
}

public struct ProcessCodexVersionRunner: CodexVersionRunning {
    public init() {}

    public func version(
        executable: ValidatedCodexExecutable,
        environment: [String: String],
        cwd: URL
    ) async throws -> String {
        let process = Process()
        let output = Pipe()
        let errorPipe = Pipe()
        let stdout = CompatibilityProcessOutput(limit: 4_096)
        let stderr = CompatibilityProcessOutput(limit: 4_096)
        process.executableURL = executable.url
        process.arguments = ["--version"]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        output.fileHandleForReading.readabilityHandler = { handle in
            stdout.consumeAvailable(from: handle)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.consumeAvailable(from: handle)
        }

        do {
            try process.run()
        } catch {
            Self.close(output)
            Self.close(errorPipe)
            throw CodexCompatibilityFailure.versionUnavailable
        }

        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if process.isRunning {
                _ = await OwnedChildShutdown(policy: .init(
                    gracefulTimeout: .zero,
                    terminateTimeout: .milliseconds(100),
                    killTimeout: .milliseconds(100)
                )).stop(process: process, stdin: nil)
            }
            Self.close(output)
            Self.close(errorPipe)
            throw CancellationError()
        }

        try? await Task.sleep(for: .milliseconds(20))
        Self.close(output)
        Self.close(errorPipe)

        let data = stdout.data
        guard process.terminationStatus == 0,
              !stdout.exceededLimit,
              let text = String(data: data, encoding: .utf8)
        else { throw CodexCompatibilityFailure.versionUnavailable }

        let lines = text.split(whereSeparator: \Character.isNewline)
        guard lines.count == 1 else { throw CodexCompatibilityFailure.versionUnavailable }
        let line = String(lines[0])
        guard !line.isEmpty,
              line.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw CodexCompatibilityFailure.versionUnavailable }
        return line
    }

    private static func close(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private final class CompatibilityProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var overflowed = false

    init(limit: Int) {
        self.limit = limit
    }

    func consumeAvailable(from handle: FileHandle) {
        lock.withLock {
            appendWhileLocked(handle.availableData)
        }
    }

    var data: Data {
        lock.withLock { storage }
    }

    var exceededLimit: Bool {
        lock.withLock { overflowed }
    }

    private func appendWhileLocked(_ data: Data) {
        guard !data.isEmpty else { return }
        let remaining = max(0, limit - storage.count)
        if data.count > remaining {
            overflowed = true
        }
        if remaining > 0 {
            storage.append(data.prefix(remaining))
        }
    }
}
