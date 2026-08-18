import CodexAppServerClient
import Darwin
import Foundation
import WatchDeviceReadiness

enum WatchDevicePreflightExitCode: Int32, Sendable {
    case success = 0
    case notReady = 2
    case toolFailure = 3
    case usage = 64
}

struct WatchDevicePreflightResult: Sendable, Equatable {
    let exitCode: WatchDevicePreflightExitCode
    let output: String
}

struct DeviceToolRequest: Sendable, Equatable {
    let outputURL: URL
    let timeoutSeconds: Int
}

enum DeviceToolResult: Sendable, Equatable {
    case success(Data)
    case unavailable
    case timedOut
    case failed(status: Int32)
}

protocol DeviceToolRunning: Sendable {
    func listDevices(_ request: DeviceToolRequest) async -> DeviceToolResult
}

protocol InventoryWorkspace: AnyObject, Sendable {
    var outputURL: URL { get }
    func close()
}

final class PrivateInventoryWorkspace: InventoryWorkspace, @unchecked Sendable {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    let rootURL: URL
    let outputURL: URL
    private let identity: Identity
    private let lock = NSLock()
    private var isClosed = false

    private init(rootURL: URL, identity: Identity) {
        self.rootURL = rootURL
        outputURL = rootURL.appending(path: "devices.json")
        self.identity = identity
    }

    static func create(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> PrivateInventoryWorkspace {
        let root = baseDirectory.appending(
            path: "codex-watch-preflight-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard chmod(root.path, 0o700) == 0, let identity = directoryIdentity(root) else {
            try? FileManager.default.removeItem(at: root)
            throw CocoaError(.fileWriteUnknown)
        }
        return PrivateInventoryWorkspace(rootURL: root, identity: identity)
    }

    func close() {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose,
              Self.directoryIdentity(rootURL) == identity
        else { return }
        try? FileManager.default.removeItem(at: rootURL)
    }

    deinit {
        close()
    }

    private static func directoryIdentity(_ url: URL) -> Identity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else { return nil }
        return Identity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}

struct ProcessInvocation: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

struct XcrunDeviceToolRunner: DeviceToolRunning {
    private static let maximumInventoryBytes = 4 * 1024 * 1024

    static func invocation(outputURL: URL, timeoutSeconds: Int) -> ProcessInvocation {
        ProcessInvocation(
            executable: "/usr/bin/xcrun",
            arguments: [
                "devicectl", "list", "devices", "--timeout", String(timeoutSeconds),
                "--json-output", outputURL.path,
            ]
        )
    }

    func listDevices(_ request: DeviceToolRequest) async -> DeviceToolResult {
        let command = Self.invocation(
            outputURL: request.outputURL,
            timeoutSeconds: request.timeoutSeconds
        )
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            return .unavailable
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: command.executable)
        child.arguments = command.arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            return .unavailable
        }

        let outcome = await OwnedChildShutdown(policy: OwnedChildShutdownPolicy(
            gracefulTimeout: .seconds(request.timeoutSeconds),
            terminateTimeout: .seconds(1),
            killTimeout: .seconds(1)
        )).stop(process: child, stdin: nil)
        switch outcome {
        case .terminated, .killed, .stillRunning:
            return .timedOut
        case .alreadyExited, .graceful:
            guard child.terminationStatus == 0 else {
                return .failed(status: child.terminationStatus)
            }
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: request.outputURL.path
            )
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= Self.maximumInventoryBytes
            else { return .failed(status: -1) }
            return .success(try Data(contentsOf: request.outputURL))
        } catch {
            return .failed(status: -1)
        }
    }
}

enum WatchDevicePreflightCommand {
    private struct Options {
        let selectedIdentifier: String?
        let json: Bool
    }

    static func run(
        arguments: [String],
        runner: any DeviceToolRunning = XcrunDeviceToolRunner(),
        workspaceFactory: @Sendable () throws -> any InventoryWorkspace = {
            try PrivateInventoryWorkspace.create()
        }
    ) async -> WatchDevicePreflightResult {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            return WatchDevicePreflightResult(exitCode: .usage, output: "code=USAGE\n")
        }

        let workspace: any InventoryWorkspace
        do {
            workspace = try workspaceFactory()
        } catch {
            return render(
                report: ReadinessReport(code: "WORKSPACE_UNAVAILABLE"),
                exitCode: .toolFailure,
                json: options.json
            )
        }
        defer { workspace.close() }

        let toolResult = await runner.listDevices(DeviceToolRequest(
            outputURL: workspace.outputURL,
            timeoutSeconds: 10
        ))
        switch toolResult {
        case .unavailable:
            return render(
                report: ReadinessReport(code: "TOOLS_UNAVAILABLE"),
                exitCode: .toolFailure,
                json: options.json
            )
        case .timedOut:
            return render(
                report: ReadinessReport(code: "TOOL_TIMEOUT"),
                exitCode: .toolFailure,
                json: options.json
            )
        case .failed:
            return render(
                report: ReadinessReport(code: "TOOL_FAILED"),
                exitCode: .toolFailure,
                json: options.json
            )
        case let .success(data):
            do {
                let inventory = try DeviceInventory.decode(data)
                let readiness = WatchReadinessClassifier.classify(
                    inventory,
                    selectedIdentifier: options.selectedIdentifier
                )
                return render(
                    report: ReadinessReport(readiness: readiness),
                    exitCode: readiness.code == .ready ? .success : .notReady,
                    json: options.json
                )
            } catch DeviceInventory.DecodingFailure.unsuccessfulOutcome {
                return render(
                    report: ReadinessReport(code: "TOOL_FAILED"),
                    exitCode: .toolFailure,
                    json: options.json
                )
            } catch {
                return render(
                    report: ReadinessReport(code: "MALFORMED_INVENTORY"),
                    exitCode: .toolFailure,
                    json: options.json
                )
            }
        }
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var selectedIdentifier: String?
        var json = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                guard !json else { throw ParseError.invalid }
                json = true
                index += 1
            case "--watch-identifier":
                guard selectedIdentifier == nil, index + 1 < arguments.count else {
                    throw ParseError.invalid
                }
                let value = arguments[index + 1]
                guard !value.isEmpty, value.utf8.count <= 4096 else {
                    throw ParseError.invalid
                }
                selectedIdentifier = value
                index += 2
            default:
                throw ParseError.invalid
            }
        }
        return Options(selectedIdentifier: selectedIdentifier, json: json)
    }

    private static func render(
        report: ReadinessReport,
        exitCode: WatchDevicePreflightExitCode,
        json: Bool
    ) -> WatchDevicePreflightResult {
        let output: String
        if json, let data = try? JSONEncoder.sorted.encode(report) {
            output = String(decoding: data, as: UTF8.self) + "\n"
        } else {
            output = report.humanDescription + "\n"
        }
        return WatchDevicePreflightResult(exitCode: exitCode, output: output)
    }

    private enum ParseError: Error { case invalid }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
