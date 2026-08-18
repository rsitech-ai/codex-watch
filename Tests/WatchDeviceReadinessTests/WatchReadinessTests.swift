import Foundation
import Testing
@testable import WatchDeviceReadiness

private func fixture(_ name: String) throws -> DeviceInventory {
    let url = try #require(Bundle.module.url(
        forResource: name,
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try DeviceInventory.decode(Data(contentsOf: url))
}

@Test(arguments: [
    ("no-devices", WatchReadiness.Code.noMatchingWatch),
    ("two-watches", .ambiguousWatch),
    ("disconnected-watch-ready-phone", .watchTunnelDisconnected),
    ("ddi-unavailable", .ddiServicesUnavailable),
    ("developer-mode-disabled", .developerModeDisabled),
    ("developer-mode-unknown", .developerModeUnknown),
    ("not-paired", .watchNotPaired),
    ("no-ready-phone", .supportingPhoneUnavailable),
    ("locked-watch", .deviceLocked),
    ("unknown-lock-state", .lockStateUnknown),
    ("ready-watch", .ready),
])
func classifiesPhysicalWatchReadiness(
    name: String,
    expected: WatchReadiness.Code
) throws {
    #expect(WatchReadinessClassifier.classify(try fixture(name)).code == expected)
}

@Test func explicitSelectionDisambiguatesPhysicalWatches() throws {
    let result = WatchReadinessClassifier.classify(
        try fixture("two-watches"),
        selectedIdentifier: "WATCH-READY"
    )

    #expect(result.code == .ready)
    #expect(result.deviceName == "Fixture Ready Watch")
}

@Test func missingExplicitSelectionFailsClosed() throws {
    let result = WatchReadinessClassifier.classify(
        try fixture("ready-watch"),
        selectedIdentifier: "WATCH-MISSING"
    )

    #expect(result.code == .selectedWatchMissing)
    #expect(result.deviceName == nil)
}

@Test func absentLockStateIsReportedAsUnobservedWithoutBlockingReadiness() throws {
    let result = WatchReadinessClassifier.classify(try fixture("ready-watch"))

    #expect(result.code == .ready)
    #expect(!result.lockStateObserved)
}

@Test func rejectsTruncatedInventory() throws {
    let url = try #require(Bundle.module.url(
        forResource: "truncated",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))

    #expect(throws: DeviceInventory.DecodingFailure.malformed) {
        try DeviceInventory.decode(Data(contentsOf: url))
    }
}

@Test func rejectsUnsuccessfulToolOutcome() {
    let data = Data(#"{"info":{"outcome":"failure"},"result":{"devices":[]}}"#.utf8)

    #expect(throws: DeviceInventory.DecodingFailure.unsuccessfulOutcome) {
        try DeviceInventory.decode(data)
    }
}
