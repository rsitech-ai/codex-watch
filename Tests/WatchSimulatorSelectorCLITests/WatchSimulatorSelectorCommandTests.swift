import Foundation
import Testing
@testable import WatchSimulatorSelectorCLI

@Test func commandSelectsSmallestExactRuntimeDestination() async throws {
    let fixture = try selectorFixture("exact-runtime")
    let runner = RecordingSimulatorToolRunner(results: [
        .activeSDK: .success(Data("26.5\n".utf8)),
        .runtimes: .success(fixture.runtimes),
        .devices: .success(fixture.devices),
    ])

    let result = await WatchSimulatorSelectorCommand.run(
        arguments: ["--format", "shell"],
        runner: runner
    )

    #expect(result.exitCode == .success)
    #expect(await runner.requests == [.activeSDK, .runtimes, .devices])
    #expect(result.stdout.contains("name='Apple Watch SE 3 (40mm)'"))
    #expect(result.stdout.contains("identifier=00000000-0000-0000-0000-000000000040"))
    #expect(result.stdout.contains("runtime=26.5"))
    #expect(result.stdout.contains("display_mm=40"))
    #expect(result.stdout.contains("rationale=smallest-available-display-on-exact-active-runtime"))
    #expect(result.stderr == "selected Watch simulator: Apple Watch SE 3 (40mm); watchOS 26.5; 40mm; smallest-available-display-on-exact-active-runtime\n")
}

@Test(arguments: [
    (SimulatorToolResult.unavailable, "TOOLS_UNAVAILABLE"),
    (.timedOut, "TOOL_TIMEOUT"),
    (.failed(status: 1), "TOOL_FAILED"),
    (.success(Data()), "INVALID_SDK_VERSION"),
])
func sdkToolFailuresAreClosed(
    toolResult: SimulatorToolResult,
    expectedCode: String
) async {
    let result = await WatchSimulatorSelectorCommand.run(
        arguments: ["--format", "shell"],
        runner: RecordingSimulatorToolRunner(results: [.activeSDK: toolResult])
    )

    #expect(result.exitCode == .toolFailure)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr == "code=\(expectedCode)\n")
}

@Test func destinationPolicyFailureUsesNoDestinationExit() async throws {
    let fixture = try selectorFixture("runtime-mismatch")
    let runner = RecordingSimulatorToolRunner(results: [
        .activeSDK: .success(Data("26.5\n".utf8)),
        .runtimes: .success(fixture.runtimes),
        .devices: .success(fixture.devices),
    ])

    let result = await WatchSimulatorSelectorCommand.run(
        arguments: ["--format", "shell"],
        runner: runner
    )

    #expect(result.exitCode == .noDestination)
    #expect(result.stderr == "code=EXACT_RUNTIME_UNAVAILABLE\n")
}

@Test(arguments: [
    [],
    ["--format"],
    ["--format", "json"],
    ["--format", "shell", "extra"],
])
func unsupportedArgumentsReturnUsage(arguments: [String]) async {
    let result = await WatchSimulatorSelectorCommand.run(
        arguments: arguments,
        runner: RecordingSimulatorToolRunner(results: [:])
    )

    #expect(result.exitCode == .usage)
    #expect(result.stderr == "code=USAGE\n")
}

@Test func xcrunInvocationsAreFixedAndReadOnly() {
    #expect(XcrunSimulatorToolRunner.invocation(for: .activeSDK) == ProcessInvocation(
        executable: "/usr/bin/xcrun",
        arguments: ["--sdk", "watchsimulator", "--show-sdk-version"]
    ))
    #expect(XcrunSimulatorToolRunner.invocation(for: .runtimes) == ProcessInvocation(
        executable: "/usr/bin/xcrun",
        arguments: ["simctl", "list", "runtimes", "--json"]
    ))
    #expect(XcrunSimulatorToolRunner.invocation(for: .devices) == ProcessInvocation(
        executable: "/usr/bin/xcrun",
        arguments: ["simctl", "list", "devices", "available", "--json"]
    ))
    let forbidden = ["boot", "shutdown", "erase", "delete", "pair", "xcodebuild"]
    for request in SimulatorToolRequest.allCases {
        #expect(!XcrunSimulatorToolRunner.invocation(for: request).arguments.contains {
            forbidden.contains($0)
        })
    }
}

@Test func shellNameEscapingCannotCreateAnotherAssignment() async {
    let runtimes = Data(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5","version":"26.5","platform":"watchOS","isAvailable":true}]}"#.utf8)
    let devices = Data(#"{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-26-5":[{"name":"Owner's Watch\nsecret=value (40mm)","udid":"00000000-0000-0000-0000-000000000040","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Fixture-40mm"}]}}"#.utf8)
    let runner = RecordingSimulatorToolRunner(results: [
        .activeSDK: .success(Data("26.5\n".utf8)),
        .runtimes: .success(runtimes),
        .devices: .success(devices),
    ])

    let result = await WatchSimulatorSelectorCommand.run(
        arguments: ["--format", "shell"],
        runner: runner
    )

    #expect(result.exitCode == .success)
    #expect(!result.stdout.contains("\nsecret=value"))
    #expect(result.stdout.contains("name='Owner'\"'\"'s Watch secret=value (40mm)'"))
}

private struct SelectorFixture {
    let runtimes: Data
    let devices: Data
}

private func selectorFixture(_ name: String) throws -> SelectorFixture {
    let testRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: testRoot
        .appending(path: "WatchSimulatorSelectionTests/Fixtures")
        .appending(path: "\(name).json"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try SelectorFixture(
        runtimes: JSONSerialization.data(withJSONObject: #require(object["runtimeInventory"])),
        devices: JSONSerialization.data(withJSONObject: #require(object["deviceInventory"]))
    )
}

private actor RecordingSimulatorToolRunner: SimulatorToolRunning {
    private(set) var requests: [SimulatorToolRequest] = []
    private let results: [SimulatorToolRequest: SimulatorToolResult]

    init(results: [SimulatorToolRequest: SimulatorToolResult]) {
        self.results = results
    }

    func run(_ request: SimulatorToolRequest) async -> SimulatorToolResult {
        requests.append(request)
        return results[request] ?? .failed(status: -1)
    }
}
