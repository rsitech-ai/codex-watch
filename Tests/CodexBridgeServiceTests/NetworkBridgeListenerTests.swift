@testable import CodexBridgeService
import CodexBridgeDelivery
import CodexBridgeShared
import CryptoKit
import Darwin
import Foundation
import Network
import Testing

private let listenerToken = Data(repeating: 0x44, count: 32)

@Test func productionListenerLoadsInjectedTLSIdentityAndBuildsBonjourAdvertisement() async throws {
    let fixture = try await ListenerFixture()
    let fingerprint = String(repeating: "ab", count: 32)
    let identity = try BridgeTLSIdentity(
        tlsOptions: NWProtocolTLS.Options(),
        publicKeySHA256: fingerprint
    )
    let listener = try NetworkBridgeListener(
        configuration: fixture.configuration,
        router: fixture.router,
        identityProvider: StaticTLSIdentityProvider(identity: identity),
        serviceName: "Codex Bridge Test",
        bindHost: "127.0.0.1",
        advertisedHost: "mac.local"
    )

    #expect(listener.advertisement.serviceType == "_voiceinbox._tcp")
    #expect(listener.advertisement.serviceName == "Codex Bridge Test")
    #expect(listener.advertisement.txtRecord(port: 42424) == [
        "host": "mac.local",
        "port": "42424",
        "protocol-version": "1",
        "public-key-sha256": fingerprint,
    ])
}

@Test func keychainIdentityProviderUsesOnlyTheInjectedReadOnlyStore() throws {
    let keychain = EmptyTLSIdentityKeychain()
    let provider = KeychainTLSIdentityProvider(keychain: keychain)

    #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
        _ = try provider.loadIdentity()
    }
    #expect(keychain.loadCount == 1)
}

@Test(arguments: [
    "0.0.0.0",
    "0",
    "0.0.0",
    "::",
    "[::]",
    "0:0:0:0:0:0:0:0",
    "*",
    "mac.local",
])
func productionListenerRejectsWildcardAndNonConcreteBindInsteadOfExposingAllInterfaces(
    _ bindHost: String
) async throws {
    let fixture = try await ListenerFixture()
    let identity = try BridgeTLSIdentity(
        tlsOptions: NWProtocolTLS.Options(),
        publicKeySHA256: String(repeating: "ab", count: 32)
    )

    #expect(throws: NetworkBridgeListenerError.invalidHost) {
        _ = try NetworkBridgeListener(
            configuration: fixture.configuration,
            router: fixture.router,
            identityProvider: StaticTLSIdentityProvider(identity: identity),
            serviceName: "Codex Bridge Test",
            bindHost: bindHost,
            advertisedHost: "mac.local"
        )
    }
}

@Test func plaintextTestListenerServesOneBoundedLoopbackRequestThenCloses() async throws {
    let fixture = try await ListenerFixture()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.isTLS == false)
    #expect(endpoint.port > 0)

    let body = try JSONEncoder().encode(PairingRedemptionRequest(code: "123456"))
    let request = Data(
        "POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nX-Codex-Version: 1\r\n\r\n".utf8
    ) + body
    let response = try tcpExchange(port: endpoint.port, request: request)
    let parsed = try splitHTTPResponse(response)
    let pairing = try JSONDecoder().decode(PairingRedemptionResponse.self, from: parsed.body)

    #expect(parsed.head.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(parsed.head.lowercased().contains("connection: close\r\n"))
    #expect(pairing.token == String(repeating: "44", count: 32))
}

@Test func finalAcknowledgementSerializesNoContentReasonPhraseAndEmptyBody() async throws {
    let fixture = try await ListenerFixture(prefillFinalReceipt: true)
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    let request = try fixture.signedFinalAcknowledgementRequest(nonce: "listener-final-ack")
    let response = try tcpExchange(port: endpoint.port, request: request)
    let parsed = try splitHTTPResponse(response)

    #expect(parsed.head.hasPrefix("HTTP/1.1 204 No Content\r\n"))
    #expect(parsed.head.lowercased().contains("content-length: 0\r\n"))
    #expect(parsed.body.isEmpty)
}

@Test func plaintextListenerSerializesCorruptFinalStatusAsTyped503() async throws {
    let fixture = try await ListenerFixture(prefillFinalReceipt: true)
    try Data("not-json".utf8).write(
        to: fixture.finalStatusRoot.appending(path: "\(fixture.memoID.rawValue).json")
    )
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    let request = try fixture.signedStatusRequest(nonce: "listener-corrupt-final-status")
    let response = try tcpExchange(port: endpoint.port, request: request)
    let parsed = try splitHTTPResponse(response)

    #expect(parsed.head.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
    #expect(parsed.body == Data("{\"error\":\"status_unavailable\"}".utf8))
}

@Test func plaintextListenerSerializesContradictoryDualStatusTruthAsTyped503() async throws {
    let fixture = try await ListenerFixture(prefillConflictingDualTruth: true)
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    let request = try fixture.signedStatusRequest(nonce: "listener-conflicting-dual-status")
    let response = try tcpExchange(port: endpoint.port, request: request)
    let parsed = try splitHTTPResponse(response)

    #expect(parsed.head.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
    #expect(parsed.body == Data("{\"error\":\"status_unavailable\"}".utf8))
}

@Test func plaintextTestListenerMapsLiveHeaderBoundTo413AndCloses() async throws {
    let fixture = try await ListenerFixture(maximumHeaderBytes: 96)
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    let request = Data(
        "POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Fill: \(String(repeating: "x", count: 128))".utf8
    )
    let response = try tcpExchange(port: endpoint.port, request: request)
    let parsed = try splitHTTPResponse(response)

    #expect(parsed.head.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
    #expect(parsed.head.lowercased().contains("connection: close\r\n"))
    #expect(parsed.body.isEmpty)
}

@Test func listenerAuthenticatesBeforeBody() async throws {
    let fixture = try await ListenerFixture()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }

    let requestHead = Data(
        "POST /v1/memos/\(fixture.memoID.rawValue) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(String(repeating: "0", count: 64))\r\nContent-Length: 16\r\nContent-Type: audio/mp4\r\nX-Codex-Body-SHA256: \(String(repeating: "a", count: 64))\r\nX-Codex-Captured-At: 41d954fc40000000\r\nX-Codex-Memo-ID: \(fixture.memoID.rawValue)\r\nX-Codex-Nonce: auth-before-body\r\nX-Codex-Revision: 1\r\nX-Codex-Signature: \(String(repeating: "0", count: 64))\r\nX-Codex-Timestamp: \(Int64(Date().timeIntervalSince1970))\r\nX-Codex-Version: 1\r\n\r\n".utf8
    )

    let response = try splitHTTPResponse(tcpExchange(port: endpoint.port, request: requestHead))

    #expect(response.head.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(response.body == Data("{\"error\":\"unauthorized\"}".utf8))
    #expect(try fixture.incomingNames().isEmpty)
}

@Test func listenerBoundsEightIdleConnections() async throws {
    let fixture = try await ListenerFixture()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    var descriptors: [Int32] = []
    defer { descriptors.forEach { Darwin.close($0) } }

    for _ in 0 ..< 9 {
        let descriptor = try openTCP(port: endpoint.port)
        descriptors.append(descriptor)
        try sendAll(Data("POST /v1/pair HTTP/1.1\r\n".utf8), to: descriptor)
    }
    try await Task.sleep(for: .milliseconds(100))

    #expect(listener.activeRequestCountForTesting == 8)
}

@Test func listenerAllowsTwoActiveWritersAndRejectsThirdWithUploadCapacity() async throws {
    let fixture = try await ListenerFixture()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let body = Data("capacity-audio".utf8)
    var first = try openTCP(port: endpoint.port)
    let second = try openTCP(port: endpoint.port)
    defer { if first >= 0 { Darwin.close(first) } }
    defer { Darwin.close(second) }
    try sendAll(fixture.signedUploadHead(body: body, nonce: "capacity-1"), to: first)
    try sendAll(fixture.signedUploadHead(body: body, nonce: "capacity-2"), to: second)
    try await eventually { try fixture.incomingNames().count == 2 }

    let third = try tcpExchange(
        port: endpoint.port,
        request: fixture.signedUploadHead(body: body, nonce: "capacity-3")
    )
    let response = try splitHTTPResponse(third)

    #expect(response.head.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
    #expect(response.body == Data("{\"error\":\"upload_capacity\"}".utf8))
    #expect(try fixture.incomingNames().count == 2)

    Darwin.close(first)
    first = -1
    try await eventually { try fixture.incomingNames().count == 1 }

    let replay = try splitHTTPResponse(tcpExchange(
        port: endpoint.port,
        request: fixture.signedUploadHead(body: body, nonce: "capacity-3")
    ))
    #expect(replay.head.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(try fixture.incomingNames().count == 1)

    let reopened = try openTCP(port: endpoint.port)
    defer { Darwin.close(reopened) }
    try sendAll(fixture.signedUploadHead(body: body, nonce: "capacity-4"), to: reopened)
    try await eventually { try fixture.incomingNames().count == 2 }
}

@Test func listenerDisconnectCancelsActiveStreamingWriter() async throws {
    let fixture = try await ListenerFixture(prefillFinalReceipt: false)
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    let body = Data("disconnect-audio".utf8)
    try sendAll(fixture.signedUploadHead(body: body, nonce: "disconnect"), to: descriptor)

    try await eventually { try fixture.incomingNames().count == 1 }
    #expect(try await fixture.finalStatuses.occupiedCount() == 1)
    Darwin.close(descriptor)
    try await eventuallyAsync {
        guard try fixture.incomingNames().isEmpty else { return false }
        return try await fixture.finalStatuses.occupiedCount() == 0
    }
}

@Test func listenerEnforcesTenSecondHeaderDeadlineWithInjectedScheduler() async throws {
    let fixture = try await ListenerFixture()
    let scheduler = ManualBridgeListenerDeadlineScheduler()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router,
        deadlineScheduler: scheduler.scheduler
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }

    try await eventually { scheduler.pendingCount(after: 10) == 1 }
    scheduler.fireNext(after: 10)
    let response = try splitHTTPResponse(receiveAll(from: descriptor))

    #expect(response.head.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    #expect(scheduler.scheduledDelays.contains(300))
}

@Test func listenerEnforcesThirtySecondIdleBodyDeadlineWithInjectedScheduler() async throws {
    let fixture = try await ListenerFixture(prefillFinalReceipt: false)
    let scheduler = ManualBridgeListenerDeadlineScheduler()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router,
        deadlineScheduler: scheduler.scheduler
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }
    try sendAll(
        fixture.signedUploadHead(body: Data("idle-body".utf8), nonce: "idle-timeout"),
        to: descriptor
    )

    try await eventually { scheduler.pendingCount(after: 30) == 1 }
    scheduler.fireNext(after: 30)
    let response = try splitHTTPResponse(receiveAll(from: descriptor))

    #expect(response.head.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    try await eventuallyAsync {
        guard try fixture.incomingNames().isEmpty else { return false }
        return try await fixture.finalStatuses.occupiedCount() == 0
    }
}

@Test func cancelledIdleDeadlineDeliveredLateIsInertAfterBodyRefresh() async throws {
    let fixture = try await ListenerFixture()
    let scheduler = ManualBridgeListenerDeadlineScheduler()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router,
        deadlineScheduler: scheduler.scheduler
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }
    let body = Data("refreshed-idle-body".utf8)
    try sendAll(
        fixture.signedUploadHead(body: body, nonce: "idle-generation"),
        to: descriptor
    )
    try await eventually { scheduler.pendingCount(after: 30) == 1 }

    try sendAll(Data(body.prefix(1)), to: descriptor)
    try await eventually {
        scheduler.scheduledCount(after: 30) >= 2 && scheduler.pendingCount(after: 30) == 1
    }
    scheduler.fireCancelledNext(after: 30)
    try sendAll(Data(body.dropFirst()), to: descriptor)

    let response = try splitHTTPResponse(receiveAll(from: descriptor))
    #expect(response.head.hasPrefix("HTTP/1.1 201 Created\r\n"))
    #expect(try await fixture.intake.audio(for: fixture.memoID) == body)
}

@Test func listenerEnforcesFiveMinuteTotalDeadlineWithInjectedScheduler() async throws {
    let fixture = try await ListenerFixture(prefillFinalReceipt: false)
    let scheduler = ManualBridgeListenerDeadlineScheduler()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router,
        deadlineScheduler: scheduler.scheduler
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }
    try sendAll(
        fixture.signedUploadHead(body: Data("total-body".utf8), nonce: "total-timeout"),
        to: descriptor
    )

    try await eventually { scheduler.pendingCount(after: 300) == 1 }
    scheduler.fireNext(after: 300)
    let response = try splitHTTPResponse(receiveAll(from: descriptor))

    #expect(response.head.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    try await eventuallyAsync {
        guard try fixture.incomingNames().isEmpty else { return false }
        return try await fixture.finalStatuses.occupiedCount() == 0
    }
}

@Test func listenerStreamsFragmentedHeadAndBodyIntoOneCommittedFile() async throws {
    let fixture = try await ListenerFixture()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router
    )
    let endpoint = try await listener.start()
    defer { Task { await listener.stop() } }
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }
    let body = Data("fragmented-streaming-audio".utf8)
    let head = try fixture.signedUploadHead(body: body, nonce: "fragmented-stream")

    try sendAll(Data(head.prefix(17)), to: descriptor)
    try sendAll(Data(head.dropFirst(17).prefix(53)), to: descriptor)
    try sendAll(Data(head.dropFirst(70)), to: descriptor)
    try sendAll(Data(body.prefix(4)), to: descriptor)
    try sendAll(Data(body.dropFirst(4).prefix(7)), to: descriptor)
    try sendAll(Data(body.dropFirst(11)), to: descriptor)

    let response = try splitHTTPResponse(receiveAll(from: descriptor))
    #expect(response.head.hasPrefix("HTTP/1.1 201 Created\r\n"))
    #expect(try await fixture.intake.audio(for: fixture.memoID) == body)
    #expect(try fixture.incomingNames().isEmpty)
}

@Test func stopStopsNewAdmissionAndCancelsTrackedPartialRequests() async throws {
    let fixture = try await ListenerFixture()
    let admissions = AdmissionRecorder()
    let listener = try NetworkBridgeListener(
        testingLoopbackPlaintextWithConfiguration: fixture.configuration,
        router: fixture.router,
        onAcceptedRequest: { Task { await admissions.record() } }
    )
    let endpoint = try await listener.start()
    let descriptor = try openTCP(port: endpoint.port)
    defer { Darwin.close(descriptor) }
    let partial = Data("POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8)
    _ = partial.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    await admissions.waitForAdmission()
    #expect(listener.activeRequestCountForTesting == 1)

    await listener.stop()
    #expect(listener.activeRequestCountForTesting == 0)
}

private struct StaticTLSIdentityProvider: BridgeTLSIdentityProvider {
    let identity: BridgeTLSIdentity

    func loadIdentity() throws -> BridgeTLSIdentity {
        identity
    }
}

private final class EmptyTLSIdentityKeychain: TLSIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    var loadCount: Int { lock.withLock { loads } }

    func load(label _: String) throws -> SecIdentity? {
        lock.withLock { loads += 1 }
        return nil
    }

    func insert(privateKey _: SecKey, certificate _: SecCertificate, label _: String) throws -> SecIdentity {
        Issue.record("read-only provider attempted an insertion")
        throw TLSIdentityProvisionerError.keychainUnavailable
    }

    func remove(label _: String) throws {
        Issue.record("read-only provider attempted a removal")
    }
}

private struct ListenerFixture {
    let memoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")
    let digest = String(repeating: "a", count: 64)
    let configuration: BridgeConfiguration
    let intakeRoot: URL
    let intake: IntakeStore
    let deliveryJournal: DeliveryJournal
    let finalStatuses: FinalDeliveryStatusStore
    let finalStatusRoot: URL
    let router: BridgeRequestRouter

    init(
        maximumHeaderBytes: Int = 1024,
        prefillFinalReceipt: Bool = false,
        prefillConflictingDualTruth: Bool = false
    ) async throws {
        configuration = try BridgeConfiguration(
            maximumHeaderBytes: maximumHeaderBytes,
            maximumBodyBytes: 4096
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bridge-listener-tests-\(UUID().uuidString)", isDirectory: true)
        intakeRoot = root
        intake = try IntakeStore(rootURL: root)
        deliveryJournal = try DeliveryJournal(
            root: root.appending(path: "delivery", directoryHint: .isDirectory),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        finalStatusRoot = root.appending(path: "final-status", directoryHint: .isDirectory)
        finalStatuses = try FinalDeliveryStatusStore(rootURL: finalStatusRoot)
        let pairing = try PairingStore(
            secretStore: InMemorySecretStore(),
            codeGenerator: { "123456" },
            tokenGenerator: { listenerToken }
        )
        _ = try await pairing.beginPairing(validFor: 600)
        _ = try await pairing.rotateCredential()
        if prefillFinalReceipt {
            try await finalStatuses.publish(FinalDeliveryReceipt(
                memoID: memoID,
                audioSHA256: digest,
                stateRevision: 8,
                deliveredAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
        }
        if prefillConflictingDualTruth {
            let body = Data("listener-dual-truth".utf8)
            let capturedAt = Date(timeIntervalSince1970: 1_699_999_999)
            let result = try await intake.commit(
                request: IntakeRequest(
                    memoID: memoID,
                    audioSHA256: AudioDigest.hex(body),
                    byteCount: body.count,
                    revision: 1,
                    capturedAt: capturedAt
                ),
                body: body
            )
            try deliveryJournal.create(.received(
                memoID: memoID,
                capturedAt: capturedAt,
                localeHint: nil,
                audioSHA256: result.receipt.audioSHA256,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ))
            _ = try deliveryJournal.transition(memoID: memoID, to: .transcribing)
            _ = try deliveryJournal.transition(
                memoID: memoID,
                to: .readyForCodex,
                transcript: "Dual truth"
            )
            _ = try deliveryJournal.transition(memoID: memoID, to: .inserting)
            _ = try deliveryJournal.transition(memoID: memoID, to: .reconciling)
            let delivered = try deliveryJournal.transition(memoID: memoID, to: .delivered)
            try await finalStatuses.publish(FinalDeliveryReceipt(
                memoID: memoID,
                audioSHA256: delivered.audioSHA256,
                stateRevision: result.receipt.acknowledgedRevision + delivered.revision,
                deliveredAt: delivered.updatedAt.addingTimeInterval(1)
            ))
        }
        router = try BridgeRequestRouter(
            pairingStore: pairing,
            intakeStore: intake,
            deliveryJournal: deliveryJournal,
            finalStatusStore: finalStatuses,
            allowedClockSkew: configuration.allowedClockSkew,
            replayRetention: 600,
            replayStore: InMemoryReplayNonceStore()
        )
    }

    func signedFinalAcknowledgementRequest(nonce: String) throws -> Data {
        let path = "/v1/memos/\(memoID.rawValue)/final-ack"
        let timestamp = Int64(Date().timeIntervalSince1970)
        let canonical = try CanonicalBridgeRequest(
            method: "POST",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: memoID,
            bodySHA256: digest,
            revision: 8
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: listenerToken)
        )
        let token = listenerToken.map { String(format: "%02x", $0) }.joined()
        return Data(
            "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\nX-Codex-Body-SHA256: \(digest)\r\nX-Codex-Memo-ID: \(memoID.rawValue)\r\nX-Codex-Nonce: \(nonce)\r\nX-Codex-Revision: 8\r\nX-Codex-Signature: \(signature)\r\nX-Codex-Timestamp: \(timestamp)\r\nX-Codex-Version: 1\r\n\r\n".utf8
        )
    }

    func signedStatusRequest(nonce: String) throws -> Data {
        let path = "/v1/memos/\(memoID.rawValue)/status"
        let timestamp = Int64(Date().timeIntervalSince1970)
        let emptyDigest = AudioDigest.hex(Data())
        let canonical = try CanonicalBridgeRequest(
            method: "GET",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: memoID,
            bodySHA256: emptyDigest,
            revision: 2
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: listenerToken)
        )
        let token = listenerToken.map { String(format: "%02x", $0) }.joined()
        return Data(
            "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\nX-Codex-Body-SHA256: \(emptyDigest)\r\nX-Codex-Memo-ID: \(memoID.rawValue)\r\nX-Codex-Nonce: \(nonce)\r\nX-Codex-Revision: 2\r\nX-Codex-Signature: \(signature)\r\nX-Codex-Timestamp: \(timestamp)\r\nX-Codex-Version: 1\r\n\r\n".utf8
        )
    }

    func signedUploadHead(body: Data, nonce: String) throws -> Data {
        let path = "/v1/memos/\(memoID.rawValue)"
        let timestamp = Int64(Date().timeIntervalSince1970)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let digest = AudioDigest.hex(body)
        let canonical = try CanonicalBridgeRequest(
            method: "POST",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: memoID,
            bodySHA256: digest,
            revision: 1,
            capturedAtBits: capturedAt.timeIntervalSinceReferenceDate.bitPattern,
            localeHint: "en-US"
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: listenerToken)
        )
        let token = listenerToken.map { String(format: "%02x", $0) }.joined()
        return Data(
            "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.count)\r\nContent-Type: audio/mp4\r\nX-Codex-Body-SHA256: \(digest)\r\nX-Codex-Captured-At: \(String(capturedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16))\r\nX-Codex-Locale: en-US\r\nX-Codex-Memo-ID: \(memoID.rawValue)\r\nX-Codex-Nonce: \(nonce)\r\nX-Codex-Revision: 1\r\nX-Codex-Signature: \(signature)\r\nX-Codex-Timestamp: \(timestamp)\r\nX-Codex-Version: 1\r\n\r\n".utf8
        )
    }

    func incomingNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: intakeRoot.path)
            .filter { $0.hasPrefix(".incoming-") }
    }
}

private func tcpExchange(port: UInt16, request: Data) throws -> Data {
    let descriptor = try openTCP(port: port)
    defer { Darwin.close(descriptor) }

    try sendAll(request, to: descriptor)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if received == 0 { return response }
        guard received > 0 else { throw POSIXTestError(operation: "recv", code: errno) }
        response.append(contentsOf: buffer.prefix(received))
        guard response.count <= 8192 else {
            throw POSIXTestError(operation: "response bound", code: EOVERFLOW)
        }
    }
}

private func sendAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let sent = Darwin.send(descriptor, base.advanced(by: offset), rawBuffer.count - offset, 0)
            guard sent > 0 else { throw POSIXTestError(operation: "send", code: errno) }
            offset += sent
        }
    }
}

private func receiveAll(from descriptor: Int32) throws -> Data {
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if received == 0 { return response }
        guard received > 0 else { throw POSIXTestError(operation: "recv", code: errno) }
        response.append(contentsOf: buffer.prefix(received))
        guard response.count <= 8192 else {
            throw POSIXTestError(operation: "response bound", code: EOVERFLOW)
        }
    }
}

private func eventually(
    attempts: Int = 100,
    condition: () throws -> Bool
) async throws {
    for _ in 0 ..< attempts {
        if try condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw POSIXTestError(operation: "eventually", code: ETIMEDOUT)
}

private func eventuallyAsync(
    attempts: Int = 100,
    condition: () async throws -> Bool
) async throws {
    for _ in 0 ..< attempts {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw POSIXTestError(operation: "eventually async", code: ETIMEDOUT)
}

private func openTCP(port: UInt16) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXTestError(operation: "socket", code: errno) }

    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
    else {
        throw POSIXTestError(operation: "setsockopt", code: errno)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        throw POSIXTestError(operation: "inet_pton", code: errno)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw POSIXTestError(operation: "connect", code: errno) }

    return descriptor
}

private func splitHTTPResponse(_ response: Data) throws -> (head: String, body: Data) {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = response.range(of: separator),
          let head = String(data: response[..<range.upperBound], encoding: .utf8)
    else {
        throw POSIXTestError(operation: "parse response", code: EPROTO)
    }
    return (head, Data(response[range.upperBound...]))
}

private struct POSIXTestError: Error {
    let operation: String
    let code: Int32
}

private actor AdmissionRecorder {
    private var admitted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        admitted = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForAdmission() async {
        guard !admitted else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class ManualBridgeListenerDeadlineScheduler: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let delay: TimeInterval
        let action: @Sendable () -> Void
        var cancelled: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var scheduler: BridgeListenerDeadlineScheduler {
        BridgeListenerDeadlineScheduler { [weak self] delay, action in
            guard let self else { return BridgeListenerDeadlineCancellation {} }
            let id = UUID()
            lock.withLock {
                entries.append(Entry(id: id, delay: delay, action: action, cancelled: false))
            }
            return BridgeListenerDeadlineCancellation { [weak self] in
                self?.lock.withLock {
                    guard let index = self?.entries.firstIndex(where: { $0.id == id }) else { return }
                    self?.entries[index].cancelled = true
                }
            }
        }
    }

    var scheduledDelays: [TimeInterval] {
        lock.withLock { entries.map(\.delay) }
    }

    func pendingCount(after delay: TimeInterval) -> Int {
        lock.withLock { entries.count { $0.delay == delay && !$0.cancelled } }
    }

    func scheduledCount(after delay: TimeInterval) -> Int {
        lock.withLock { entries.count { $0.delay == delay } }
    }

    func fireNext(after delay: TimeInterval) {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = entries.firstIndex(where: { $0.delay == delay && !$0.cancelled }) else {
                return nil
            }
            entries[index].cancelled = true
            return entries[index].action
        }
        action?()
    }

    func fireCancelledNext(after delay: TimeInterval) {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let index = entries.firstIndex(where: { $0.delay == delay && $0.cancelled }) else {
                return nil
            }
            return entries[index].action
        }
        action?()
    }
}
