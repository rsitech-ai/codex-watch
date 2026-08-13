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
