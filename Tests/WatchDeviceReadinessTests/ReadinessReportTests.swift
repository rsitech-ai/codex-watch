import Foundation
import Testing
@testable import WatchDeviceReadiness

@Test func readyReportRemainsUnverifiedUntilAWorkflowRuns() throws {
    let report = ReadinessReport(readiness: WatchReadiness(
        code: .ready,
        deviceName: "Fixture Watch",
        model: "Apple Watch SE 3",
        osVersion: "26.5",
        lockStateObserved: false
    ))

    #expect(report.label == "unverified")
    #expect(report.code == "READY")
    #expect(report.lockState == "unobserved")
    #expect(report.humanDescription == "label=unverified; code=READY; device=Fixture Watch; model=Apple Watch SE 3; os=26.5; lock-state=unobserved")
}

@Test func blockedReportContainsOnlyAllowListedJSONFields() throws {
    let report = ReadinessReport(readiness: WatchReadiness(
        code: .watchTunnelDisconnected,
        deviceName: "Fixture Watch",
        model: "Apple Watch Ultra 2",
        osVersion: "26.4",
        lockStateObserved: false
    ))
    let data = try JSONEncoder().encode(report)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(Set(object.keys) == [
        "schemaVersion", "label", "code", "device", "model", "osVersion", "lockState",
    ])
    #expect(object["label"] as? String == "blocked:external")
    #expect(object["code"] as? String == "WATCH_TUNNEL_DISCONNECTED")
}

@Test func humanReportNeutralizesControlAndDelimiterCharacters() {
    let report = ReadinessReport(readiness: WatchReadiness(
        code: .watchTunnelDisconnected,
        deviceName: "Fixture; Watch\nidentifier=SECRET",
        model: "Apple\rWatch",
        osVersion: "26.4\tprivate",
        lockStateObserved: false
    ))

    #expect(!report.humanDescription.contains("\n"))
    #expect(!report.humanDescription.contains("\r"))
    #expect(!report.humanDescription.contains("\t"))
    #expect(!report.humanDescription.contains("; Watch"))
    #expect(!report.humanDescription.contains("identifier="))
}
