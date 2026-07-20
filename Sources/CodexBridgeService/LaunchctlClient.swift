import Darwin
import Foundation
import CodexAppServerClient

public protocol LaunchctlControlling: Sendable {
    func bootstrap(domain: String, plist: URL) async throws
    func bootout(domain: String, label: String) async throws
    func printService(domain: String, label: String) async throws -> String
}

public enum LaunchctlClientError: Error, Equatable, Sendable {
    case invalidArgument
    case launchFailed
    case serviceNotLoaded
    case timedOut
    case childStillRunning(pid: pid_t, killResult: Int32)
    case commandFailed(status: Int32, stdoutBytes: Int, stderrBytes: Int)
}

public struct LaunchctlClient: LaunchctlControlling, Sendable {
    public static let maximumOutputBytes = 64 * 1024
    public static let defaultTimeout: Duration = .seconds(15)

    private let executable: URL
    private let timeout: Duration
    private let outputLimit: Int
    private let shutdown: @Sendable (Process) async -> OwnedChildShutdownOutcome

    public init() {
        executable = URL(fileURLWithPath: "/bin/launchctl")
        timeout = Self.defaultTimeout
        outputLimit = Self.maximumOutputBytes
        shutdown = Self.defaultShutdown
    }

    init(executable: URL, timeout: Duration, outputLimit: Int) {
        self.executable = executable.standardizedFileURL
        self.timeout = timeout
        self.outputLimit = min(max(outputLimit, 0), Self.maximumOutputBytes)
        shutdown = Self.defaultShutdown
    }

    init(
        executable: URL,
        timeout: Duration,
        outputLimit: Int,
        shutdown: @escaping @Sendable (Process) async -> OwnedChildShutdownOutcome
    ) {
        self.executable = executable.standardizedFileURL
        self.timeout = timeout
        self.outputLimit = min(max(outputLimit, 0), Self.maximumOutputBytes)
        self.shutdown = shutdown
    }

    public func bootstrap(domain: String, plist: URL) async throws {
        try validate(domain: domain)
        guard plist.isFileURL, plist.path.hasPrefix("/") else {
            throw LaunchctlClientError.invalidArgument
        }
        _ = try await run(arguments: ["bootstrap", domain, plist.standardizedFileURL.path])
    }

    public func bootout(domain: String, label: String) async throws {
        try validate(domain: domain, label: label)
        _ = try await run(arguments: ["bootout", "\(domain)/\(label)"])
    }

    public func printService(domain: String, label: String) async throws -> String {
        try validate(domain: domain, label: label)
        let output = try await run(arguments: ["print", "\(domain)/\(label)"])
        return String(decoding: output.stdout, as: UTF8.self)
    }

    private func validate(domain: String, label: String? = nil) throws {
        let prefix = "gui/"
        guard domain.hasPrefix(prefix),
              !domain.dropFirst(prefix.count).isEmpty,
              domain.dropFirst(prefix.count).allSatisfy(\.isNumber),
              !domain.contains(where: { $0.isNewline || $0 == "\0" })
        else { throw LaunchctlClientError.invalidArgument }
        if let label {
            guard !label.isEmpty,
                  !label.contains("/"),
                  !label.contains(where: { $0.isNewline || $0 == "\0" })
            else { throw LaunchctlClientError.invalidArgument }
        }
    }

    private func run(arguments: [String]) async throws -> LaunchctlCommandOutput {
        guard executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              timeout > .zero
        else { throw LaunchctlClientError.invalidArgument }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = BoundedProcessOutput(limit: outputLimit)
        let stderr = BoundedProcessOutput(limit: outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }
        do { try process.run() }
        catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw LaunchctlClientError.launchFailed
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            let survivor = process.isRunning ? await shutdown(process) : nil
            Self.close(stdoutPipe)
            Self.close(stderrPipe)
            if case let .stillRunning(pid, killResult) = survivor {
                throw LaunchctlClientError.childStillRunning(pid: pid, killResult: killResult)
            }
            throw error
        }
        if process.isRunning {
            let outcome = await shutdown(process)
            Self.close(stdoutPipe)
            Self.close(stderrPipe)
            if case let .stillRunning(pid, killResult) = outcome {
                throw LaunchctlClientError.childStillRunning(pid: pid, killResult: killResult)
            }
            throw LaunchctlClientError.timedOut
        }

        try? await Task.sleep(for: .milliseconds(20))
        Self.close(stdoutPipe)
        Self.close(stderrPipe)
        let result = LaunchctlCommandOutput(stdout: stdout.data, stderr: stderr.data)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if ["print", "bootout"].contains(arguments.first), process.terminationStatus == 113 {
                throw LaunchctlClientError.serviceNotLoaded
            }
            throw LaunchctlClientError.commandFailed(
                status: process.terminationStatus,
                stdoutBytes: result.stdout.count,
                stderrBytes: result.stderr.count
            )
        }
        return result
    }

    private static func defaultShutdown(_ process: Process) async -> OwnedChildShutdownOutcome {
        await OwnedChildShutdown(policy: .init(
            gracefulTimeout: .zero,
            terminateTimeout: .milliseconds(100),
            killTimeout: .milliseconds(100)
        )).stop(process: process, stdin: nil)
    }

    private static func close(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private struct LaunchctlCommandOutput: Sendable {
    let stdout: Data
    let stderr: Data
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            if remaining > 0 { storage.append(data.prefix(remaining)) }
        }
    }

    var data: Data { lock.withLock { storage } }
}
