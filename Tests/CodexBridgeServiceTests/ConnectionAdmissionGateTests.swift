@testable import CodexBridgeService
import Foundation
import Testing

@Test func ninthConnectionIsRefusedUntilAnExplicitLeaseRelease() async throws {
    let gate = try ConnectionAdmissionGate()
    var tokens: [UUID] = []

    for _ in 0 ..< 8 {
        let token = await gate.acquireConnection()
        #expect(token != nil)
        if let token { tokens.append(token) }
    }

    #expect(await gate.acquireConnection() == nil)
    #expect(await gate.releaseConnection(tokens[0]))
    #expect(await gate.acquireConnection() != nil)
}

@Test func thirdUploadIsRefusedUntilAnExplicitLeaseRelease() async throws {
    let gate = try ConnectionAdmissionGate()
    let first = await gate.acquireUpload()
    let second = await gate.acquireUpload()

    #expect(first != nil)
    #expect(second != nil)
    #expect(await gate.acquireUpload() == nil)
    #expect(await gate.releaseUpload(first!))
    #expect(await gate.acquireUpload() != nil)
}

@Test func unknownAndAlreadyReleasedLeasesFailWithoutReleasingCapacity() async throws {
    let gate = try ConnectionAdmissionGate(maximumConnections: 1, maximumUploads: 1)
    let connection = await gate.acquireConnection()!
    let upload = await gate.acquireUpload()!

    #expect(await gate.releaseConnection(UUID()) == false)
    #expect(await gate.releaseUpload(UUID()) == false)
    #expect(await gate.acquireConnection() == nil)
    #expect(await gate.acquireUpload() == nil)

    #expect(await gate.releaseConnection(connection))
    #expect(await gate.releaseConnection(connection) == false)
    #expect(await gate.releaseUpload(upload))
    #expect(await gate.releaseUpload(upload) == false)
}

@Test func admissionGateRejectsNonpositiveLimits() {
    #expect(throws: BridgeConfigurationError.invalidLimit) {
        _ = try ConnectionAdmissionGate(maximumConnections: 0)
    }
    #expect(throws: BridgeConfigurationError.invalidLimit) {
        _ = try ConnectionAdmissionGate(maximumUploads: 0)
    }
}
