import CodexBridgeShared
@testable import CodexWatchCore
import Foundation
import Testing

@Test func successfulUploadPersistsReceivedBeforeReportingReceipt() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(outcome == .received(fixture.memoID))
        #expect(stored.metadata.state == .received)
        #expect(stored.metadata.stateRevision == 2)
        #expect(await fixture.transport.callCount == 1)
    }
}

@Test func transientFailureReturnsMemoToSavedWithRetrySchedule() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try await withCoordinatorFixture(behavior: .failure(.transient), now: now) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(outcome == .retryScheduled(fixture.memoID, now.addingTimeInterval(2)))
        #expect(stored.metadata.state == .saved)
        #expect(stored.metadata.stateRevision == 2)

        let earlyRetry = try await fixture.coordinator.uploadNext()
        #expect(earlyRetry == .retryScheduled(fixture.memoID, now.addingTimeInterval(2)))
        #expect(await fixture.transport.callCount == 1)
    }
}

@Test func unknownInfrastructureFailurePreservesMemoAndSchedulesRetry() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try await withCoordinatorFixture(behavior: .unknownFailure, now: now) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)
        #expect(outcome == .retryScheduled(fixture.memoID, now.addingTimeInterval(2)))
        #expect(stored.metadata.state == .saved)
    }
}

@Test func malformedSuccessfulUploadResponsePreservesMemoAndSchedulesRetry() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try await withCoordinatorFixture(behavior: .malformedSuccessfulResponse, now: now) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(outcome == .retryScheduled(fixture.memoID, now.addingTimeInterval(2)))
        #expect(stored.metadata.state == .saved)
    }
}

@Test func authenticationFailurePreservesSavedMemoForRepairAndRequeue() async throws {
    try await withCoordinatorFixture(behavior: .failure(.authentication)) { fixture in
        let before = try await fixture.store.load(memoID: fixture.memoID)

        #expect(try await fixture.coordinator.uploadNext() == .pairingRequired(fixture.memoID))

        let after = try await fixture.store.load(memoID: fixture.memoID)
        #expect(after.metadata.state == .saved)
        #expect(after.metadata.audioSHA256 == before.metadata.audioSHA256)
        #expect(after.audioURL == before.audioURL)
    }
}

@Test func pairingBarrierPersistsAcrossStoreAndCoordinatorRelaunch() async throws {
    try await withCoordinatorFixture(behavior: .failure(.authentication)) { fixture in
        #expect(try await fixture.coordinator.uploadNext() == .pairingRequired(fixture.memoID))

        let restartedStore = try WatchMemoStore(root: fixture.root)
        let transport = StubTransport(behavior: .success)
        let restarted = try WatchTransferCoordinator(
            store: restartedStore,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        #expect(try await restarted.uploadNext() == .pairingRequired(fixture.memoID))
        #expect(await transport.callCount == 0)
        #expect(try await restartedStore.load(memoID: fixture.memoID).metadata.state == .saved)
    }
}

@Test func relaunchPreservesRetryDeadlineAndDoesNotWakeTransportEarly() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try await withCoordinatorFixture(behavior: .failure(.transient), now: now) { fixture in
        #expect(
            try await fixture.coordinator.uploadNext()
                == .retryScheduled(fixture.memoID, now.addingTimeInterval(2))
        )

        let newTransport = StubTransport(behavior: .success)
        let relaunched = try WatchTransferCoordinator(
            store: fixture.store,
            transport: newTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
            clock: { now }
        )

        #expect(
            try await relaunched.uploadNext()
                == .retryScheduled(fixture.memoID, now.addingTimeInterval(2))
        )
        #expect(await newTransport.callCount == 0)
    }
}

@Test func relaunchRecoversInterruptedUploadingStateThroughIdempotentReupload() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.store.transition(memoID: fixture.memoID, to: .uploading)
        let newTransport = StubTransport(behavior: .success)
        let relaunched = try WatchTransferCoordinator(
            store: fixture.store,
            transport: newTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await relaunched.uploadNext() == .received(fixture.memoID))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .received)
        #expect(await newTransport.callCount == 1)
    }
}

@Test func relaunchAcceptsAuthoritativeReceiptFromUploadAcceptedBeforeCrash() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.store.transition(memoID: fixture.memoID, to: .uploading)
        let newTransport = StubTransport(behavior: .existingReceipt(revision: 2))
        let relaunched = try WatchTransferCoordinator(
            store: fixture.store,
            transport: newTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await relaunched.uploadNext() == .received(fixture.memoID))
        let stored = try await fixture.store.load(memoID: fixture.memoID)
        #expect(stored.metadata.state == .received)
        #expect(stored.metadata.stateRevision == 2)
        #expect(await newTransport.callCount == 1)
    }
}

@Test func authenticatedIdenticalReceivedStatusIsIdempotentNoProgress() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        #expect(try await fixture.coordinator.uploadNext() == .received(fixture.memoID))
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let transport = try StatusTransport(status: BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .received,
            stateRevision: 2,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await coordinator.syncNextStatus() == .idle)
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata == received)
    }
}

@Test func activityRegistryMovesFromCompletedFirstStatusToExactBlockingSecondStatus() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-status-activity-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = try MemoID("423e4567-e89b-12d3-a456-426614174001")
    let secondID = try MemoID("423e4567-e89b-12d3-a456-426614174002")
    let store = try WatchMemoStore(root: root)
    try await commitTransferMemo(memoID: firstID, state: .received, capturedAt: Date(timeIntervalSince1970: 1), store: store)
    try await commitTransferMemo(memoID: secondID, state: .received, capturedAt: Date(timeIntervalSince1970: 2), store: store)
    let transport = FirstStatusCompletesSecondBlocksTransport(firstMemoID: firstID)
    let activityRegistry = WatchTransferActivityRegistry()
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
        activityRegistry: activityRegistry
    )

    let sync = Task { try await coordinator.syncNextStatus() }
    #expect(await transport.nextBlockingMemoID() == secondID)
    #expect(await activityRegistry.activeMemoIDs == Set([secondID]))
    let cancelledFirst = await activityRegistry.cancelIfActive(firstID) { sync.cancel() }
    #expect(!cancelledFirst)
    #expect(await activityRegistry.activeMemoIDs == Set([secondID]))

    let cancelledSecond = await activityRegistry.cancelIfActive(secondID) { sync.cancel() }
    #expect(cancelledSecond)
    await #expect(throws: CancellationError.self) {
        _ = try await sync.value
    }
    #expect(await activityRegistry.activeMemoIDs.isEmpty)
}

@Test func activityRegistryMovesFromCompletedFirstFinalAckToExactBlockingSecondFinalAck() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-final-ack-activity-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = try MemoID("423e4567-e89b-12d3-a456-426614174003")
    let secondID = try MemoID("423e4567-e89b-12d3-a456-426614174004")
    let store = try WatchMemoStore(root: root)
    try await commitTransferMemo(memoID: firstID, state: .delivered, capturedAt: Date(timeIntervalSince1970: 1), store: store)
    try await commitTransferMemo(memoID: secondID, state: .delivered, capturedAt: Date(timeIntervalSince1970: 2), store: store)
    let transport = FirstFinalAckCompletesSecondBlocksTransport(firstMemoID: firstID)
    let activityRegistry = WatchTransferActivityRegistry()
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
        activityRegistry: activityRegistry
    )

    let sync = Task { try await coordinator.syncNextStatus() }
    #expect(await transport.nextBlockingMemoID() == secondID)
    #expect(await activityRegistry.activeMemoIDs == Set([secondID]))
    let cancelledFirst = await activityRegistry.cancelIfActive(firstID) { sync.cancel() }
    #expect(!cancelledFirst)
    #expect(await activityRegistry.activeMemoIDs == Set([secondID]))

    let cancelledSecond = await activityRegistry.cancelIfActive(secondID) { sync.cancel() }
    #expect(cancelledSecond)
    await #expect(throws: CancellationError.self) {
        _ = try await sync.value
    }
    #expect(await activityRegistry.activeMemoIDs.isEmpty)
}

@Test func acceptedMemoWithMissingStatusReuploadsSameIdentityThenResumesPolling() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    try await withCoordinatorFixture(behavior: .success, now: now) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let transport = RecoveringStatusTransport()
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900),
            clock: { now }
        )

        #expect(try await coordinator.syncNextStatus() == .retryScheduled(fixture.memoID, now))
        #expect(await transport.recoveredMemoIDs == [fixture.memoID])
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .received)
    }
}

@Test func statusUnavailableIsTransientAndNeverRecoversAbsentStatusOrReuploads() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let transport = StatusUnavailableTransport()
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        await #expect(throws: WatchBridgeTransportFailure.transient) {
            _ = try await coordinator.syncNextStatus()
        }
        #expect(await transport.statusMemoIDs == [fixture.memoID])
        #expect(await transport.recoveredMemoIDs.isEmpty)
        #expect(await transport.uploadCount == 0)
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .received)
    }
}

@Test(arguments: [
    WatchBridgeTransportFailure.transient,
    .conflict,
    .permanent,
])
func finalAcknowledgementFailureIsIsolatedPerMemoAndDoesNotStarveStatus(
    _ failure: WatchBridgeTransportFailure
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-final-ack-fairness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let firstID = try MemoID("123e4567-e89b-12d3-a456-426614174001")
    let secondID = try MemoID("123e4567-e89b-12d3-a456-426614174002")
    let statusID = try MemoID("123e4567-e89b-12d3-a456-426614174003")
    let store = try WatchMemoStore(root: root)
    try await commitTransferMemo(memoID: firstID, state: .delivered, capturedAt: now, store: store)
    try await commitTransferMemo(
        memoID: secondID,
        state: .delivered,
        capturedAt: now.addingTimeInterval(1),
        store: store
    )
    try await commitTransferMemo(
        memoID: statusID,
        state: .received,
        capturedAt: now.addingTimeInterval(2),
        store: store
    )
    let firstAcknowledgement = try #require(
        try await store.pendingFinalAcknowledgements().first { $0.memoID == firstID }
    )
    let retryPolicy = try WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    let expectedRetry = retryPolicy.nextAttemptDate(
        afterAttempt: firstAcknowledgement.stateRevision,
        now: now,
        sample: 1
    )
    let transport = FinalAcknowledgementFairnessTransport(
        failingMemoID: firstID,
        failure: failure
    )
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: retryPolicy,
        clock: { now },
        randomSample: { 1 }
    )

    let outcome = try await coordinator.syncNextStatus()
    if failure == .transient {
        #expect(outcome == .retryScheduled(firstID, expectedRetry))
    } else {
        #expect(outcome == .needsAttention(firstID))
    }
    #expect(await transport.acknowledgedMemoIDs == [firstID, secondID])
    #expect(await transport.statusMemoIDs == [statusID])
    #expect(try await store.pendingFinalAcknowledgements().map(\.memoID) == [firstID])
    #expect(try await store.retryNotBefore(memoID: firstID) == expectedRetry)
    #expect(try await store.retryNotBefore(memoID: secondID) == nil)

    _ = try await coordinator.syncNextStatus()
    #expect(await transport.acknowledgedMemoIDs == [firstID, secondID])
    #expect(await transport.statusMemoIDs == [statusID, statusID])
}

@Test func finalAcknowledgementAuthenticationFailureRemainsGlobalPairingBarrier() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-final-ack-auth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = try MemoID("223e4567-e89b-12d3-a456-426614174001")
    let secondID = try MemoID("223e4567-e89b-12d3-a456-426614174002")
    let statusID = try MemoID("223e4567-e89b-12d3-a456-426614174003")
    let store = try WatchMemoStore(root: root)
    try await commitTransferMemo(memoID: firstID, state: .delivered, capturedAt: .distantPast, store: store)
    try await commitTransferMemo(memoID: secondID, state: .delivered, capturedAt: .distantPast, store: store)
    try await commitTransferMemo(memoID: statusID, state: .received, capturedAt: .distantPast, store: store)
    let transport = FinalAcknowledgementFairnessTransport(
        failingMemoID: firstID,
        failure: .authentication
    )
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )

    #expect(try await coordinator.syncNextStatus() == .pairingRequired(firstID))
    #expect(await transport.acknowledgedMemoIDs == [firstID])
    #expect(await transport.statusMemoIDs.isEmpty)
    #expect(try await store.pendingFinalAcknowledgements().map(\.memoID) == [firstID, secondID])
    #expect(try await store.pairingIsRequired())
}

@Test func statusAuthenticationFailurePreservesAcceptedMemoBehindPairingBarrier() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: FailingStatusTransport(failure: .authentication),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        #expect(try await coordinator.syncNextStatus() == .pairingRequired(fixture.memoID))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .received)
        #expect(try await fixture.store.pairingIsRequired())
    }
}

@Test func recoveryAuthenticationFailurePreservesAcceptedMemoBehindPairingBarrier() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: FailingRecoveryStatusTransport(failure: .authentication),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        #expect(try await coordinator.syncNextStatus() == .pairingRequired(fixture.memoID))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .received)
        #expect(try await fixture.store.pairingIsRequired())
    }
}

@Test func statusSyncAppliesExactAuthoritativeForwardRevisionAndTerminalState() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let transport = try StatusTransport(status: BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .needsAttention,
            stateRevision: 4,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_002)
        ))
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await coordinator.syncNextStatus() == .statusUpdated(fixture.memoID, .needsAttention))
        let stored = try await fixture.store.load(memoID: fixture.memoID).metadata
        #expect(stored.state == .needsAttention)
        #expect(stored.stateRevision == 4)
    }
}

@Test func statusSyncRejectsBackwardIdentityMismatchAndImpossibleSkipWithoutMutation() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let forward = try BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .transcribing,
            stateRevision: 3,
            updatedAt: .distantPast
        )
        let forwardCoordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: StatusTransport(status: forward),
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )
        _ = try await forwardCoordinator.syncNextStatus()
        let transcribing = try await fixture.store.load(memoID: fixture.memoID).metadata

        let responses = try [
            BridgeMemoStatus(
                memoID: fixture.memoID,
                audioSHA256: received.audioSHA256,
                state: .received,
                stateRevision: 2,
                updatedAt: .distantPast
            ),
            BridgeMemoStatus(
                memoID: MemoID("30303030-3030-3030-3030-303030303030"),
                audioSHA256: received.audioSHA256,
                state: .readyForCodex,
                stateRevision: 4,
                updatedAt: .distantPast
            ),
            BridgeMemoStatus(
                memoID: fixture.memoID,
                audioSHA256: received.audioSHA256,
                state: .received,
                stateRevision: 4,
                updatedAt: .distantPast
            ),
        ]
        for response in responses {
            let coordinator = try WatchTransferCoordinator(
                store: fixture.store,
                transport: StatusTransport(status: response),
                retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
            )
            await #expect(throws: WatchBridgeTransportFailure.permanent) {
                _ = try await coordinator.syncNextStatus()
            }
            #expect(try await fixture.store.load(memoID: fixture.memoID).metadata == transcribing)
        }
    }
}

@Test func authenticatedDeliveredStatusAloneUnlocksAgeBasedPurge() async throws {
    let deliveredAt = Date(timeIntervalSince1970: 1_700_000_010)
    try await withCoordinatorFixture(behavior: .success, clock: { deliveredAt }) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let delivered = try BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .delivered,
            stateRevision: 6,
            updatedAt: deliveredAt
        )
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: StatusTransport(status: delivered),
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await coordinator.syncNextStatus() == .statusUpdated(fixture.memoID, .delivered))
        #expect(try await fixture.store.purgeDelivered(before: deliveredAt).isEmpty)
        #expect(try await fixture.store.purgeDelivered(
            before: deliveredAt.addingTimeInterval(1)
        ) == [fixture.memoID])
    }
}

@Test func finalAcknowledgementFailurePersistsAcrossRestartAndRetriesWithoutRegressingDelivery() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let delivered = try BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .delivered,
            stateRevision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let failingTransport = FinalAcknowledgementTransport(
            status: delivered,
            acknowledgementFailure: .transient
        )
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: failingTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )

        #expect(try await coordinator.syncNextStatus() == .statusUpdated(fixture.memoID, .delivered))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .delivered)
        #expect(try await fixture.store.pendingFinalAcknowledgements().count == 1)

        let restartedStore = try WatchMemoStore(root: fixture.root)
        let succeedingTransport = FinalAcknowledgementTransport(
            status: delivered,
            acknowledgementFailure: nil
        )
        let restarted = try WatchTransferCoordinator(
            store: restartedStore,
            transport: succeedingTransport,
            retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
        )
        #expect(try await restarted.syncNextStatus() == .idle)
        #expect(try await restartedStore.pendingFinalAcknowledgements().isEmpty)
        #expect(try await restartedStore.load(memoID: fixture.memoID).metadata.state == .delivered)
        #expect(await succeedingTransport.acknowledgements.count == 1)
        #expect(await succeedingTransport.statusCallCount == 0)
    }
}

@Test func finalAcknowledgementAuthenticationFailureCreatesPairingBarrierWithoutRegressingDelivery() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let delivered = try BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .delivered,
            stateRevision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let initial = try WatchTransferCoordinator(
            store: fixture.store,
            transport: FinalAcknowledgementTransport(
                status: delivered,
                acknowledgementFailure: .transient
            ),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        _ = try await initial.syncNextStatus()
        let retrying = try WatchTransferCoordinator(
            store: fixture.store,
            transport: FinalAcknowledgementTransport(
                status: delivered,
                acknowledgementFailure: .authentication
            ),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        #expect(try await retrying.syncNextStatus() == .pairingRequired(fixture.memoID))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .delivered)
        #expect(try await fixture.store.pendingFinalAcknowledgements().count == 1)
        #expect(try await fixture.store.pairingIsRequired())
    }
}

@Test func immediateFinalAcknowledgementAuthenticationFailureCreatesPairingBarrier() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        _ = try await fixture.coordinator.uploadNext()
        let received = try await fixture.store.load(memoID: fixture.memoID).metadata
        let delivered = try BridgeMemoStatus(
            memoID: fixture.memoID,
            audioSHA256: received.audioSHA256,
            state: .delivered,
            stateRevision: 7,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let coordinator = try WatchTransferCoordinator(
            store: fixture.store,
            transport: FinalAcknowledgementTransport(
                status: delivered,
                acknowledgementFailure: .authentication
            ),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )

        #expect(try await coordinator.syncNextStatus() == .pairingRequired(fixture.memoID))
        #expect(try await fixture.store.load(memoID: fixture.memoID).metadata.state == .delivered)
        #expect(try await fixture.store.pendingFinalAcknowledgements().count == 1)
        #expect(try await fixture.store.pairingIsRequired())
    }
}

@Test func unsafeRetrySymlinkIsQuarantinedWithoutBlockingUploadOrTouchingTarget() async throws {
    try await withCoordinatorFixture(behavior: .success) { fixture in
        let outside = fixture.root.appendingPathComponent("external.retry")
        try Data("do not touch".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: outside.path
        )
        let retry = fixture.root
            .appendingPathComponent("Retry", isDirectory: true)
            .appendingPathComponent("\(fixture.memoID.rawValue).retry")
        try FileManager.default.createSymbolicLink(at: retry, withDestinationURL: outside)

        #expect(try await fixture.coordinator.uploadNext() == .received(fixture.memoID))
        #expect(try Data(contentsOf: outside) == Data("do not touch".utf8))
        #expect(try permissions(of: outside) == 0o644)
        #expect(try await fixture.store.quarantinedEntryNames().contains {
            $0.hasPrefix("\(fixture.memoID.rawValue).retry.retry.")
        })
    }
}

@Test func uploadSelectionDoesNotHashOrQuarantineUnselectedQueueAudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-selection-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstID = try MemoID("723e4567-e89b-12d3-a456-426614174000")
    let secondID = try MemoID("823e4567-e89b-12d3-a456-426614174000")
    let thirdID = try MemoID("923e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)

    let firstRecording = await store.temporaryRecordingURL(for: firstID)
    try Data("first".utf8).write(to: firstRecording)
    _ = try await store.commitRecording(
        temporaryURL: firstRecording,
        memoID: firstID,
        capturedAt: Date(timeIntervalSince1970: 1),
        durationMilliseconds: 100,
        localeHint: nil
    )
    let secondRecording = await store.temporaryRecordingURL(for: secondID)
    try Data("second".utf8).write(to: secondRecording)
    let second = try await store.commitRecording(
        temporaryURL: secondRecording,
        memoID: secondID,
        capturedAt: Date(timeIntervalSince1970: 2),
        durationMilliseconds: 100,
        localeHint: nil
    )
    let thirdRecording = await store.temporaryRecordingURL(for: thirdID)
    try Data("third".utf8).write(to: thirdRecording)
    _ = try await store.commitRecording(
        temporaryURL: thirdRecording,
        memoID: thirdID,
        capturedAt: Date(timeIntervalSince1970: 3),
        durationMilliseconds: 100,
        localeHint: nil
    )
    try Data("broken".utf8).write(to: second.audioURL)

    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: StubTransport(behavior: .success),
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )
    #expect(try await coordinator.uploadNext() == .received(firstID))
    #expect(FileManager.default.fileExists(atPath: second.audioURL.path))
    #expect(try await store.quarantinedEntryNames().isEmpty)
    #expect(try await coordinator.uploadNext() == .received(thirdID))
    #expect(try await store.quarantinedEntryNames().contains {
        $0.hasPrefix("\(secondID.rawValue).m4a.corrupt.")
    })
}

@Test(arguments: [WatchBridgeTransportFailure.conflict, .permanent])
func permanentFailuresPersistNeedsAttention(_ failure: WatchBridgeTransportFailure) async throws {
    try await withCoordinatorFixture(behavior: .failure(failure)) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(outcome == .needsAttention(fixture.memoID))
        #expect(stored.metadata.state == .needsAttention)
        #expect(stored.metadata.stateRevision == 2)
    }
}

@Test func mismatchedReceiptFailsClosedAsNeedsAttention() async throws {
    try await withCoordinatorFixture(behavior: .mismatchedReceipt) { fixture in
        let outcome = try await fixture.coordinator.uploadNext()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(outcome == .needsAttention(fixture.memoID))
        #expect(stored.metadata.state == .needsAttention)
    }
}

@Test func concurrentUploadAttemptReturnsBusyWhileTransportIsSuspended() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-busy-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoID = try MemoID("523e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("voice".utf8).write(to: temporary)
    _ = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        durationMilliseconds: 100,
        localeHint: nil
    )
    let transport = BlockingTransport()
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )

    let first = Task { try await coordinator.uploadNext() }
    await transport.waitUntilStarted()
    #expect(try await coordinator.uploadNext() == .busy)
    await transport.release()
    #expect(try await first.value == .received(memoID))
}

@Test func logicalUploadLeaseBlocksSecondCoordinatorRecoveryAndLocalMutation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-lease-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoID = try MemoID("623e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)
    let temporary = await store.temporaryRecordingURL(for: memoID)
    let audio = Data("leased voice".utf8)
    try audio.write(to: temporary)
    let committed = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        durationMilliseconds: 100,
        localeHint: nil
    )
    let blockingTransport = BlockingTransport()
    let firstCoordinator = try WatchTransferCoordinator(
        store: store,
        transport: blockingTransport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )
    let recoveryTransport = StubTransport(behavior: .success)
    let secondCoordinator = try WatchTransferCoordinator(
        store: store,
        transport: recoveryTransport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )

    let firstUpload = Task { try await firstCoordinator.uploadNext() }
    await blockingTransport.waitUntilStarted()
    let leased = try await store.load(memoID: memoID)
    #expect(leased.metadata.state == .uploading)

    #expect(try await secondCoordinator.uploadNext() == .idle)
    #expect(await recoveryTransport.callCount == 0)
    await #expect(throws: WatchMemoStoreError.invalidState) {
        _ = try await store.transition(memoID: memoID, to: .saved)
    }
    await #expect(throws: WatchMemoStoreError.invalidState) {
        try await store.deleteLocal(memoID: memoID)
    }
    await #expect(throws: WatchMemoStoreError.invalidState) {
        _ = try await store.reconcileAuthoritative(
            memoID: memoID,
            state: .delivered,
            revision: 8
        )
    }
    #expect(try await store.purgeDelivered(before: .distantFuture).isEmpty)

    let replacement = await store.temporaryRecordingURL(for: memoID)
    try Data("replacement".utf8).write(to: replacement)
    await #expect(throws: WatchMemoStoreError.invalidState) {
        _ = try await store.commitRecording(
            temporaryURL: replacement,
            memoID: memoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationMilliseconds: 200,
            localeHint: "pl-PL"
        )
    }
    #expect(try Data(contentsOf: replacement) == Data("replacement".utf8))
    #expect(try await store.load(memoID: memoID) == leased)
    #expect(FileManager.default.fileExists(atPath: committed.audioURL.path))
    #expect(FileManager.default.fileExists(atPath: committed.metadataURL.path))
    #expect(try Data(contentsOf: committed.audioURL) == audio)

    await blockingTransport.release()
    #expect(try await firstUpload.value == .received(memoID))
    for state in [
        MemoState.transcribing, .readyForCodex, .inserting, .delivered,
    ] {
        _ = try await store.transition(memoID: memoID, to: state)
    }
    #expect(try await store.purgeDelivered(before: .distantFuture) == [memoID])
    #expect(!FileManager.default.fileExists(atPath: committed.audioURL.path))
    #expect(!FileManager.default.fileExists(atPath: committed.metadataURL.path))
}

@Test func cancellationReleasesLogicalUploadLeaseBeforeRestoringSavedState() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-cancel-lease-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoID = try MemoID("723e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("cancelled voice".utf8).write(to: temporary)
    let committed = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        durationMilliseconds: 100,
        localeHint: nil
    )
    let transport = BlockingTransport()
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30)
    )

    let upload = Task { try await coordinator.uploadNext() }
    await transport.waitUntilStarted()
    upload.cancel()
    await transport.release()
    await #expect(throws: CancellationError.self) {
        _ = try await upload.value
    }

    let restored = try await store.load(memoID: memoID)
    #expect(restored.metadata.state == .saved)
    #expect(restored.metadata.stateRevision == 2)
    try await store.deleteLocal(memoID: memoID)
    #expect(!FileManager.default.fileExists(atPath: committed.audioURL.path))
    #expect(!FileManager.default.fileExists(atPath: committed.metadataURL.path))
}

@Test func transientFinalizationPublishesBackoffBeforeAnotherCoordinatorCanUpload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-transient-finalization-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let retryDate = now.addingTimeInterval(2)
    let memoID = try MemoID("823e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("transient voice".utf8).write(to: temporary)
    _ = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: now,
        durationMilliseconds: 100,
        localeHint: nil
    )
    let checkpoint = TransientFinalizationCheckpoint()
    let firstTransport = StubTransport(behavior: .failure(.transient))
    let firstCoordinator = try WatchTransferCoordinator(
        store: store,
        transport: firstTransport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
        clock: { now },
        randomSample: { 1 },
        transientFinalizationCheckpoint: { await checkpoint.pause() }
    )
    let secondTransport = StubTransport(behavior: .success)
    let secondCoordinator = try WatchTransferCoordinator(
        store: store,
        transport: secondTransport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
        clock: { now },
        randomSample: { 1 }
    )

    let firstUpload = Task { try await firstCoordinator.uploadNext() }
    await checkpoint.waitUntilPaused()
    #expect(try await secondCoordinator.uploadNext() == .retryScheduled(memoID, retryDate))
    #expect(await secondTransport.callCount == 0)
    await checkpoint.release()
    #expect(try await firstUpload.value == .retryScheduled(memoID, retryDate))
    #expect(try await store.load(memoID: memoID).metadata.state == .saved)
    #expect(try await store.retryNotBefore(memoID: memoID) == retryDate)
}

@Test func retryPolicyUsesFullJitterSamplesAcrossBoundedExponentialWindows() throws {
    let policy = try WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
    let now = Date(timeIntervalSince1970: 100)

    #expect(policy.nextAttemptDate(afterAttempt: 0, now: now, sample: 0) == now)
    #expect(policy.nextAttemptDate(afterAttempt: 0, now: now, sample: 0.5) == now.addingTimeInterval(2.5))
    #expect(policy.nextAttemptDate(afterAttempt: 0, now: now, sample: 1) == now.addingTimeInterval(5))
    #expect(policy.nextAttemptDate(afterAttempt: 1, now: now, sample: 0.5) == now.addingTimeInterval(5))
    #expect(policy.nextAttemptDate(afterAttempt: 8, now: now, sample: 1) == now.addingTimeInterval(900))
}

private enum TransportBehavior: Sendable {
    case success
    case existingReceipt(revision: UInt64)
    case mismatchedReceipt
    case failure(WatchBridgeTransportFailure)
    case unknownFailure
    case malformedSuccessfulResponse
}

private actor StubTransport: WatchBridgeTransport {
    private let behavior: TransportBehavior
    private(set) var callCount = 0

    init(behavior: TransportBehavior) {
        self.behavior = behavior
    }

    func upload(
        memo: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        callCount += 1
        switch behavior {
        case .success:
            return try BridgeReceipt(
                memoID: memo.memoID,
                audioSHA256: memo.audioSHA256,
                acknowledgedRevision: expectedRevision,
                capturedAt: memo.capturedAt,
                localeHint: memo.localeHint,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        case let .existingReceipt(revision):
            return try BridgeReceipt(
                memoID: memo.memoID,
                audioSHA256: memo.audioSHA256,
                acknowledgedRevision: revision,
                capturedAt: memo.capturedAt,
                localeHint: memo.localeHint,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        case .mismatchedReceipt:
            return try BridgeReceipt(
                memoID: MemoID("323e4567-e89b-12d3-a456-426614174000"),
                audioSHA256: memo.audioSHA256,
                acknowledgedRevision: expectedRevision,
                capturedAt: memo.capturedAt,
                localeHint: memo.localeHint,
                receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        case let .failure(failure):
            throw failure
        case .unknownFailure:
            throw UnknownTransportError()
        case .malformedSuccessfulResponse:
            return try BridgeUploadResponseDecoder.receipt(
                statusCode: 201,
                body: Data(#"{"payload":"#.utf8)
            )
        }
    }
}

private struct UnknownTransportError: Error {}

private actor BlockingTransport: WatchBridgeTransport {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func upload(
        memo: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try Task.checkCancellation()
        return try BridgeReceipt(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            acknowledgedRevision: expectedRevision,
            capturedAt: memo.capturedAt,
            localeHint: memo.localeHint,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }
}

private actor TransientFinalizationCheckpoint {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }
}

private actor StatusTransport: WatchBridgeTransport {
    let statusResponse: BridgeMemoStatus
    init(status: BridgeMemoStatus) { statusResponse = status }

    func upload(memo _: VoiceMemoMetadata, audioURL _: URL, expectedRevision _: UInt64) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        statusResponse
    }
}

private actor FirstStatusCompletesSecondBlocksTransport: WatchBridgeTransport {
    private let firstMemoID: MemoID
    private var blockingMemoIDs: [MemoID] = []
    private var blockingWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var continuation: CheckedContinuation<BridgeMemoStatus, any Error>?

    init(firstMemoID: MemoID) {
        self.firstMemoID = firstMemoID
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        if memo.memoID == firstMemoID {
            return try identicalStatus(for: memo)
        }
        signalBlocking(memo.memoID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func nextBlockingMemoID() async -> MemoID {
        if !blockingMemoIDs.isEmpty {
            return blockingMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            blockingWaiters.append(continuation)
        }
    }

    private func signalBlocking(_ memoID: MemoID) {
        if blockingWaiters.isEmpty {
            blockingMemoIDs.append(memoID)
        } else {
            blockingWaiters.removeFirst().resume(returning: memoID)
        }
    }

    private func identicalStatus(for memo: VoiceMemoMetadata) throws -> BridgeMemoStatus {
        try BridgeMemoStatus(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            state: memo.state,
            stateRevision: memo.stateRevision,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor FirstFinalAckCompletesSecondBlocksTransport: WatchBridgeTransport {
    private let firstMemoID: MemoID
    private var blockingMemoIDs: [MemoID] = []
    private var blockingWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var continuation: CheckedContinuation<Void, any Error>?

    init(firstMemoID: MemoID) {
        self.firstMemoID = firstMemoID
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        guard acknowledgement.memoID != firstMemoID else { return }
        signalBlocking(acknowledgement.memoID)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func signalBlocking(_ memoID: MemoID) {
        if blockingWaiters.isEmpty {
            blockingMemoIDs.append(memoID)
        } else {
            blockingWaiters.removeFirst().resume(returning: memoID)
        }
    }

    func nextBlockingMemoID() async -> MemoID {
        if !blockingMemoIDs.isEmpty {
            return blockingMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            blockingWaiters.append(continuation)
        }
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor RecoveringStatusTransport: WatchBridgeTransport {
    private(set) var recoveredMemoIDs: [MemoID] = []

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        throw WatchBridgeTransportFailure.statusAbsent
    }

    func recoverAbsentStatus(memo: VoiceMemoMetadata, audioURL _: URL) async throws {
        recoveredMemoIDs.append(memo.memoID)
    }
}

private actor FailingStatusTransport: WatchBridgeTransport {
    let failure: WatchBridgeTransportFailure

    init(failure: WatchBridgeTransportFailure) {
        self.failure = failure
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        throw failure
    }
}

private actor StatusUnavailableTransport: WatchBridgeTransport {
    private(set) var statusMemoIDs: [MemoID] = []
    private(set) var recoveredMemoIDs: [MemoID] = []
    private(set) var uploadCount = 0

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        uploadCount += 1
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        statusMemoIDs.append(memo.memoID)
        throw WatchBridgeTransportFailure.transient
    }

    func recoverAbsentStatus(memo: VoiceMemoMetadata, audioURL _: URL) async throws {
        recoveredMemoIDs.append(memo.memoID)
    }
}

private actor FinalAcknowledgementFairnessTransport: WatchBridgeTransport {
    let failingMemoID: MemoID
    let failure: WatchBridgeTransportFailure
    private(set) var acknowledgedMemoIDs: [MemoID] = []
    private(set) var statusMemoIDs: [MemoID] = []

    init(failingMemoID: MemoID, failure: WatchBridgeTransportFailure) {
        self.failingMemoID = failingMemoID
        self.failure = failure
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        statusMemoIDs.append(memo.memoID)
        return try BridgeMemoStatus(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            state: memo.state,
            stateRevision: memo.stateRevision,
            updatedAt: .distantPast
        )
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        acknowledgedMemoIDs.append(acknowledgement.memoID)
        if acknowledgement.memoID == failingMemoID { throw failure }
    }
}

private actor FailingRecoveryStatusTransport: WatchBridgeTransport {
    let failure: WatchBridgeTransportFailure

    init(failure: WatchBridgeTransportFailure) {
        self.failure = failure
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        throw WatchBridgeTransportFailure.statusAbsent
    }

    func recoverAbsentStatus(memo _: VoiceMemoMetadata, audioURL _: URL) async throws {
        throw failure
    }
}

private actor FinalAcknowledgementTransport: WatchBridgeTransport {
    let statusResponse: BridgeMemoStatus
    let acknowledgementFailure: WatchBridgeTransportFailure?
    private(set) var acknowledgements: [FinalDeliveryAcknowledgement] = []
    private(set) var statusCallCount = 0

    init(status: BridgeMemoStatus, acknowledgementFailure: WatchBridgeTransportFailure?) {
        statusResponse = status
        self.acknowledgementFailure = acknowledgementFailure
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        statusCallCount += 1
        return statusResponse
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        acknowledgements.append(acknowledgement)
        if let acknowledgementFailure { throw acknowledgementFailure }
    }
}

private struct CoordinatorFixture: Sendable {
    let root: URL
    let memoID: MemoID
    let store: WatchMemoStore
    let transport: StubTransport
    let coordinator: WatchTransferCoordinator
}

private func withCoordinatorFixture(
    behavior: TransportBehavior,
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    clock: @escaping @Sendable () -> Date = Date.init,
    _ body: (CoordinatorFixture) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-transfer-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoID = try MemoID("423e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root, clock: clock)
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("voice".utf8).write(to: temporary)
    _ = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: now,
        durationMilliseconds: 100,
        localeHint: nil
    )
    let transport = StubTransport(behavior: behavior)
    let coordinator = try WatchTransferCoordinator(
        store: store,
        transport: transport,
        retryPolicy: WatchRetryPolicy(baseDelay: 2, maximumDelay: 30),
        clock: { now },
        randomSample: { 1 }
    )
    try await body(.init(
        root: root,
        memoID: memoID,
        store: store,
        transport: transport,
        coordinator: coordinator
    ))
}

private func commitTransferMemo(
    memoID: MemoID,
    state: MemoState,
    capturedAt: Date,
    store: WatchMemoStore
) async throws {
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("voice-\(memoID.rawValue)".utf8).write(to: temporary)
    _ = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: capturedAt,
        durationMilliseconds: 100,
        localeHint: nil
    )
    guard state != .saved else { return }
    for transition in [
        MemoState.uploading, .received, .transcribing,
        .readyForCodex, .inserting, .reconciling, .delivered,
    ] {
        _ = try await store.transition(memoID: memoID, to: transition)
        if transition == state { return }
    }
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
