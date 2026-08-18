import Darwin
import Foundation
import Testing
@testable import WatchDevicePreflightCLI

@Test func readyInventoryReturnsSuccessWithoutClaimingPhysicalProof() async throws {
    let runner = RecordingDeviceToolRunner(result: .success(try fixtureData("ready-watch")))
    let workspace = RecordingInventoryWorkspace()

    let result = await WatchDevicePreflightCommand.run(
        arguments: [],
        runner: runner,
        workspaceFactory: { workspace }
    )

    #expect(result.exitCode == .success)
    #expect(result.output.contains("label=unverified"))
    #expect(result.output.contains("code=READY"))
    #expect(await runner.requests == [
        DeviceToolRequest(outputURL: workspace.outputURL, timeoutSeconds: 10),
    ])
    #expect(workspace.closeCount == 1)
}

@Test func disconnectedWatchReturnsClosedExternalBlock() async throws {
    let runner = RecordingDeviceToolRunner(
        result: .success(try fixtureData("disconnected-watch-ready-phone"))
    )

    let result = await WatchDevicePreflightCommand.run(
        arguments: [],
        runner: runner,
        workspaceFactory: RecordingInventoryWorkspace.init
    )

    #expect(result.exitCode == .notReady)
    #expect(result.output.contains("label=blocked:external"))
    #expect(result.output.contains("code=WATCH_TUNNEL_DISCONNECTED"))
    #expect(!result.output.contains("WATCH-DISCONNECTED"))
    #expect(!result.output.contains("PHONE-READY"))
}

@Test(arguments: [
    (DeviceToolResult.unavailable, "TOOLS_UNAVAILABLE"),
    (.timedOut, "TOOL_TIMEOUT"),
    (.failed(status: 70), "TOOL_FAILED"),
    (.success(Data("not-json".utf8)), "MALFORMED_INVENTORY"),
])
func toolAndDecodeFailuresRemainClosed(
    toolResult: DeviceToolResult,
    expectedCode: String
) async {
    let result = await WatchDevicePreflightCommand.run(
        arguments: [],
        runner: RecordingDeviceToolRunner(result: toolResult),
        workspaceFactory: RecordingInventoryWorkspace.init
    )

    #expect(result.exitCode == .toolFailure)
    #expect(result.output.contains("label=blocked:external"))
    #expect(result.output.contains("code=\(expectedCode)"))
}

@Test func explicitIdentifierIsUsedOnlyForSelectionAndNeverRendered() async throws {
    let runner = RecordingDeviceToolRunner(result: .success(try fixtureData("two-watches")))

    let result = await WatchDevicePreflightCommand.run(
        arguments: ["--watch-identifier", "WATCH-READY", "--json"],
        runner: runner,
        workspaceFactory: RecordingInventoryWorkspace.init
    )

    #expect(result.exitCode == .success)
    #expect(!result.output.contains("WATCH-READY"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    )
    #expect(object["code"] as? String == "READY")
}

@Test(arguments: [
    ["--watch-identifier"],
    ["--watch-identifier", ""],
    ["--unknown"],
    ["--json", "extra"],
])
func invalidArgumentsReturnUsage(arguments: [String]) async {
    let result = await WatchDevicePreflightCommand.run(
        arguments: arguments,
        runner: RecordingDeviceToolRunner(result: .unavailable),
        workspaceFactory: RecordingInventoryWorkspace.init
    )

    #expect(result.exitCode == .usage)
    #expect(result.output == "code=USAGE\n")
}

@Test func xcrunInvocationIsFixedAndReadOnly() {
    let outputURL = URL(fileURLWithPath: "/private/tmp/fixture/devices.json")
    let invocation = XcrunDeviceToolRunner.invocation(
        outputURL: outputURL,
        timeoutSeconds: 10
    )

    #expect(invocation.executable == "/usr/bin/xcrun")
    #expect(invocation.arguments == [
        "devicectl", "list", "devices", "--timeout", "10",
        "--json-output", "/private/tmp/fixture/devices.json",
    ])
    let forbidden = [
        "pair", "unpair", "developer", "manage", "restart", "xcodebuild",
        "register", "profile", "certificate",
    ]
    #expect(!invocation.arguments.contains { forbidden.contains($0) })
}

@Test func liveWorkspaceIsPrivateAndRemovesOnlyItsOwnedDirectory() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.appending(
        path: "watch-preflight-workspace-test-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let sentinel = fixtureRoot.appending(path: "sentinel")
    try Data("preserve".utf8).write(to: sentinel)
    let workspace = try PrivateInventoryWorkspace.create(baseDirectory: fixtureRoot)

    #expect(try posixMode(workspace.rootURL) == 0o700)
    #expect(workspace.outputURL.deletingLastPathComponent() == workspace.rootURL)

    workspace.close()

    #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
}

private func fixtureData(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root
        .appending(path: "WatchDeviceReadinessTests/Fixtures")
        .appending(path: "\(name).json"))
}

private func posixMode(_ url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return metadata.st_mode & 0o777
}

private actor RecordingDeviceToolRunner: DeviceToolRunning {
    private(set) var requests: [DeviceToolRequest] = []
    private let result: DeviceToolResult

    init(result: DeviceToolResult) {
        self.result = result
    }

    func listDevices(_ request: DeviceToolRequest) async -> DeviceToolResult {
        requests.append(request)
        return result
    }
}

private final class RecordingInventoryWorkspace: InventoryWorkspace, @unchecked Sendable {
    let outputURL = URL(fileURLWithPath: "/private/tmp/fixture-preflight/devices.json")
    private(set) var closeCount = 0

    func close() {
        closeCount += 1
    }
}
