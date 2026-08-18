import Foundation
import Testing
@testable import WatchSimulatorSelection

@Test func choosesSmallestDisplayOnExactActiveRuntime() throws {
    let fixture = try selectionFixture("exact-runtime")

    let selected = try WatchSimulatorSelector.select(
        activeSDK: fixture.activeSDK,
        runtimes: fixture.runtimes,
        devices: fixture.devices
    )

    #expect(selected.name == "Apple Watch SE 3 (40mm)")
    #expect(selected.identifier == "00000000-0000-0000-0000-000000000040")
    #expect(selected.runtimeVersion == "26.5")
    #expect(selected.displayMillimeters == 40)
    #expect(selected.rationale == "smallest-available-display-on-exact-active-runtime")
}

@Test func stableTieUsesNameThenIdentifier() throws {
    let fixture = try selectionFixture("stable-tie")

    let selected = try WatchSimulatorSelector.select(
        activeSDK: fixture.activeSDK,
        runtimes: fixture.runtimes,
        devices: fixture.devices
    )

    #expect(selected.identifier == "00000000-0000-0000-0000-000000000001")
}

@Test func selectEachDisplaySizeReturnsOneStableDestinationPerSize() throws {
    let runtime = exactRuntime
    let devices = [
        watchDevice(name: "Apple Watch SE 3 (40mm)", suffix: "0040"),
        watchDevice(name: "Apple Watch Series 11 (42mm)", suffix: "0042"),
        watchDevice(name: "Apple Watch Series 10 (42mm)", suffix: "1042"),
        watchDevice(name: "Apple Watch Series 6 (44mm)", suffix: "0044"),
        watchDevice(name: "Apple Watch Series 11 (46mm)", suffix: "0046"),
        watchDevice(name: "Apple Watch Ultra 3 (49mm)", suffix: "0049"),
    ]

    let selected = try WatchSimulatorSelector.selectEachDisplaySize(
        activeSDK: "26.5",
        runtimes: [runtime],
        devices: devices
    )

    #expect(selected.map(\.displayMillimeters) == [40, 42, 44, 46, 49])
    #expect(selected[1].name == "Apple Watch Series 10 (42mm)")
    #expect(selected.allSatisfy {
        $0.rationale == "one-stable-destination-per-display-on-exact-active-runtime"
    })
}

@Test func selectEachDisplaySizeRejectsDuplicateIdentifiers() {
    let duplicate = watchDevice(name: "Apple Watch Series 11 (42mm)", suffix: "0042")

    #expect(throws: WatchSimulatorSelectionError.contradictoryInventory) {
        try WatchSimulatorSelector.selectEachDisplaySize(
            activeSDK: "26.5",
            runtimes: [exactRuntime],
            devices: [duplicate, duplicate]
        )
    }
}

@Test func selectEachDisplaySizeRejectsUnknownAvailableSizeButIgnoresUnavailableDevices() throws {
    let unavailableUnknown = SimulatorDevice(
        name: "Apple Watch Fixture",
        identifier: "00000000-0000-0000-0000-000000009999",
        runtimeIdentifier: exactRuntime.identifier,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Fixture",
        isAvailable: false
    )
    let availableUnknown = SimulatorDevice(
        name: "Apple Watch Fixture",
        identifier: "00000000-0000-0000-0000-000000008888",
        runtimeIdentifier: exactRuntime.identifier,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Fixture",
        isAvailable: true
    )

    #expect(try WatchSimulatorSelector.selectEachDisplaySize(
        activeSDK: "26.5",
        runtimes: [exactRuntime],
        devices: [watchDevice(name: "Apple Watch SE 3 (40mm)", suffix: "0040"), unavailableUnknown]
    ).map(\.displayMillimeters) == [40])

    #expect(throws: WatchSimulatorSelectionError.unknownDisplaySize) {
        try WatchSimulatorSelector.selectEachDisplaySize(
            activeSDK: "26.5",
            runtimes: [exactRuntime],
            devices: [availableUnknown]
        )
    }
}

@Test(arguments: [
    ("runtime-mismatch", WatchSimulatorSelectionError.exactRuntimeUnavailable),
    ("unavailable-only", .noAvailableWatch),
    ("no-watch", .noAvailableWatch),
    ("unknown-size", .unknownDisplaySize),
])
func failsClosedForInvalidDestinationInventory(
    name: String,
    expected: WatchSimulatorSelectionError
) throws {
    let fixture = try selectionFixture(name)

    #expect(throws: expected) {
        try WatchSimulatorSelector.select(
            activeSDK: fixture.activeSDK,
            runtimes: fixture.runtimes,
            devices: fixture.devices
        )
    }
}

@Test func malformedInventoryFailsClosed() throws {
    let data = try fixtureData("malformed")

    #expect(throws: WatchSimulatorSelectionError.malformedInventory) {
        try SimulatorInventory.decodeRuntimes(data)
    }
}

@Test(arguments: ["", "26", "26.5.1", "latest", "26.x"])
func invalidActiveSDKFailsClosed(activeSDK: String) throws {
    let fixture = try selectionFixture("exact-runtime")

    #expect(throws: WatchSimulatorSelectionError.invalidSDKVersion) {
        try WatchSimulatorSelector.select(
            activeSDK: activeSDK,
            runtimes: fixture.runtimes,
            devices: fixture.devices
        )
    }
}

private struct SelectionFixture {
    let activeSDK: String
    let runtimes: [SimulatorRuntime]
    let devices: [SimulatorDevice]
}

private let exactRuntime = SimulatorRuntime(
    identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-26-5",
    version: "26.5",
    platform: "watchOS",
    isAvailable: true
)

private func watchDevice(name: String, suffix: String) -> SimulatorDevice {
    SimulatorDevice(
        name: name,
        identifier: "00000000-0000-0000-0000-00000000\(suffix)",
        runtimeIdentifier: exactRuntime.identifier,
        deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Fixture-\(suffix)",
        isAvailable: true
    )
}

private func selectionFixture(_ name: String) throws -> SelectionFixture {
    let root = try #require(
        JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any]
    )
    let activeSDK = try #require(root["activeSDK"] as? String)
    let runtimeObject = try #require(root["runtimeInventory"])
    let deviceObject = try #require(root["deviceInventory"])
    return try SelectionFixture(
        activeSDK: activeSDK,
        runtimes: SimulatorInventory.decodeRuntimes(
            JSONSerialization.data(withJSONObject: runtimeObject)
        ),
        devices: SimulatorInventory.decodeDevices(
            JSONSerialization.data(withJSONObject: deviceObject)
        )
    )
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try Data(contentsOf: url)
}
