import CodexAppServerClient
import Foundation
import WatchSimulatorSelection

enum WatchSimulatorSelectorExitCode: Int32, Sendable {
    case success = 0
    case noDestination = 2
    case toolFailure = 3
    case usage = 64
}

struct WatchSimulatorSelectorResult: Sendable, Equatable {
    let exitCode: WatchSimulatorSelectorExitCode
    let stdout: String
    let stderr: String
}

enum SimulatorToolRequest: CaseIterable, Hashable, Sendable {
    case activeSDK
    case runtimes
    case devices
}

enum SimulatorToolResult: Equatable, Sendable {
    case success(Data)
    case unavailable
    case timedOut
    case failed(status: Int32)
}

protocol SimulatorToolRunning: Sendable {
    func run(_ request: SimulatorToolRequest) async -> SimulatorToolResult
}

struct ProcessInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

struct XcrunSimulatorToolRunner: SimulatorToolRunning {
    private static let timeout: Duration = .seconds(10)
    private static let maximumJSONBytes = 4 * 1024 * 1024
    private static let maximumSDKBytes = 64

    static func invocation(for request: SimulatorToolRequest) -> ProcessInvocation {
        switch request {
        case .activeSDK:
            ProcessInvocation(
                executable: "/usr/bin/xcrun",
                arguments: ["--sdk", "watchsimulator", "--show-sdk-version"]
            )
        case .runtimes:
            ProcessInvocation(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "list", "runtimes", "--json"]
            )
        case .devices:
            ProcessInvocation(
                executable: "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available", "--json"]
            )
        }
    }

    func run(_ request: SimulatorToolRequest) async -> SimulatorToolResult {
        let command = Self.invocation(for: request)
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            return .unavailable
        }
        let outputLimit = request == .activeSDK
            ? Self.maximumSDKBytes
            : Self.maximumJSONBytes
        let output = BoundedOutput(limit: outputLimit)
        let stdoutPipe = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: command.executable)
        child.arguments = command.arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        do {
            try child.run()
        } catch {
            Self.close(stdoutPipe)
            return .unavailable
        }

        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        do {
            while child.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if child.isRunning { _ = await Self.shutdown(child) }
            Self.close(stdoutPipe)
            return .timedOut
        }
        guard !child.isRunning else {
            _ = await Self.shutdown(child)
            Self.close(stdoutPipe)
            return .timedOut
        }

        try? await Task.sleep(for: .milliseconds(20))
        Self.close(stdoutPipe)
        guard child.terminationReason == .exit, child.terminationStatus == 0 else {
            return .failed(status: child.terminationStatus)
        }
        guard !output.didTruncate else { return .failed(status: -1) }
        return .success(output.data)
    }

    private static func shutdown(_ process: Process) async -> OwnedChildShutdownOutcome {
        await OwnedChildShutdown(policy: .init(
            gracefulTimeout: .zero,
            terminateTimeout: .seconds(1),
            killTimeout: .seconds(1)
        )).stop(process: process, stdin: nil)
    }

    private static func close(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

enum WatchSimulatorSelectorCommand {
    static func run(
        arguments: [String],
        runner: any SimulatorToolRunning = XcrunSimulatorToolRunner()
    ) async -> WatchSimulatorSelectorResult {
        guard arguments == ["--format", "shell"] else {
            return failure(.usage, code: "USAGE")
        }

        let sdkData: Data
        switch await runner.run(.activeSDK) {
        case let .success(data): sdkData = data
        case .unavailable: return failure(.toolFailure, code: "TOOLS_UNAVAILABLE")
        case .timedOut: return failure(.toolFailure, code: "TOOL_TIMEOUT")
        case .failed: return failure(.toolFailure, code: "TOOL_FAILED")
        }
        let activeSDK = String(decoding: sdkData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeSDK.range(
            of: #"^[0-9]+\.[0-9]+$"#,
            options: .regularExpression
        ) != nil else {
            return failure(.toolFailure, code: "INVALID_SDK_VERSION")
        }

        let runtimeData: Data
        switch await runner.run(.runtimes) {
        case let .success(data): runtimeData = data
        case .unavailable: return failure(.toolFailure, code: "TOOLS_UNAVAILABLE")
        case .timedOut: return failure(.toolFailure, code: "TOOL_TIMEOUT")
        case .failed: return failure(.toolFailure, code: "TOOL_FAILED")
        }
        let deviceData: Data
        switch await runner.run(.devices) {
        case let .success(data): deviceData = data
        case .unavailable: return failure(.toolFailure, code: "TOOLS_UNAVAILABLE")
        case .timedOut: return failure(.toolFailure, code: "TOOL_TIMEOUT")
        case .failed: return failure(.toolFailure, code: "TOOL_FAILED")
        }

        do {
            let destination = try WatchSimulatorSelector.select(
                activeSDK: activeSDK,
                runtimes: SimulatorInventory.decodeRuntimes(runtimeData),
                devices: SimulatorInventory.decodeDevices(deviceData)
            )
            return try success(destination)
        } catch let error as WatchSimulatorSelectionError {
            switch error {
            case .invalidSDKVersion, .malformedInventory:
                return failure(.toolFailure, code: error.rawValue)
            case .exactRuntimeUnavailable, .noAvailableWatch,
                 .unknownDisplaySize, .contradictoryInventory:
                return failure(.noDestination, code: error.rawValue)
            }
        } catch {
            return failure(.toolFailure, code: "MALFORMED_INVENTORY")
        }
    }

    private static func success(
        _ destination: WatchSimulatorDestination
    ) throws -> WatchSimulatorSelectorResult {
        guard destination.identifier.range(
            of: #"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil,
        destination.runtimeIdentifier.range(
            of: #"^[A-Za-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
        else { throw WatchSimulatorSelectionError.malformedInventory }

        let name = sanitizeName(destination.name)
        let stdout = [
            "name=\(shellQuote(name))",
            "identifier=\(destination.identifier)",
            "runtime=\(destination.runtimeVersion)",
            "runtime_identifier=\(destination.runtimeIdentifier)",
            "display_mm=\(destination.displayMillimeters)",
            "rationale=\(destination.rationale)",
        ].joined(separator: "\n") + "\n"
        let stderr = "selected Watch simulator: \(name); watchOS \(destination.runtimeVersion); \(destination.displayMillimeters)mm; \(destination.rationale)\n"
        return WatchSimulatorSelectorResult(
            exitCode: .success,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func failure(
        _ exitCode: WatchSimulatorSelectorExitCode,
        code: String
    ) -> WatchSimulatorSelectorResult {
        WatchSimulatorSelectorResult(
            exitCode: exitCode,
            stdout: "",
            stderr: "code=\(code)\n"
        )
    }

    private static func sanitizeName(_ name: String) -> String {
        let normalized = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(normalized.prefix(128))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            storage.append(data.prefix(remaining))
            if data.count > remaining { truncated = true }
        }
    }

    var data: Data { lock.withLock { storage } }
    var didTruncate: Bool { lock.withLock { truncated } }
}
