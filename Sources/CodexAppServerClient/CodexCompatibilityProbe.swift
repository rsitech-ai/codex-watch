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
                clientName: "voice-inbox-compatibility-smoke",
                title: "Voice Inbox Compatibility Smoke",
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
        let error = Pipe()
        process.executableURL = executable.url
        process.arguments = ["--version"]
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardOutput = output
        process.standardError = error
        try process.run()

        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        _ = try? error.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              data.count <= 4096,
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
}
