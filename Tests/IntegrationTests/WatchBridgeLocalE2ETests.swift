import CodexBridgeDelivery
@testable import CodexBridgeService
import CodexBridgeShared
import CodexWatchCore
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import Testing

private let e2eMemoID = try! MemoID("817e3c02-e599-47e6-9e79-7da86290012f")
private let e2ePKCS12ImportLock = NSLock()

@Test func watchUploadSurvivesBridgeRestartAndDeliversExactlyOnceToFakeInbox() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-local-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let tls = try EphemeralTLSFixture(root: root.appendingPathComponent("tls", isDirectory: true))
    let productionIdentityProvider = CountingTLSIdentityProvider(
        wrapping: MemoryOnlyPKCS12TLSIdentityProvider(
            data: tls.identityData,
            password: tls.password
        )
    )
    let identity = try e2ePKCS12ImportLock.withLock {
        try productionIdentityProvider.loadIdentity()
    }
    let identityProvider = PreloadedTLSIdentityProvider(identity: identity)
    let configuration = try BridgeConfiguration(
        maximumHeaderBytes: 16 * 1024,
        maximumBodyBytes: 1 * 1024 * 1024,
        allowedClockSkew: 300
    )
    let secretStore = InMemorySecretStore()
    let token = Data((0 ..< 32).map { UInt8($0 + 1) })
    let pairing = try PairingStore(
        secretStore: secretStore,
        codeGenerator: { "482913" },
        tokenGenerator: { token }
    )
    let challenge = try await pairing.beginPairing(validFor: 300)
    let intakeRoot = root.appendingPathComponent("bridge/intake", isDirectory: true)
    let deliveryRoot = root.appendingPathComponent("bridge/delivery", isDirectory: true)
    let firstIntake = try IntakeStore(rootURL: intakeRoot)
    let firstRouter = try BridgeRequestRouter(
        pairingStore: pairing,
        intakeStore: firstIntake,
        allowedClockSkew: configuration.allowedClockSkew,
        replayRetention: 600,
        replayStore: InMemoryReplayNonceStore()
    )
    let firstListener = try NetworkBridgeListener(
        configuration: configuration,
        router: firstRouter,
        identityProvider: identityProvider,
        serviceName: "Voice Inbox Local E2E",
        bindHost: "127.0.0.1",
        advertisedHost: "127.0.0.1"
    )
    #expect(productionIdentityProvider.loadCount == 1)
    let watchRoot = root.appendingPathComponent("watch", isDirectory: true)
    let capturedAt = Date(timeIntervalSinceReferenceDate: 789_123_456.25)
    let verifiedDeliveryAt = capturedAt.addingTimeInterval(60)
    let watchStore = try WatchMemoStore(root: watchRoot, clock: { verifiedDeliveryAt })
    let rawAudio = Data("RAW-AUDIO-SENTINEL:\u{0}\u{1}\u{2}private voice bytes".utf8)
    let temporaryAudio = await watchStore.temporaryRecordingURL(for: e2eMemoID)
    try rawAudio.write(to: temporaryAudio)
    let committedWatchMemo = try await watchStore.commitRecording(
        temporaryURL: temporaryAudio,
        memoID: e2eMemoID,
        capturedAt: capturedAt,
        durationMilliseconds: 1250,
        localeHint: "en-US"
    )
    _ = try await withStartedListener(firstListener) { firstEndpoint in
        #expect(firstEndpoint.isTLS)
        #expect(firstEndpoint.host == "127.0.0.1")

        let pairingResponse = try await pinnedTLSExchange(
            endpoint: firstEndpoint,
            expectedPublicKeySHA256: identity.publicKeySHA256,
            request: pairingHTTPRequest(code: challenge.code)
        )
        #expect(pairingResponse.status == 200)
        let credential = try JSONDecoder().decode(
            PairingRedemptionResponse.self,
            from: pairingResponse.body
        )
        #expect(credential.token == token.hexString)

        let firstTransport = PinnedLoopbackWatchTransport(
            endpoint: firstEndpoint,
            expectedPublicKeySHA256: identity.publicKeySHA256,
            token: token
        )
        let firstCoordinator = try WatchTransferCoordinator(
            store: watchStore,
            transport: firstTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 1, maximumDelay: 4)
        )
        #expect(try await firstCoordinator.uploadNext() == .received(e2eMemoID))
    }
    #expect(firstListener.activeRequestCountForTesting == 0)

    let receipt = try #require(try await firstIntake.receipt(for: e2eMemoID))
    #expect(receipt.memoID == e2eMemoID)
    #expect(receipt.audioSHA256 == committedWatchMemo.metadata.audioSHA256)
    #expect(receipt.capturedAt == capturedAt)
    #expect(receipt.localeHint == "en-US")
    #expect(receipt.acknowledgedRevision == 2)
    #expect(try await firstIntake.audio(for: e2eMemoID) == rawAudio)

    let restartedIntake = try IntakeStore(rootURL: intakeRoot)
    let restartedJournal = try DeliveryJournal(root: deliveryRoot)
    let transcriber = DeterministicTranscriber(transcript: "Draft the offline launch checklist")
    let fakeInbox = AmbiguousAcceptanceInbox()
    let processor = MemoProcessor(
        journal: restartedJournal,
        transcriber: transcriber,
        inbox: fakeInbox
    )
    let restartedRouter = try BridgeRequestRouter(
        pairingStore: pairing,
        intakeStore: restartedIntake,
        deliveryJournal: restartedJournal,
        allowedClockSkew: configuration.allowedClockSkew,
        replayRetention: 600,
        replayStore: InMemoryReplayNonceStore()
    )
    let restartedListener = try NetworkBridgeListener(
        configuration: configuration,
        router: restartedRouter,
        identityProvider: identityProvider,
        serviceName: "Voice Inbox Local E2E",
        bindHost: "127.0.0.1",
        advertisedHost: "127.0.0.1"
    )
    #expect(productionIdentityProvider.loadCount == 1)
    _ = try await withStartedListener(restartedListener) { restartedEndpoint in
        let recovery = IntakeStorePendingMemoProcessor(
            intakeStore: restartedIntake,
            processor: processor,
            maximumRecords: 8
        )
        try await recovery.recoverPendingMemos()
        // A second recovery is the restart-safe retry: delivered journal truth
        // must reconcile without resubmitting the accepted marker.
        try await recovery.recoverPendingMemos()

        let marker = MemoProcessor.marker(for: e2eMemoID)
        let inboxPayloads = await fakeInbox.payloads
        #expect(inboxPayloads.count == 1)
        let payload = try #require(inboxPayloads.first)
        #expect(payload.components(separatedBy: marker).count - 1 == 1)
        #expect(payload.contains("Draft the offline launch checklist"))
        #expect(payload.contains("Captured at:"))
        #expect(payload.contains("Locale: en-US"))
        #expect(!payload.contains("RAW-AUDIO-SENTINEL"))
        #expect(payload.data(using: .utf8)?.range(of: rawAudio) == nil)
        #expect(await fakeInbox.submitCount == 1)
        #expect(await transcriber.callCount == 1)
        #expect(try restartedJournal.load(memoID: e2eMemoID).state == .delivered)

        let restartedTransport = PinnedLoopbackWatchTransport(
            endpoint: restartedEndpoint,
            expectedPublicKeySHA256: identity.publicKeySHA256,
            token: token
        )
        let restartedCoordinator = try WatchTransferCoordinator(
            store: watchStore,
            transport: restartedTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 1, maximumDelay: 4)
        )
        #expect(
            try await restartedCoordinator.syncNextStatus()
                == .statusUpdated(e2eMemoID, .delivered)
        )
        let deliveredWatchMemo = try await watchStore.load(memoID: e2eMemoID)
        #expect(deliveredWatchMemo.metadata.state == .delivered)
        #expect(deliveredWatchMemo.metadata.stateRevision == 7)
    }
    #expect(restartedListener.activeRequestCountForTesting == 0)
    #expect(await fakeInbox.activeCallCount == 0)
    #expect(await transcriber.activeCallCount == 0)
    #expect(try await watchStore.purgeDelivered(before: verifiedDeliveryAt).isEmpty)
    #expect(
        try await watchStore.purgeDelivered(before: verifiedDeliveryAt.addingTimeInterval(1))
            == [e2eMemoID]
    )
}

@Test func productionArchiveStatusAndFinalAckRemainExactlyOnceAcrossRestart() async throws {
    try await withProductionBridgeE2EFixture { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        #expect(try await fixture.intake.receipt(for: fixture.memoID) == nil)
        #expect(try await fixture.intake.retainedRecord(for: fixture.memoID) != nil)

        try await fixture.restartBridge()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(try await fixture.watchStore.load(memoID: fixture.memoID).metadata.state == .delivered)
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == nil)
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionTimeoutAfterPossibleAcceptanceReconcilesExactlyOnceAfterRestart() async throws {
    try await withProductionBridgeE2EFixture(inboxScenario: .timeoutAfterPossibleAcceptance) { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitJournalState(.reconciling, submitCount: 1, historyCount: 0)
        try await fixture.restartBridge()
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionAuthoritativeZeroMarkerAllowsOneSafeResend() async throws {
    try await withProductionBridgeE2EFixture(inboxScenario: .authoritativeZeroThenSafeResend) { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitJournalState(.reconciling, submitCount: 1, historyCount: 0)
        await fixture.advanceProductionRetry()
        try await fixture.awaitJournalState(.readyForCodex, submitCount: 1, historyCount: 1)
        await fixture.advanceProductionRetry()
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
        #expect(await fixture.fakeInbox.submitCount == 2)
        #expect(await fixture.fakeInbox.historyCount == 2)
    }
}

@Test func productionReplayAfterBridgeRestartIsRejectedBeforeExactlyOnceDelivery() async throws {
    try await withProductionBridgeE2EFixture { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.restartBridge()
        #expect(try await fixture.replayLastUpload() == 401)
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionStatus404RecoversByReuploadingBeforeExactlyOnceDelivery() async throws {
    try await withProductionBridgeE2EFixture { fixture in
        await fixture.stopProductionProcessorAtRestartBoundary()
        try await fixture.uploadNextMemo()
        try await fixture.restartBridge(withEmptyMemoState: true)
        #expect(try await fixture.pollOnce() == .retryScheduled(fixture.memoID, fixture.now))
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionCorruptFinalStatusIs503AndNeverTriggersRecoveryUpload() async throws {
    try await withProductionBridgeE2EFixture { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitRetainedThroughProductionCoordinator()
        try fixture.corruptFinalStatusReceipt()

        await #expect(throws: WatchBridgeTransportFailure.transient) {
            _ = try await fixture.pollOnce()
        }
        #expect(await fixture.recoveryUploadCount() == 0)
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
        #expect(try await fixture.watchStore.load(memoID: fixture.memoID).metadata.state == .received)
        #expect(try await fixture.intake.retainedRecord(for: fixture.memoID) != nil)
    }
}

@Test func productionContradictoryDualStatusTruthIs503AndNeverTriggersRecoveryUpload() async throws {
    try await withProductionBridgeE2EFixture(holdCommittedAdmissions: true) { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitCommittedAdmissionSignals(1)
        try await fixture.publishContradictoryFinalWhileActive()

        await #expect(throws: WatchBridgeTransportFailure.transient) {
            _ = try await fixture.pollOnce()
        }
        #expect(await fixture.recoveryUploadCount() == 0)
        #expect(await fixture.fakeInbox.acceptedMarkers.isEmpty)
        #expect(try await fixture.watchStore.load(memoID: fixture.memoID).metadata.state == .received)
        #expect(try await fixture.intake.receipt(for: fixture.memoID) != nil)
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) != nil)
    }
}

@Test func productionFinalAckLossRetriesIdempotentlyWithoutDuplicateInboxDelivery() async throws {
    try await withProductionBridgeE2EFixture { fixture in
        try await fixture.uploadNextMemo()
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        await fixture.loseNextFinalAckAfterServerAcceptance()
        #expect(try await fixture.pollOnce() == .statusUpdated(fixture.memoID, .delivered))
        #expect(try await fixture.watchStore.pendingFinalAcknowledgements().count == 1)
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == nil)
        try await fixture.restartBridge()
        #expect(try await fixture.pollOnce() == .idle)
        #expect(try await fixture.watchStore.pendingFinalAcknowledgements().isEmpty)
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionTerminalReceiptCapacityRejectsBeforeIntakeThenRecovers() async throws {
    try await withProductionBridgeE2EFixture(finalStatusCapacity: 1, prefillTerminalReceipt: true) { fixture in
        #expect(try await fixture.uploadNextMemoOnce() == .retryScheduled(fixture.memoID, fixture.now))
        #expect(try await fixture.intake.receipt(for: fixture.memoID) == nil)
        #expect(try await fixture.intake.retainedRecord(for: fixture.memoID) == nil)
        #expect(await fixture.fakeInbox.acceptedMarkers.isEmpty)
        try await fixture.releaseTerminalBackpressure()
        #expect(try await fixture.uploadNextMemoOnce() == .received(fixture.memoID))
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        try await fixture.pollUntilDeliveredAndAcknowledge()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
    }
}

@Test func productionReservationCommitFailureStillDeliversAndDuplicateRetryIsExactlyOnce() async throws {
    let writeFault = FailSelectedProductionFinalStatusWrite(ordinal: 2)
    try await withProductionBridgeE2EFixture(
        finalStatusFaultInjector: writeFault.inject,
        holdCommittedAdmissions: true
    ) { fixture in
        #expect(try await fixture.uploadNextMemoOnce() == .retryScheduled(fixture.memoID, fixture.now))
        #expect(await fixture.lastUploadStatus() == 500)
        #expect(
            await fixture.lastUploadResponseBody()
                == Data("{\"error\":\"status_unavailable\"}".utf8)
        )
        #expect(try await fixture.intake.receipt(for: fixture.memoID) != nil)
        try await fixture.awaitCommittedAdmissionSignals(1)

        let retryReceipt = try await fixture.retryOriginalUploadDirectly()
        let retryStatus = await fixture.lastUploadStatus()
        #expect(retryReceipt.memoID == fixture.memoID)
        #expect(retryStatus == 200)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(
            try await fixture.lastUploadResponseBody()
                == (encoder.encode(BridgeEnvelope(payload: retryReceipt)))
        )
        try await fixture.awaitCommittedAdmissionSignals(2)
        await fixture.releaseCommittedAdmissions()
        try await fixture.awaitDeliveredThroughProductionCoordinator()
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
        #expect(await fixture.fakeInbox.submitCount == 1)
        #expect(try await fixture.finalStatuses.occupiedCount() == 1)
    }
}

@Test func productionReservationCommitFailureAfterRetentionReturnsAuthoritativeDuplicateAcrossRestart() async throws {
    let writeFault = FailSelectedProductionFinalStatusWrite(ordinal: 2)
    try await withProductionBridgeE2EFixture(
        finalStatusFaultInjector: writeFault.inject
    ) { fixture in
        #expect(try await fixture.uploadNextMemoOnce() == .retryScheduled(fixture.memoID, fixture.now))
        #expect(await fixture.lastUploadStatus() == 500)
        #expect(
            await fixture.lastUploadResponseBody()
                == Data("{\"error\":\"status_unavailable\"}".utf8)
        )

        try await fixture.awaitRetainedThroughProductionCoordinator()
        let retainedBeforeRetry = try #require(
            try await fixture.intake.retainedRecord(for: fixture.memoID)
        )
        let finalBeforeRetry = try #require(
            try await fixture.finalStatuses.receipt(for: fixture.memoID)
        )
        #expect(try await fixture.intake.committedRecord(for: fixture.memoID) == nil)
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
        #expect(await fixture.fakeInbox.submitCount == 1)

        let retryReceipt = try await fixture.retryOriginalUploadDirectly()
        #expect(retryReceipt.memoID == fixture.memoID)
        #expect(await fixture.lastUploadStatus() == 200)
        #expect(try await fixture.intake.committedRecord(for: fixture.memoID) == nil)
        #expect(
            try await fixture.intake.retainedRecord(for: fixture.memoID) == retainedBeforeRetry
        )
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == finalBeforeRetry)
        #expect(await fixture.fakeInbox.submitCount == 1)

        try await fixture.restartBridge()
        #expect(try await fixture.intake.committedRecord(for: fixture.memoID) == nil)
        #expect(
            try await fixture.intake.retainedRecord(for: fixture.memoID) == retainedBeforeRetry
        )
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == finalBeforeRetry)

        _ = try await fixture.retryOriginalUploadDirectly()
        #expect(await fixture.lastUploadStatus() == 200)
        #expect(try await fixture.intake.committedRecord(for: fixture.memoID) == nil)
        #expect(
            try await fixture.intake.retainedRecord(for: fixture.memoID) == retainedBeforeRetry
        )
        #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == finalBeforeRetry)
        #expect(await fixture.fakeInbox.acceptedMarkers == [MemoProcessor.marker(for: fixture.memoID)])
        #expect(await fixture.fakeInbox.submitCount == 1)
    }
}

@Test func startedListenerScopeAwaitsCleanupWhenScenarioThrows() async throws {
    let fixture = try LocalE2EListenerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let exchange = ExchangeTaskHolder()

    do {
        try await withStartedListener(fixture.listener) { endpoint in
            await exchange.store(Task {
                try await pinnedTLSExchange(
                    endpoint: endpoint,
                    expectedPublicKeySHA256: fixture.publicKeySHA256,
                    request: Data("POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8),
                    timeout: .milliseconds(500)
                )
            })
            try await waitForActiveRequest(in: fixture.listener)
            throw LocalE2EError.injectedFailure
        }
        Issue.record("Expected the injected scenario failure")
    } catch LocalE2EError.injectedFailure {
        // Expected: the scope must still finish listener cleanup before rethrowing.
    }

    await exchange.waitForCompletion()
    #expect(fixture.listener.activeRequestCountForTesting == 0)
    try await fixture.listener.waitUntilStopped()
}

@Test func cancelledListenerStartScopeAwaitsProductionStopBeforeReturning() async throws {
    let fixture = try LocalE2EListenerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let startGate = ListenerStartCancellationGate()

    let scope = Task {
        try await withStartedListener(
            fixture.listener,
            start: {
                let productionStart = Task {
                    await startGate.waitUntilProductionStartAllowed()
                    return try await fixture.listener.start()
                }
                await startGate.markEntered()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return try await productionStart.value
                } catch {
                    productionStart.cancel()
                    await startGate.allowProductionStart()
                    _ = try? await productionStart.value
                    throw error
                }
            }
        ) { _ in
            Issue.record("A cancelled start must not enter the listener operation")
        }
    }

    await startGate.waitUntilEntered()
    scope.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await scope.value
    }
    try await fixture.listener.waitUntilStopped()
    #expect(fixture.listener.activeRequestCountForTesting == 0)
}

@Test func localListenerFixtureImportsProductionIdentityExactlyOnce() throws {
    let fixture = try LocalE2EListenerFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    #expect(fixture.productionIdentityLoadCount == 1)
}

@Test func alreadyCancelledExchangeCompletesWithoutLosingItsContinuation() async throws {
    let connection = NWConnection(
        host: "127.0.0.1",
        port: 9,
        using: .tcp
    )
    let operation = TLSExchangeOperation(
        connection: connection,
        request: Data("cancel-before-registration".utf8),
        timeout: .milliseconds(100)
    )
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await operation.run()
    }

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

@Test func silentTLSExchangeFailsAtTheBoundedClientTimeout() async throws {
    let fixture = try LocalE2EListenerFixture(requestTimeout: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    _ = try await withStartedListener(fixture.listener) { endpoint in
        await #expect(throws: LocalE2EError.exchangeTimedOut) {
            _ = try await pinnedTLSExchange(
                endpoint: endpoint,
                expectedPublicKeySHA256: fixture.publicKeySHA256,
                request: Data("POST /v1/pair HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8),
                timeout: .milliseconds(50)
            )
        }
    }
    #expect(fixture.listener.activeRequestCountForTesting == 0)
}

private final class ProductionBridgeE2EFixture: @unchecked Sendable {
    let memoID = e2eMemoID
    let now = Date(timeIntervalSinceReferenceDate: 789_123_999)
    let root: URL
    let watchStore: WatchMemoStore
    let fakeInbox: ProductionFakeInbox

    private let token: Data
    private let pairing: PairingStore
    private let configuration: BridgeConfiguration
    private let identity: BridgeTLSIdentity
    private let intakeRoot: URL
    private let retainedRoot: URL
    private let journalRoot: URL
    private let finalStatusRoot: URL
    private let replayRoot: URL
    private let finalStatusCapacity: Int
    private let backpressureMemoID = try! MemoID("bcd6dd54-9c0b-41e2-9f8f-e38db20aa001")
    private let transport: ProductionLoopbackWatchTransport
    private let transcriber: DeterministicTranscriber
    private let retryGate = ProductionRetryGate()
    private let admissionGate: ProductionAdmissionGate
    private var listener: NetworkBridgeListener
    private var journal: DeliveryJournal
    private var pendingProcessor: BoundedIntakeMemoProcessor
    var intake: IntakeStore
    var finalStatuses: FinalDeliveryStatusStore

    init(
        inboxScenario: ProductionFakeInbox.Scenario = .accept,
        finalStatusCapacity: Int = 4096,
        prefillTerminalReceipt: Bool = false,
        finalStatusFaultInjector: @escaping @Sendable (
            FinalDeliveryStatusStoreMutationBoundary
        ) throws -> Void = { _ in },
        holdCommittedAdmissions: Bool = false
    ) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watch-production-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        let tls = try EphemeralTLSFixture(root: root.appendingPathComponent("tls", isDirectory: true))
        let loadedIdentity = try e2ePKCS12ImportLock.withLock {
            try MemoryOnlyPKCS12TLSIdentityProvider(data: tls.identityData, password: tls.password)
                .loadIdentity()
        }
        identity = loadedIdentity
        configuration = try BridgeConfiguration(
            maximumHeaderBytes: 16 * 1024,
            maximumBodyBytes: 1 * 1024 * 1024,
            allowedClockSkew: 300
        )
        let deterministicToken = Data((0 ..< 32).map { UInt8($0 + 33) })
        token = deterministicToken
        pairing = try PairingStore(
            secretStore: InMemorySecretStore(),
            codeGenerator: { "615204" },
            tokenGenerator: { deterministicToken }
        )
        let challenge = try await pairing.beginPairing(validFor: 300)

        intakeRoot = root.appendingPathComponent("bridge/intake", isDirectory: true)
        retainedRoot = root.appendingPathComponent("bridge/retained", isDirectory: true)
        journalRoot = root.appendingPathComponent("bridge/delivery", isDirectory: true)
        finalStatusRoot = root.appendingPathComponent("bridge/final-status", isDirectory: true)
        replayRoot = root.appendingPathComponent("bridge/replay", isDirectory: true)
        self.finalStatusCapacity = finalStatusCapacity
        admissionGate = ProductionAdmissionGate(held: holdCommittedAdmissions)
        intake = try IntakeStore(rootURL: intakeRoot, retentionRootURL: retainedRoot)
        journal = try DeliveryJournal(root: journalRoot)
        finalStatuses = try FinalDeliveryStatusStore(
            rootURL: finalStatusRoot,
            capacity: finalStatusCapacity,
            faultInjector: finalStatusFaultInjector
        )
        fakeInbox = ProductionFakeInbox(scenario: inboxScenario)
        if prefillTerminalReceipt {
            try await finalStatuses.publish(FinalDeliveryReceipt(
                memoID: backpressureMemoID,
                audioSHA256: AudioDigest.hex(Data("terminal-capacity-seed".utf8)),
                stateRevision: 7,
                deliveredAt: now
            ))
        }
        transcriber = DeterministicTranscriber(transcript: "Draft the production bridge proof")
        let retention = try BridgeDeliveredRetentionController(
            intakeStore: intake,
            journal: journal
        )
        let completionPublisher = DeliveryCompletionPublisher(
            intakeStore: intake,
            journal: journal,
            finalStatusStore: finalStatuses,
            retainDelivered: { memoID in try await retention.retainDelivered(memoID) }
        )
        let memoProcessor = MemoProcessor(
            journal: journal,
            transcriber: transcriber,
            inbox: fakeInbox
        )
        let boundedProcessor = BoundedIntakeMemoProcessor(
            intakeStore: intake,
            processor: memoProcessor,
            maximumQueuedRecords: 2,
            sample: { 0 },
            sleep: { [retryGate] _ in await retryGate.waitForPermit() },
            onDelivered: { memoID in
                try await completionPublisher.publishAndRetain(memoID)
            }
        )
        pendingProcessor = boundedProcessor
        try await reconcileFixtureCapacity(intake: intake, finalStatuses: finalStatuses)
        try await boundedProcessor.recoverPendingMemos()
        let router = try BridgeRequestRouter(
            pairingStore: pairing,
            intakeStore: intake,
            deliveryJournal: journal,
            finalStatusStore: finalStatuses,
            allowedClockSkew: configuration.allowedClockSkew,
            replayRetention: 600,
            replayStore: DurableReplayNonceStore(rootURL: replayRoot),
            onCommitted: { [admissionGate] record in
                await admissionGate.beforeAdmission()
                await boundedProcessor.admit(record)
            }
        )
        listener = try NetworkBridgeListener(
            configuration: configuration,
            router: router,
            identityProvider: PreloadedTLSIdentityProvider(identity: identity),
            serviceName: "Voice Inbox Production E2E",
            bindHost: "127.0.0.1",
            advertisedHost: "127.0.0.1"
        )
        let endpoint = try await listener.start()
        let pairingResponse = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: identity.publicKeySHA256,
            request: pairingHTTPRequest(code: challenge.code)
        )
        guard pairingResponse.status == 200 else { throw LocalE2EError.invalidResponse }
        let credential = try JSONDecoder().decode(PairingRedemptionResponse.self, from: pairingResponse.body)
        guard credential.token == token.hexString else { throw LocalE2EError.invalidResponse }
        transport = ProductionLoopbackWatchTransport(
            endpoint: endpoint,
            expectedPublicKeySHA256: identity.publicKeySHA256,
            token: token
        )

        let watchRoot = root.appendingPathComponent("watch", isDirectory: true)
        watchStore = try WatchMemoStore(root: watchRoot)
        let audio = Data("production-composed voice memo".utf8)
        let temporary = await watchStore.temporaryRecordingURL(for: memoID)
        try audio.write(to: temporary)
        _ = try await watchStore.commitRecording(
            temporaryURL: temporary,
            memoID: memoID,
            capturedAt: Date(timeIntervalSinceReferenceDate: 789_123_456.25),
            durationMilliseconds: 1250,
            localeHint: "en-US"
        )
    }

    func uploadNextMemo() async throws {
        guard try await uploadNextMemoOnce() == .received(memoID) else {
            throw LocalE2EError.invalidResponse
        }
    }

    func uploadNextMemoOnce() async throws -> WatchTransferOutcome {
        try await makeCoordinator().uploadNext()
    }

    func awaitDeliveredThroughProductionCoordinator() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if try await finalStatuses.receipt(for: memoID) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalE2EError.invalidResponse
    }

    func awaitRetainedThroughProductionCoordinator() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let finalReceipt = try await finalStatuses.receipt(for: memoID)
            let committed = try await intake.committedRecord(for: memoID)
            let retained = try await intake.retainedRecord(for: memoID)
            if finalReceipt != nil, committed == nil, retained != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalE2EError.invalidResponse
    }

    func restartBridge(withEmptyMemoState: Bool = false) async throws {
        await listener.stop()
        try await listener.waitUntilStopped()
        await pendingProcessor.stop()
        let selectedIntakeRoot = withEmptyMemoState
            ? root.appendingPathComponent("empty-bridge/intake", isDirectory: true)
            : intakeRoot
        let selectedRetainedRoot = withEmptyMemoState
            ? root.appendingPathComponent("empty-bridge/retained", isDirectory: true)
            : retainedRoot
        let selectedJournalRoot = withEmptyMemoState
            ? root.appendingPathComponent("empty-bridge/delivery", isDirectory: true)
            : journalRoot
        let selectedFinalStatusRoot = withEmptyMemoState
            ? root.appendingPathComponent("empty-bridge/final-status", isDirectory: true)
            : finalStatusRoot
        let selectedReplayRoot = withEmptyMemoState
            ? root.appendingPathComponent("empty-bridge/replay", isDirectory: true)
            : replayRoot
        intake = try IntakeStore(
            rootURL: selectedIntakeRoot,
            retentionRootURL: selectedRetainedRoot
        )
        journal = try DeliveryJournal(root: selectedJournalRoot)
        finalStatuses = try FinalDeliveryStatusStore(
            rootURL: selectedFinalStatusRoot,
            capacity: finalStatusCapacity
        )
        let retention = try BridgeDeliveredRetentionController(
            intakeStore: intake,
            journal: journal
        )
        let completionPublisher = DeliveryCompletionPublisher(
            intakeStore: intake,
            journal: journal,
            finalStatusStore: finalStatuses,
            retainDelivered: { memoID in try await retention.retainDelivered(memoID) }
        )
        let memoProcessor = MemoProcessor(
            journal: journal,
            transcriber: transcriber,
            inbox: fakeInbox
        )
        let boundedProcessor = BoundedIntakeMemoProcessor(
            intakeStore: intake,
            processor: memoProcessor,
            maximumQueuedRecords: 2,
            sample: { 0 },
            sleep: { [retryGate] _ in await retryGate.waitForPermit() },
            onDelivered: { memoID in
                try await completionPublisher.publishAndRetain(memoID)
            }
        )
        pendingProcessor = boundedProcessor
        try await reconcileFixtureCapacity(intake: intake, finalStatuses: finalStatuses)
        try await boundedProcessor.recoverPendingMemos()
        let router = try BridgeRequestRouter(
            pairingStore: pairing,
            intakeStore: intake,
            deliveryJournal: journal,
            finalStatusStore: finalStatuses,
            allowedClockSkew: configuration.allowedClockSkew,
            replayRetention: 600,
            replayStore: DurableReplayNonceStore(rootURL: selectedReplayRoot),
            onCommitted: { record in await boundedProcessor.admit(record) }
        )
        listener = try NetworkBridgeListener(
            configuration: configuration,
            router: router,
            identityProvider: PreloadedTLSIdentityProvider(identity: identity),
            serviceName: "Voice Inbox Production E2E",
            bindHost: "127.0.0.1",
            advertisedHost: "127.0.0.1"
        )
        let endpoint = try await listener.start()
        await transport.update(endpoint: endpoint)
    }

    func pollUntilDeliveredAndAcknowledge() async throws {
        guard try await pollOnce() == .statusUpdated(memoID, .delivered) else {
            throw LocalE2EError.invalidResponse
        }
    }

    func pollOnce() async throws -> WatchTransferOutcome {
        try await makeCoordinator().syncNextStatus()
    }

    func corruptFinalStatusReceipt() throws {
        try Data("not-json".utf8).write(
            to: finalStatusRoot.appending(path: "\(memoID.rawValue).json")
        )
    }

    func publishContradictoryFinalWhileActive() async throws {
        let receipt = try #require(try await intake.receipt(for: memoID))
        try journal.create(.received(
            memoID: memoID,
            capturedAt: receipt.capturedAt,
            localeHint: receipt.localeHint,
            audioSHA256: receipt.audioSHA256,
            updatedAt: now
        ))
        _ = try journal.transition(memoID: memoID, to: .transcribing)
        _ = try journal.transition(
            memoID: memoID,
            to: .readyForCodex,
            transcript: "Dual truth"
        )
        _ = try journal.transition(memoID: memoID, to: .inserting)
        _ = try journal.transition(memoID: memoID, to: .reconciling)
        let delivered = try journal.transition(memoID: memoID, to: .delivered)
        try await finalStatuses.publish(FinalDeliveryReceipt(
            memoID: memoID,
            audioSHA256: delivered.audioSHA256,
            stateRevision: receipt.acknowledgedRevision + delivered.revision,
            deliveredAt: delivered.updatedAt.addingTimeInterval(1)
        ))
    }

    func recoveryUploadCount() async -> Int {
        await transport.recoveryUploadCount
    }

    func replayLastUpload() async throws -> Int {
        try await transport.replayLastUpload()
    }

    func lastUploadStatus() async -> Int? {
        await transport.lastUploadStatus
    }

    func lastUploadResponseBody() async -> Data? {
        await transport.lastUploadResponseBody
    }

    func retryOriginalUploadDirectly() async throws -> BridgeReceipt {
        try await transport.retryLastUploadWithFreshAuthentication()
    }

    func awaitCommittedAdmissionSignals(_ expected: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await admissionGate.arrivalCount >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalE2EError.invalidResponse
    }

    func releaseCommittedAdmissions() async {
        await admissionGate.release()
    }

    func loseNextFinalAckAfterServerAcceptance() async {
        await transport.loseNextFinalAckAfterServerAcceptance()
    }

    func advanceProductionRetry() async {
        await retryGate.releaseOne()
    }

    func stopProductionProcessorAtRestartBoundary() async {
        await pendingProcessor.stop()
    }

    func awaitJournalState(
        _ state: MemoState,
        submitCount: Int,
        historyCount: Int
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if (try? journal.load(memoID: memoID).state) == state,
               await fakeInbox.submitCount == submitCount,
               await fakeInbox.historyCount == historyCount
            {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalE2EError.invalidResponse
    }

    func releaseTerminalBackpressure() async throws {
        let receipt = try #require(try await finalStatuses.receipt(for: backpressureMemoID))
        guard try await finalStatuses.acknowledge(
            memoID: receipt.memoID,
            audioSHA256: receipt.audioSHA256,
            stateRevision: receipt.stateRevision
        ) else { throw LocalE2EError.invalidResponse }
    }

    func close() async {
        await admissionGate.release()
        await listener.stop()
        try? await listener.waitUntilStopped()
        await pendingProcessor.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeCoordinator() throws -> WatchTransferCoordinator {
        try WatchTransferCoordinator(
            store: watchStore,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 1, maximumDelay: 4),
            clock: { self.now },
            randomSample: { 0 }
        )
    }
}

private actor ProductionFakeInbox: InboxDeliveryClient {
    enum Scenario: Sendable {
        case accept
        case timeoutAfterPossibleAcceptance
        case authoritativeZeroThenSafeResend
    }

    private let scenario: Scenario
    private(set) var acceptedMarkers: [String] = []
    private(set) var submitCount = 0
    private(set) var historyCount = 0

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func submit(memoID: MemoID, marker: String, text: String) async throws {
        guard marker == MemoProcessor.marker(for: memoID), text.contains(marker) else {
            throw LocalE2EError.invalidResponse
        }
        submitCount += 1
        switch scenario {
        case .accept:
            acceptedMarkers.append(marker)
        case .timeoutAfterPossibleAcceptance where submitCount == 1:
            acceptedMarkers.append(marker)
            throw InboxSubmissionFailure.acceptanceUnknown
        case .authoritativeZeroThenSafeResend where submitCount == 1:
            throw InboxSubmissionFailure.acceptanceUnknown
        case .timeoutAfterPossibleAcceptance, .authoritativeZeroThenSafeResend:
            acceptedMarkers.append(marker)
        }
    }

    func history(containing marker: String) async throws -> InboxHistory {
        historyCount += 1
        return InboxHistory(
            texts: acceptedMarkers.filter { $0 == marker },
            authoritative: true
        )
    }
}

private actor ProductionRetryGate {
    private var permits = 0

    func releaseOne() {
        permits += 1
    }

    func waitForPermit() async {
        while !Task.isCancelled {
            if permits > 0 {
                permits -= 1
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor ProductionAdmissionGate {
    private(set) var arrivalCount = 0
    private var held: Bool

    init(held: Bool) {
        self.held = held
    }

    func beforeAdmission() async {
        arrivalCount += 1
        while held, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        held = false
    }
}

private final class FailSelectedProductionFinalStatusWrite: @unchecked Sendable {
    private let lock = NSLock()
    private let ordinal: Int
    private var writes = 0

    init(ordinal: Int) {
        self.ordinal = ordinal
    }

    func inject(at boundary: FinalDeliveryStatusStoreMutationBoundary) throws {
        guard boundary == .beforeTemporaryCreation else { return }
        let shouldFail = lock.withLock { () -> Bool in
            writes += 1
            return writes == ordinal
        }
        if shouldFail { throw LocalE2EError.injectedFailure }
    }
}

private func reconcileFixtureCapacity(
    intake: IntakeStore,
    finalStatuses: FinalDeliveryStatusStore
) async throws {
    var identities: [MemoID: String] = [:]
    var cursor: MemoID?
    repeat {
        let page = try await intake.committedRecordPage(maximumEntries: 2, afterMemoID: cursor)
        for record in page.records {
            guard identities.updateValue(record.receipt.audioSHA256, forKey: record.memoID) == nil else {
                throw LocalE2EError.invalidResponse
            }
        }
        guard page.hasMore else { break }
        guard let next = page.records.last?.memoID, next != cursor else {
            throw LocalE2EError.invalidResponse
        }
        cursor = next
    } while true
    try await finalStatuses.reconcileCapacityReservations(with: identities)
}

private actor ProductionLoopbackWatchTransport: WatchBridgeTransport {
    private var endpoint: NetworkBridgeEndpoint
    private let expectedPublicKeySHA256: String
    private let token: Data
    private var lastUploadWire: Data?
    private(set) var lastUploadStatus: Int?
    private(set) var lastUploadResponseBody: Data?
    private var lastUploadMemo: VoiceMemoMetadata?
    private var lastUploadBody: Data?
    private var lastExpectedRevision: UInt64?
    private var loseNextFinalAcknowledgement = false
    private(set) var recoveryUploadCount = 0

    init(endpoint: NetworkBridgeEndpoint, expectedPublicKeySHA256: String, token: Data) {
        self.endpoint = endpoint
        self.expectedPublicKeySHA256 = expectedPublicKeySHA256
        self.token = token
    }

    func update(endpoint: NetworkBridgeEndpoint) {
        self.endpoint = endpoint
    }

    func loseNextFinalAckAfterServerAcceptance() {
        loseNextFinalAcknowledgement = true
    }

    func replayLastUpload() async throws -> Int {
        guard let lastUploadWire else { throw LocalE2EError.invalidResponse }
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: lastUploadWire
        )
        return response.status
    }

    func upload(
        memo: VoiceMemoMetadata,
        audioURL: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        guard expectedRevision == memo.stateRevision + 1 else {
            throw WatchBridgeTransportFailure.permanent
        }
        let body = try Data(contentsOf: audioURL)
        lastUploadMemo = memo
        lastUploadBody = body
        lastExpectedRevision = expectedRevision
        let request = try BridgeUploadRequestBuilder.make(
            memo: memo,
            contentLength: body.count,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let wire = httpRequest(request, body: body)
        lastUploadWire = wire
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: wire
        )
        lastUploadStatus = response.status
        lastUploadResponseBody = response.body
        return try BridgeUploadResponseDecoder.receipt(statusCode: response.status, body: response.body)
    }

    func retryLastUploadWithFreshAuthentication() async throws -> BridgeReceipt {
        guard let memo = lastUploadMemo,
              let body = lastUploadBody,
              let expectedRevision = lastExpectedRevision,
              expectedRevision == memo.stateRevision + 1
        else { throw LocalE2EError.invalidResponse }
        let request = try BridgeUploadRequestBuilder.make(
            memo: memo,
            contentLength: body.count,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let wire = httpRequest(request, body: body)
        lastUploadWire = wire
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: wire
        )
        lastUploadStatus = response.status
        lastUploadResponseBody = response.body
        return try BridgeUploadResponseDecoder.receipt(
            statusCode: response.status,
            body: response.body
        )
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        let request = try BridgeStatusRequestBuilder.make(
            memo: memo,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: httpRequest(request)
        )
        return try BridgeStatusResponseDecoder.status(statusCode: response.status, body: response.body)
    }

    func recoverAbsentStatus(memo: VoiceMemoMetadata, audioURL: URL) async throws {
        recoveryUploadCount += 1
        let body = try Data(contentsOf: audioURL)
        let request = try BridgeRecoveryUploadRequestBuilder.make(
            memo: memo,
            contentLength: body.count,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: httpRequest(request, body: body)
        )
        _ = try BridgeUploadResponseDecoder.receipt(statusCode: response.status, body: response.body)
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        let request = try BridgeFinalAcknowledgementRequestBuilder.make(
            acknowledgement: acknowledgement,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: httpRequest(request)
        )
        _ = try BridgeFinalAcknowledgementResponseDecoder.acknowledged(
            statusCode: response.status,
            body: response.body
        )
        if loseNextFinalAcknowledgement {
            loseNextFinalAcknowledgement = false
            throw WatchBridgeTransportFailure.transient
        }
    }
}

private func withProductionBridgeE2EFixture<Result: Sendable>(
    inboxScenario: ProductionFakeInbox.Scenario = .accept,
    finalStatusCapacity: Int = 4096,
    prefillTerminalReceipt: Bool = false,
    finalStatusFaultInjector: @escaping @Sendable (
        FinalDeliveryStatusStoreMutationBoundary
    ) throws -> Void = { _ in },
    holdCommittedAdmissions: Bool = false,
    _ operation: (ProductionBridgeE2EFixture) async throws -> Result
) async throws -> Result {
    let fixture = try await ProductionBridgeE2EFixture(
        inboxScenario: inboxScenario,
        finalStatusCapacity: finalStatusCapacity,
        prefillTerminalReceipt: prefillTerminalReceipt,
        finalStatusFaultInjector: finalStatusFaultInjector,
        holdCommittedAdmissions: holdCommittedAdmissions
    )
    do {
        let result = try await operation(fixture)
        await fixture.close()
        return result
    } catch {
        await fixture.close()
        throw error
    }
}

private struct EphemeralTLSFixture {
    let identityData: Data
    let password: String

    init(root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key.pem")
        let certificate = root.appendingPathComponent("certificate.pem")
        password = UUID().uuidString
        _ = try Self.runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", key.path,
            "-out", certificate.path,
            "-days", "1",
            "-subj", "/CN=codex-watch-local-e2e",
        ])
        identityData = try Self.runOpenSSL([
            "pkcs12", "-export",
            "-out", "/dev/stdout",
            "-inkey", key.path,
            "-in", certificate.path,
            "-passout", "pass:\(password)",
        ], captureOutput: true)
        for url in [key, certificate] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        }
    }

    private static func runOpenSSL(
        _ arguments: [String],
        captureOutput: Bool = false
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let standardError = Pipe()
        let standardOutput = Pipe()
        process.standardOutput = captureOutput ? standardOutput : FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        let output = captureOutput
            ? standardOutput.fileHandleForReading.readDataToEndOfFile()
            : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "openssl failed"
            throw LocalE2EError.commandFailed(message)
        }
        return output
    }
}

private struct LocalE2EListenerFixture: @unchecked Sendable {
    let root: URL
    let listener: NetworkBridgeListener
    let publicKeySHA256: String
    let productionIdentityLoadCount: Int

    init(requestTimeout: TimeInterval = 2) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-watch-listener-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        do {
            let tls = try EphemeralTLSFixture(
                root: root.appendingPathComponent("tls", isDirectory: true)
            )
            let productionIdentityProvider = CountingTLSIdentityProvider(
                wrapping: MemoryOnlyPKCS12TLSIdentityProvider(
                    data: tls.identityData,
                    password: tls.password
                )
            )
            let identity = try e2ePKCS12ImportLock.withLock {
                try productionIdentityProvider.loadIdentity()
            }
            publicKeySHA256 = identity.publicKeySHA256
            let configuration = try BridgeConfiguration(
                maximumHeaderBytes: 4 * 1024,
                maximumBodyBytes: 64 * 1024,
                allowedClockSkew: 300,
                headerTimeout: requestTimeout,
                idleBodyTimeout: requestTimeout,
                totalRequestTimeout: requestTimeout
            )
            let pairing = try PairingStore(secretStore: InMemorySecretStore())
            let intake = try IntakeStore(
                rootURL: root.appendingPathComponent("intake", isDirectory: true)
            )
            let router = try BridgeRequestRouter(
                pairingStore: pairing,
                intakeStore: intake,
                allowedClockSkew: configuration.allowedClockSkew,
                replayRetention: 600,
                replayStore: InMemoryReplayNonceStore()
            )
            listener = try NetworkBridgeListener(
                configuration: configuration,
                router: router,
                identityProvider: PreloadedTLSIdentityProvider(identity: identity),
                serviceName: "Voice Inbox Scope Test",
                bindHost: "127.0.0.1",
                advertisedHost: "127.0.0.1"
            )
            productionIdentityLoadCount = productionIdentityProvider.loadCount
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

private struct PreloadedTLSIdentityProvider: BridgeTLSIdentityProvider {
    let identity: BridgeTLSIdentity

    func loadIdentity() throws -> BridgeTLSIdentity { identity }
}

private struct MemoryOnlyPKCS12TLSIdentityProvider: BridgeTLSIdentityProvider {
    let data: Data
    let password: String

    func loadIdentity() throws -> BridgeTLSIdentity {
        do {
            let identity = try PKCS12TLSIdentityProvider.importMemoryOnlyIdentity(
                data: data,
                password: password
            )
            return try BridgeTLSIdentity(secIdentity: identity)
        } catch {
            throw LocalE2EError.invalidResponse
        }
    }
}

private final class CountingTLSIdentityProvider: @unchecked Sendable, BridgeTLSIdentityProvider {
    private let wrapped: any BridgeTLSIdentityProvider
    private let lock = NSLock()
    private var storedLoadCount = 0

    init(wrapping wrapped: any BridgeTLSIdentityProvider) {
        self.wrapped = wrapped
    }

    var loadCount: Int { lock.withLock { storedLoadCount } }

    func loadIdentity() throws -> BridgeTLSIdentity {
        lock.withLock { storedLoadCount += 1 }
        return try wrapped.loadIdentity()
    }
}

private actor ListenerStartCancellationGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var productionStartAllowed = false
    private var productionStartWaiters: [CheckedContinuation<Void, Never>] = []

    func markEntered() {
        entered = true
        let pending = enteredWaiters
        enteredWaiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func allowProductionStart() {
        productionStartAllowed = true
        let pending = productionStartWaiters
        productionStartWaiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitUntilProductionStartAllowed() async {
        guard !productionStartAllowed else { return }
        await withCheckedContinuation { productionStartWaiters.append($0) }
    }
}

private actor ExchangeTaskHolder {
    private var task: Task<ParsedHTTPResponse, any Error>?

    func store(_ task: Task<ParsedHTTPResponse, any Error>) {
        self.task = task
    }

    func waitForCompletion() async {
        guard let task else { return }
        _ = try? await task.value
    }
}

private actor DeterministicTranscriber: TranscriptionEngine {
    private let transcript: String
    private(set) var callCount = 0
    private(set) var activeCallCount = 0

    init(transcript: String) {
        self.transcript = transcript
    }

    func transcribe(committedAudio: CommittedAudioAsset, localeHint: String?) async throws -> String {
        activeCallCount += 1
        defer { activeCallCount -= 1 }
        try committedAudio.validate()
        guard localeHint == "en-US" else { throw TranscriptionError.unsupportedLocale }
        callCount += 1
        return transcript
    }
}

private actor AmbiguousAcceptanceInbox: InboxDeliveryClient {
    private(set) var payloads: [String] = []
    private(set) var submitCount = 0
    private(set) var activeCallCount = 0

    func submit(memoID: MemoID, marker: String, text: String) async throws {
        activeCallCount += 1
        defer { activeCallCount -= 1 }
        guard text.contains(marker), marker.contains(memoID.rawValue) else {
            throw LocalE2EError.invalidResponse
        }
        submitCount += 1
        payloads.append(text)
        throw LocalE2EError.connectionLostAfterAcceptance
    }

    func history(containing marker: String) async throws -> InboxHistory {
        activeCallCount += 1
        defer { activeCallCount -= 1 }
        return InboxHistory(texts: payloads.filter { $0.contains(marker) }, authoritative: true)
    }
}

private actor PinnedLoopbackWatchTransport: WatchBridgeTransport {
    private let endpoint: NetworkBridgeEndpoint
    private let expectedPublicKeySHA256: String
    private let token: Data

    init(endpoint: NetworkBridgeEndpoint, expectedPublicKeySHA256: String, token: Data) {
        self.endpoint = endpoint
        self.expectedPublicKeySHA256 = expectedPublicKeySHA256
        self.token = token
    }

    func upload(
        memo: VoiceMemoMetadata,
        audioURL: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        guard expectedRevision == memo.stateRevision + 1 else {
            throw WatchBridgeTransportFailure.permanent
        }
        let body = try Data(contentsOf: audioURL)
        let signed = try BridgeUploadRequestBuilder.make(
            memo: memo,
            contentLength: body.count,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: httpRequest(signed, body: body)
        )
        return try BridgeUploadResponseDecoder.receipt(
            statusCode: response.status,
            body: response.body
        )
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        let signed = try BridgeStatusRequestBuilder.make(
            memo: memo,
            token: token,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.lowercased()
        )
        let response = try await pinnedTLSExchange(
            endpoint: endpoint,
            expectedPublicKeySHA256: expectedPublicKeySHA256,
            request: httpRequest(signed)
        )
        return try BridgeStatusResponseDecoder.status(
            statusCode: response.status,
            body: response.body
        )
    }
}

private struct ParsedHTTPResponse {
    let status: Int
    let body: Data
}

private func pairingHTTPRequest(code: String) throws -> Data {
    let body = try JSONEncoder().encode(PairingRedemptionRequest(code: code))
    let head = [
        "POST /v1/pair HTTP/1.1",
        "Host: 127.0.0.1",
        "Connection: close",
        "Content-Type: application/json",
        "Content-Length: \(body.count)",
        "X-Codex-Version: \(BridgeProtocolVersion.current.major)",
        "",
        "",
    ].joined(separator: "\r\n")
    return Data(head.utf8) + body
}

private func httpRequest(_ signed: SignedBridgeUploadRequest, body: Data) -> Data {
    var head = "\(signed.method) \(signed.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
    for (name, value) in signed.headers.sorted(by: { $0.key < $1.key }) {
        head += "\(name): \(value)\r\n"
    }
    return Data("\(head)\r\n".utf8) + body
}

private func httpRequest(_ signed: SignedBridgeControlRequest) -> Data {
    var head = "\(signed.method) \(signed.path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
    for (name, value) in signed.headers.sorted(by: { $0.key < $1.key }) {
        head += "\(name): \(value)\r\n"
    }
    return Data("\(head)\r\n".utf8) + signed.body
}

private func pinnedTLSExchange(
    endpoint: NetworkBridgeEndpoint,
    expectedPublicKeySHA256: String,
    request: Data,
    timeout: Duration = .seconds(5)
) async throws -> ParsedHTTPResponse {
    guard endpoint.isTLS else { throw LocalE2EError.insecureEndpoint }
    let tlsOptions = NWProtocolTLS.Options()
    let verificationQueue = DispatchQueue(label: "ai.rsitech.voiceinbox.e2e-pin")
    sec_protocol_options_set_verify_block(
        tlsOptions.securityProtocolOptions,
        { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let key = SecTrustCopyKey(secTrust)
            let representation = key.flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }
            let actual = representation.map { SHA256.hash(data: $0).hexString }
            complete(actual == expectedPublicKeySHA256)
        },
        verificationQueue
    )
    let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    let connection = NWConnection(
        host: NWEndpoint.Host(endpoint.host),
        port: NWEndpoint.Port(rawValue: endpoint.port)!,
        using: parameters
    )
    let wire = try await TLSExchangeOperation(
        connection: connection,
        request: request,
        timeout: timeout
    ).run()
    return try parseHTTPResponse(wire)
}

private final class TLSExchangeOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: Duration
    private let queue = DispatchQueue(label: "ai.rsitech.voiceinbox.e2e-client")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var terminalResult: Result<Data, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var response = Data()

    init(connection: NWConnection, request: Data, timeout: Duration = .seconds(5)) {
        self.connection = connection
        self.request = request
        self.timeout = timeout > .zero ? timeout : .milliseconds(1)
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        send()
                    case let .failed(error):
                        finish(.failure(error))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                if let terminalResult = register(continuation) {
                    continuation.resume(with: terminalResult)
                    return
                }
                if startConnectionIfPending() { scheduleTimeout() }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func send() {
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { finish(.failure(error)) } else { receive() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { lock.withLock { response.append(data) } }
            if let error {
                finish(.failure(error))
            } else if complete {
                finish(.success(lock.withLock { response }))
            } else {
                receive()
            }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let completed = lock.withLock { () -> (
            CheckedContinuation<Data, any Error>?, Task<Void, Never>?
        )? in
            guard terminalResult == nil else { return nil }
            terminalResult = result
            defer { self.continuation = nil }
            defer { timeoutTask = nil }
            return (self.continuation, timeoutTask)
        }
        guard let completed else { return }
        connection.cancel()
        completed.1?.cancel()
        completed.0?.resume(with: result)
    }

    private func register(
        _ continuation: CheckedContinuation<Data, any Error>
    ) -> Result<Data, any Error>? {
        lock.withLock {
            if let terminalResult { return terminalResult }
            self.continuation = continuation
            return nil
        }
    }

    private func scheduleTimeout() {
        let task = Task { [weak self, timeout] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(.failure(LocalE2EError.exchangeTimedOut))
        }
        let retained = lock.withLock { () -> Bool in
            guard terminalResult == nil else { return false }
            timeoutTask = task
            return true
        }
        if !retained { task.cancel() }
    }

    private func startConnectionIfPending() -> Bool {
        lock.withLock {
            guard terminalResult == nil else { return false }
            connection.start(queue: queue)
            return true
        }
    }
}

private func withStartedListener<Result: Sendable>(
    _ listener: NetworkBridgeListener,
    operation: @Sendable (NetworkBridgeEndpoint) async throws -> Result
) async throws -> Result {
    try await withStartedListener(
        listener,
        start: { try await listener.start() },
        operation: operation
    )
}

private func withStartedListener<Result: Sendable>(
    _ listener: NetworkBridgeListener,
    start: @Sendable () async throws -> NetworkBridgeEndpoint,
    operation: @Sendable (NetworkBridgeEndpoint) async throws -> Result
) async throws -> Result {
    do {
        let endpoint = try await start()
        try Task.checkCancellation()
        let result = try await operation(endpoint)
        await listener.stop()
        return result
    } catch {
        await listener.stop()
        throw error
    }
}

private func waitForActiveRequest(in listener: NetworkBridgeListener) async throws {
    for _ in 0 ..< 200 {
        if listener.activeRequestCountForTesting > 0 { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw LocalE2EError.requestNeverBecameActive
}

private func parseHTTPResponse(_ response: Data) throws -> ParsedHTTPResponse {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = response.range(of: separator),
          let head = String(data: response[..<range.lowerBound], encoding: .utf8),
          let statusLine = head.split(separator: "\r\n").first,
          let status = Int(statusLine.split(separator: " ")[safe: 1] ?? "")
    else { throw LocalE2EError.invalidResponse }
    return ParsedHTTPResponse(status: status, body: Data(response[range.upperBound...]))
}

private enum LocalE2EError: Error, Equatable {
    case commandFailed(String)
    case connectionLostAfterAcceptance
    case exchangeTimedOut
    case injectedFailure
    case insecureEndpoint
    case invalidResponse
    case requestNeverBecameActive
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
