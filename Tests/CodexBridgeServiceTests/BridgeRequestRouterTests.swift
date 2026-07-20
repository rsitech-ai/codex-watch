import CodexBridgeDelivery
@testable import CodexBridgeService
import CodexBridgeShared
import CryptoKit
import Foundation
import Testing

private let routerMemoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")
private let routerNow = Date(timeIntervalSince1970: 1_700_000_000)
private let routerToken = Data(repeating: 0x33, count: 32)

@Test func routerRedeemsWatchPairingCodeIntoVersionedTokenResponse() async throws {
    let fixture = try await RouterFixture()
    let request = try makePairingHTTPRequest(code: "123456")

    let response = await fixture.router.route(request)
    let pairing = try JSONDecoder().decode(PairingRedemptionResponse.self, from: response.body)

    #expect(response.status == 200)
    #expect(response.headers["content-type"] == "application/json")
    #expect(pairing.token == String(repeating: "33", count: 32))
}

@Test func routerPairingRedemptionIsOneUseAndHidesFailureReason() async throws {
    let fixture = try await RouterFixture()
    let invalid = try await fixture.router.route(makePairingHTTPRequest(code: "000000"))
    let accepted = try await fixture.router.route(makePairingHTTPRequest(code: "123456"))
    let replayed = try await fixture.router.route(makePairingHTTPRequest(code: "123456"))

    #expect(invalid.status == 401)
    #expect(accepted.status == 200)
    #expect(replayed.status == 401)
    #expect(invalid.body == replayed.body)
    #expect(invalid.body == Data("{\"error\":\"pairing_failed\"}".utf8))
}

@Test func routerRateLimitsPairingAttemptsWithoutRevealingCodeValidity() async throws {
    let clock = RouterClock(routerNow)
    let fixture = try await RouterFixture(
        clock: clock.now,
        pairingAttemptLimit: 2,
        rateLimitWindow: 60
    )

    #expect(try await fixture.router.route(makePairingHTTPRequest(code: "000000")).status == 401)
    #expect(try await fixture.router.route(makePairingHTTPRequest(code: "000001")).status == 401)
    let limited = try await fixture.router.route(makePairingHTTPRequest(code: "123456"))

    #expect(limited.status == 429)
    #expect(limited.headers["retry-after"] == "60")
    #expect(limited.body == Data("{\"error\":\"pairing_failed\"}".utf8))

    clock.advance(by: 61)
    #expect(try await fixture.router.route(makePairingHTTPRequest(code: "123456")).status == 200)
}

@Test func routerRejectsMalformedPairingEnvelopeBeforeRedemption() async throws {
    let fixture = try await RouterFixture()
    let body = try JSONEncoder().encode(PairingRedemptionRequest(code: "123456"))
    let request = HTTPRequest(
        method: "POST",
        path: "/v1/pair",
        headers: [
            "content-length": String(body.count),
            "content-type": "text/plain",
            "host": "localhost",
            "x-codex-version": "1",
        ],
        body: body
    )

    let response = await fixture.router.route(request)

    #expect(response.status == 400)
    #expect(response.body == Data("{\"error\":\"invalid_request\"}".utf8))
}

@Test func routerAuthenticatesAndDurablyAcknowledgesAnUpload() async throws {
    let fixture = try await RouterFixture()
    let body = Data("authenticated-audio".utf8)
    let request = try makeSignedHTTPRequest(body: body, nonce: "nonce-1")

    let response = await fixture.router.route(request)
    let envelope = try JSONDecoder().decode(BridgeEnvelope<BridgeReceipt>.self, from: response.body)

    #expect(response.status == 201)
    #expect(envelope.payload.memoID == routerMemoID)
    #expect(envelope.payload.audioSHA256 == AudioDigest.hex(body))
    #expect(try await fixture.intake.audio(for: routerMemoID) == body)
    #expect(try await fixture.finalStatuses.occupiedCount() == 1)
}

@Test func routerPreparesAuthenticatedUploadFromHeadWithoutBodyBytes() async throws {
    let fixture = try await RouterFixture()
    let body = Data("prepared-audio".utf8)
    let request = try makeSignedHTTPRequest(body: body, nonce: "prepared-head")
    let head = HTTPRequestHead(
        method: request.method,
        path: request.path,
        headers: request.headers,
        contentLength: body.count
    )

    switch await fixture.router.prepare(head) {
    case let .upload(upload):
        #expect(upload.head == head)
        #expect(upload.intakeRequest.memoID == routerMemoID)
        #expect(upload.intakeRequest.audioSHA256 == AudioDigest.hex(body))
        #expect(upload.intakeRequest.byteCount == body.count)
    case .reject, .buffered:
        Issue.record("Expected an authenticated streaming upload")
    }
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
}

@Test func routerRateLimitsAuthenticatedUploadsAndRecoversAfterTheWindow() async throws {
    let clock = RouterClock(routerNow)
    let fixture = try await RouterFixture(
        clock: clock.now,
        uploadRequestLimit: 2,
        rateLimitWindow: 60
    )
    let body = Data("rate-limited-audio".utf8)

    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: body, nonce: "rate-1")).status == 201)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: body, nonce: "rate-2")).status == 200)
    let limited = try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "rate-3")
    )

    #expect(limited.status == 429)
    #expect(limited.headers["retry-after"] == "60")
    #expect(limited.body == Data("{\"error\":\"rate_limited\"}".utf8))

    clock.advance(by: 61)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(
        body: body,
        nonce: "rate-4",
        timestamp: 1_700_000_061
    )).status == 200)
}

@Test func routerRejectsBeforeIntakeCommitWhenAvailableDiskIsBelowAdmissionFloor() async throws {
    let fixture = try await RouterFixture(minimumAvailableBytes: 100, availableBytes: { 99 })
    let response = try await fixture.router.route(makeSignedHTTPRequest(body: Data("disk-gate".utf8), nonce: "disk-gate"))

    #expect(response.status == 503)
    #expect(response.body == Data("{\"error\":\"disk_pressure\"}".utf8))
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
}

@Test func routerRejectsSaturatedTerminalCapacityBeforeIntakeAcceptance() async throws {
    let fixture = try await RouterFixture(finalStatusCapacity: 1)
    let occupyingMemoID = try MemoID("91919191-9191-9191-9191-919191919191")
    try await fixture.finalStatuses.publish(FinalDeliveryReceipt(
        memoID: occupyingMemoID,
        audioSHA256: AudioDigest.hex(Data("occupied".utf8)),
        stateRevision: 8,
        deliveredAt: routerNow
    ))

    let response = try await fixture.router.route(makeSignedHTTPRequest(
        body: Data("capacity-rejected".utf8),
        nonce: "terminal-capacity"
    ))

    #expect(response.status == 503)
    #expect(response.body == Data("{\"error\":\"terminal_capacity\"}".utf8))
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
    #expect(try await fixture.finalStatuses.occupiedCount() == 1)
}

@Test func routerReleasesItsCapacityLeaseWhenStreamingDigestValidationFails() async throws {
    let fixture = try await RouterFixture(finalStatusCapacity: 1)
    let signed = try makeSignedHTTPRequest(body: Data("expected-body".utf8), nonce: "bad-body")
    let request = HTTPRequest(
        method: signed.method,
        path: signed.path,
        headers: signed.headers,
        body: Data("tampered-body".utf8)
    )

    #expect(await fixture.router.route(request).status == 422)
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
    #expect(try await fixture.finalStatuses.occupiedCount() == 0)
}

@Test func routerReleasesItsCapacityLeaseWhenWriterCreationFails() async throws {
    let fixture = try await RouterFixture(finalStatusCapacity: 1)
    try FileManager.default.removeItem(at: fixture.intakeRoot)

    let response = try await fixture.router.route(makeSignedHTTPRequest(
        body: Data("writer-creation".utf8),
        nonce: "writer-creation"
    ))

    #expect(response.status == 500)
    #expect(response.body == Data("{\"error\":\"intake_unavailable\"}".utf8))
    #expect(try await fixture.finalStatuses.occupiedCount() == 0)
}

@Test func routerAcknowledgesDurableCommitBeforeAsynchronouslyEnqueuingItForOwnedProcessing() async throws {
    let admitted = AdmittedRecordRecorder()
    let fixture = try await RouterFixture(onCommitted: { record in
        await admitted.record(record)
    })
    let body = Data("enqueue-after-commit".utf8)

    let response = try await fixture.router.route(makeSignedHTTPRequest(body: body, nonce: "enqueue"))

    #expect(response.status == 201)
    #expect(try await fixture.intake.audio(for: routerMemoID) == body)
    for _ in 0 ..< 20 where await admitted.records.isEmpty {
        await Task.yield()
    }
    #expect(await admitted.records.map(\.memoID) == [routerMemoID])
}

@Test func routerReadmitsDurableDuplicateAfterReservationCommitFailureWithoutRestart() async throws {
    let admitted = AdmittedRecordRecorder()
    let writeFault = FailSelectedFinalStatusWrite(ordinal: 2)
    let fixture = try await RouterFixture(
        onCommitted: { record in await admitted.record(record) },
        finalStatusFaultInjector: writeFault.inject
    )
    let body = Data("durable-before-reservation-commit".utf8)

    let first = try await fixture.router.route(makeSignedHTTPRequest(
        body: body,
        nonce: "reservation-commit-failure"
    ))
    #expect(first.status == 500)
    #expect(first.body == Data("{\"error\":\"status_unavailable\"}".utf8))
    #expect(try await fixture.intake.audio(for: routerMemoID) == body)

    let retry = try await fixture.router.route(makeSignedHTTPRequest(
        body: body,
        nonce: "reservation-commit-retry"
    ))
    #expect(retry.status == 200)
    for _ in 0 ..< 20 where await admitted.records.count < 2 {
        await Task.yield()
    }
    #expect(await admitted.records.map(\.memoID) == [routerMemoID, routerMemoID])
    #expect(try await fixture.finalStatuses.occupiedCount() == 1)
}

@Test func routerRejectsMissingOrUnsignedCaptureMetadataBeforeIntakeCommit() async throws {
    let fixture = try await RouterFixture()
    let body = Data("authenticated-audio".utf8)
    let signed = try makeSignedHTTPRequest(body: body, nonce: "missing-capture")
    var headers = signed.headers
    headers["x-codex-captured-at"] = nil
    let missingCapture = HTTPRequest(
        method: signed.method,
        path: signed.path,
        headers: headers,
        body: signed.body
    )

    #expect(await fixture.router.route(missingCapture).status == 400)
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
}

@Test func routerRejectsInvalidHMACExpiredTimestampAndReplayBeforeMutation() async throws {
    let fixture = try await RouterFixture()
    let body = Data("authenticated-audio".utf8)
    var invalid = try makeSignedHTTPRequest(body: body, nonce: "bad-signature")
    invalid = HTTPRequest(
        method: invalid.method,
        path: invalid.path,
        headers: invalid.headers.merging(["x-codex-signature": String(repeating: "0", count: 64)]) { _, new in new },
        body: invalid.body
    )
    #expect(await fixture.router.route(invalid).status == 401)
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)

    let expired = try makeSignedHTTPRequest(body: body, nonce: "expired", timestamp: 1_699_999_000)
    #expect(await fixture.router.route(expired).status == 401)
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)

    let valid = try makeSignedHTTPRequest(body: body, nonce: "one-use")
    #expect(await fixture.router.route(valid).status == 201)
    #expect(await fixture.router.route(valid).status == 401)
}

@Test func routerReturnsAuthUnavailableWhenReplayPersistenceFailsWithoutMemoryFallback() async throws {
    let fixture = try await RouterFixture(replayStore: FailingReplayNonceStore())
    let request = try makeSignedHTTPRequest(body: Data("replay-failure".utf8), nonce: "persistence-failure")

    let response = await fixture.router.route(request)

    #expect(response.status == 503)
    #expect(response.body == Data("{\"error\":\"auth_unavailable\"}".utf8))
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
}

@Test func routerReturnsAuthUnavailableForFinalAcknowledgementWhenReplayPersistenceFails() async throws {
    let fixture = try await RouterFixture(replayStore: FailingReplayNonceStore())
    let acknowledgement = FinalDeliveryAcknowledgement(
        memoID: routerMemoID,
        audioSHA256: String(repeating: "a", count: 64),
        stateRevision: 1
    )

    let response = try await fixture.router.route(
        makeSignedFinalAcknowledgementHTTPRequest(acknowledgement, nonce: "final-auth-unavailable")
    )

    #expect(response.status == 503)
    #expect(response.body == Data("{\"error\":\"auth_unavailable\"}".utf8))
}

@Test func routerMapsDuplicateToOKAndIdentityConflictToConflict() async throws {
    let fixture = try await RouterFixture()
    let original = Data("original".utf8)
    let different = Data("different".utf8)

    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: original, nonce: "first")).status == 201)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: original, nonce: "duplicate")).status == 200)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: different, nonce: "conflict")).status == 409)
}

@Test func routerRejectsBearerAndBodyDigestMismatchWithoutLeakingMemoExistence() async throws {
    let fixture = try await RouterFixture()
    let body = Data("audio".utf8)
    let valid = try makeSignedHTTPRequest(body: body, nonce: "auth")
    var headers = valid.headers
    headers["authorization"] = "Bearer " + String(repeating: "00", count: 32)
    let wrongBearer = HTTPRequest(method: valid.method, path: valid.path, headers: headers, body: body)
    #expect(await fixture.router.route(wrongBearer).status == 401)

    let wrongDigest = try makeSignedHTTPRequest(
        body: body,
        nonce: "signed-wrong-digest",
        signedDigest: String(repeating: "f", count: 64)
    )
    #expect(await fixture.router.route(wrongDigest).status == 422)
    #expect(try await fixture.intake.receipt(for: routerMemoID) == nil)
}

@Test func routerReturnsAuthenticatedStatusWithAbsoluteRevisionAndTruthfulTimestamp() async throws {
    let fixture = try await RouterFixture()
    let body = Data("status-audio".utf8)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: body, nonce: "status-upload")).status == 201)
    let receipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.journal.create(.received(
        memoID: routerMemoID,
        capturedAt: receipt.capturedAt,
        localeHint: receipt.localeHint,
        audioSHA256: receipt.audioSHA256,
        updatedAt: routerNow
    ))

    let identical = try await fixture.router.route(makeSignedStatusHTTPRequest(nonce: "status-0", revision: 2))
    let initial = try JSONDecoder().decode(BridgeEnvelope<BridgeMemoStatus>.self, from: identical.body).payload
    #expect(identical.status == 200)
    #expect(initial.state == .received)
    #expect(initial.stateRevision == 2)
    #expect(initial.updatedAt == routerNow)

    let progressedAt = routerNow.addingTimeInterval(1)
    let progressingJournal = try DeliveryJournal(root: fixture.journalRoot, clock: { progressedAt })
    _ = try progressingJournal.transition(memoID: routerMemoID, to: .transcribing)
    let progressed = try await fixture.router.route(makeSignedStatusHTTPRequest(nonce: "status-1", revision: 2))
    let status = try JSONDecoder().decode(BridgeEnvelope<BridgeMemoStatus>.self, from: progressed.body).payload
    #expect(status.state == .transcribing)
    #expect(status.stateRevision == 3)
    #expect(status.updatedAt == progressedAt)

    _ = try progressingJournal.transition(memoID: routerMemoID, to: .needsAttention)
    let terminal = try await fixture.router.route(makeSignedStatusHTTPRequest(nonce: "status-terminal", revision: 3))
    let terminalStatus = try JSONDecoder().decode(BridgeEnvelope<BridgeMemoStatus>.self, from: terminal.body).payload
    #expect(terminalStatus.state == .needsAttention)
    #expect(terminalStatus.stateRevision == 4)
}

@Test func routerStatusFailsClosedForAuthReplayUnknownAndIdentityMismatch() async throws {
    let fixture = try await RouterFixture()
    let body = Data("status-audio".utf8)
    #expect(try await fixture.router.route(makeSignedHTTPRequest(body: body, nonce: "status-upload")).status == 201)
    let receipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.journal.create(.received(
        memoID: routerMemoID,
        capturedAt: receipt.capturedAt,
        localeHint: receipt.localeHint,
        audioSHA256: String(repeating: "f", count: 64),
        updatedAt: routerNow
    ))
    let mismatch = try await fixture.router.route(makeSignedStatusHTTPRequest(nonce: "mismatch", revision: 2))
    #expect(mismatch.status == 503)
    #expect(mismatch.body == Data("{\"error\":\"status_unavailable\"}".utf8))

    let replay = try makeSignedStatusHTTPRequest(nonce: "replay", revision: 2)
    #expect(await fixture.router.route(replay).status == 503)
    #expect(await fixture.router.route(replay).status == 401)

    var badBearer = try makeSignedStatusHTTPRequest(nonce: "bad-bearer", revision: 2)
    badBearer = HTTPRequest(method: badBearer.method, path: badBearer.path, headers: badBearer.headers.merging([
        "authorization": "Bearer " + String(repeating: "00", count: 32),
    ]) { _, new in new }, body: Data())
    #expect(await fixture.router.route(badBearer).status == 401)

    let expired = try makeSignedStatusHTTPRequest(
        nonce: "expired-status",
        revision: 2,
        timestamp: 1_699_999_000
    )
    #expect(await fixture.router.route(expired).status == 401)

    let unknownID = try MemoID("99999999-9999-9999-9999-999999999999")
    let absent = try await fixture.router.route(makeSignedStatusHTTPRequest(
        nonce: "unknown", revision: 2, memoID: unknownID
    ))
    #expect(absent.status == 404)
    #expect(absent.body == Data("{\"error\":\"status_absent\"}".utf8))
}

@Test func routerStatusReturnsUnavailableForCorruptActiveIntakeJournalAndFinalReceipt() async throws {
    let body = Data("status-corruption-audio".utf8)

    let corruptIntake = try await RouterFixture()
    #expect(try await corruptIntake.router.route(
        makeSignedHTTPRequest(body: body, nonce: "corrupt-intake-upload")
    ).status == 201)
    try Data("not-json".utf8).write(
        to: corruptIntake.intakeRoot
            .appending(path: routerMemoID.rawValue, directoryHint: .isDirectory)
            .appending(path: "receipt.json", directoryHint: .notDirectory)
    )
    let intakeResponse = try await corruptIntake.router.route(
        makeSignedStatusHTTPRequest(nonce: "corrupt-intake-status", revision: 2)
    )
    #expect(intakeResponse.status == 503)
    #expect(intakeResponse.body == Data("{\"error\":\"status_unavailable\"}".utf8))

    let corruptJournal = try await RouterFixture()
    #expect(try await corruptJournal.router.route(
        makeSignedHTTPRequest(body: body, nonce: "corrupt-journal-upload")
    ).status == 201)
    let receipt = try #require(try await corruptJournal.intake.receipt(for: routerMemoID))
    try corruptJournal.journal.create(.received(
        memoID: routerMemoID,
        capturedAt: receipt.capturedAt,
        localeHint: receipt.localeHint,
        audioSHA256: receipt.audioSHA256,
        updatedAt: routerNow
    ))
    try Data("not-json".utf8).write(
        to: corruptJournal.journalRoot.appending(path: "\(routerMemoID.rawValue).json")
    )
    let journalResponse = try await corruptJournal.router.route(
        makeSignedStatusHTTPRequest(nonce: "corrupt-journal-status", revision: 2)
    )
    #expect(journalResponse.status == 503)
    #expect(journalResponse.body == Data("{\"error\":\"status_unavailable\"}".utf8))

    let corruptFinal = try await RouterFixture()
    try await corruptFinal.finalStatuses.publish(FinalDeliveryReceipt(
        memoID: routerMemoID,
        audioSHA256: AudioDigest.hex(body),
        stateRevision: 8,
        deliveredAt: routerNow
    ))
    try Data("not-json".utf8).write(
        to: corruptFinal.finalStatusRoot.appending(path: "\(routerMemoID.rawValue).json")
    )
    let finalResponse = try await corruptFinal.router.route(
        makeSignedStatusHTTPRequest(nonce: "corrupt-final-status", revision: 2)
    )
    #expect(finalResponse.status == 503)
    #expect(finalResponse.body == Data("{\"error\":\"status_unavailable\"}".utf8))
}

@Test func routerStatusRevisionConflictRemains409ForActiveAndFinalTruth() async throws {
    let body = Data("status-revision-audio".utf8)
    let active = try await RouterFixture()
    #expect(try await active.router.route(
        makeSignedHTTPRequest(body: body, nonce: "revision-active-upload")
    ).status == 201)
    let receipt = try #require(try await active.intake.receipt(for: routerMemoID))
    try active.journal.create(.received(
        memoID: routerMemoID,
        capturedAt: receipt.capturedAt,
        localeHint: receipt.localeHint,
        audioSHA256: receipt.audioSHA256,
        updatedAt: routerNow
    ))
    let activeConflict = try await active.router.route(
        makeSignedStatusHTTPRequest(nonce: "revision-active-status", revision: 3)
    )
    #expect(activeConflict.status == 409)
    #expect(activeConflict.body == Data("{\"error\":\"revision_conflict\"}".utf8))

    let terminal = try await RouterFixture()
    try await terminal.finalStatuses.publish(FinalDeliveryReceipt(
        memoID: routerMemoID,
        audioSHA256: AudioDigest.hex(body),
        stateRevision: 8,
        deliveredAt: routerNow
    ))
    let terminalConflict = try await terminal.router.route(
        makeSignedStatusHTTPRequest(nonce: "revision-terminal-status", revision: 9)
    )
    #expect(terminalConflict.status == 409)
    #expect(terminalConflict.body == Data("{\"error\":\"revision_conflict\"}".utf8))
}

@Test(arguments: DualTruthDisagreement.allCases)
func routerStatusRejectsContradictoryCompleteActiveAndFinalTruth(
    _ disagreement: DualTruthDisagreement
) async throws {
    let fixture = try await RouterFixture()
    let body = Data("dual-status-truth".utf8)
    #expect(try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "dual-truth-upload-\(disagreement)")
    ).status == 201)
    let receipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    if disagreement == .state {
        try fixture.journal.create(.received(
            memoID: routerMemoID,
            capturedAt: receipt.capturedAt,
            localeHint: receipt.localeHint,
            audioSHA256: receipt.audioSHA256,
            updatedAt: routerNow
        ))
        _ = try fixture.journal.transition(memoID: routerMemoID, to: .transcribing)
        _ = try fixture.journal.transition(
            memoID: routerMemoID,
            to: .readyForCodex,
            transcript: "Dual truth"
        )
        _ = try fixture.journal.transition(memoID: routerMemoID, to: .inserting)
        _ = try fixture.journal.transition(memoID: routerMemoID, to: .reconciling)
        _ = try fixture.journal.transition(memoID: routerMemoID, to: .needsAttention)
    } else {
        try fixture.markDelivered(receipt: receipt)
    }
    let active = try fixture.journal.load(memoID: routerMemoID)
    let activeRevision = receipt.acknowledgedRevision + active.revision
    let matchingFinal = try FinalDeliveryReceipt(
        memoID: routerMemoID,
        audioSHA256: active.audioSHA256,
        stateRevision: disagreement == .revision
            ? activeRevision + 1
            : activeRevision,
        deliveredAt: disagreement == .timestamp
            ? active.updatedAt.addingTimeInterval(1)
            : active.updatedAt
    )
    try await fixture.finalStatuses.publish(matchingFinal)
    if disagreement == .digest {
        let conflictingFinal = try FinalDeliveryReceipt(
            memoID: routerMemoID,
            audioSHA256: String(repeating: "f", count: 64),
            stateRevision: activeRevision,
            deliveredAt: active.updatedAt
        )
        try JSONEncoder().encode(conflictingFinal).write(
            to: fixture.finalStatusRoot.appending(path: "\(routerMemoID.rawValue).json")
        )
    }

    let response = try await fixture.router.route(makeSignedStatusHTTPRequest(
        nonce: "dual-truth-status-\(disagreement)",
        revision: 2
    ))
    #expect(response.status == 503)
    #expect(response.body == Data("{\"error\":\"status_unavailable\"}".utf8))
}

@Test func routerStatusAcceptsConsistentActiveAndFinalPublicationWindow() async throws {
    let fixture = try await RouterFixture()
    let body = Data("consistent-dual-status-truth".utf8)
    #expect(try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "consistent-dual-upload")
    ).status == 201)
    let receipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.markDelivered(receipt: receipt)
    let active = try fixture.journal.load(memoID: routerMemoID)
    try await fixture.finalStatuses.publish(FinalDeliveryReceipt(
        memoID: routerMemoID,
        audioSHA256: active.audioSHA256,
        stateRevision: receipt.acknowledgedRevision + active.revision,
        deliveredAt: active.updatedAt
    ))

    let response = try await fixture.router.route(makeSignedStatusHTTPRequest(
        nonce: "consistent-dual-status",
        revision: 2
    ))
    let status = try JSONDecoder().decode(
        BridgeEnvelope<BridgeMemoStatus>.self,
        from: response.body
    ).payload
    #expect(response.status == 200)
    #expect(status.state == .delivered)
    #expect(status.audioSHA256 == active.audioSHA256)
    #expect(status.stateRevision == receipt.acknowledgedRevision + active.revision)
    #expect(status.updatedAt == active.updatedAt)
}

@Test func finalAcknowledgementSurvivesArchivalAndIsIdempotent() async throws {
    let codexAdmissions = AdmittedRecordRecorder()
    let retentionEvents = RouterEventRecorder()
    let fixture = try await RouterFixture(onCommitted: { record in
        await codexAdmissions.record(record)
    })
    let body = Data("final-ack-audio".utf8)
    #expect(try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "final-ack-upload")
    ).status == 201)
    for _ in 0 ..< 20 where await codexAdmissions.records.isEmpty {
        await Task.yield()
    }
    let intakeReceipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.markDelivered(receipt: intakeReceipt)
    let publisher = DeliveryCompletionPublisher(
        intakeStore: fixture.intake,
        journal: fixture.journal,
        finalStatusStore: fixture.finalStatuses,
        retainDelivered: { memoID in
            await retentionEvents.append("retained")
            try await fixture.retention.retainDelivered(memoID)
        }
    )
    try await publisher.publishAndRetain(routerMemoID)

    #expect(try await fixture.intake.committedRecord(for: routerMemoID) == nil)
    #expect(try await fixture.intake.retainedRecord(for: routerMemoID) != nil)
    let statusResponse = try await fixture.router.route(
        makeSignedStatusHTTPRequest(nonce: "final-ack-status", revision: 2)
    )
    let status = try JSONDecoder().decode(
        BridgeEnvelope<BridgeMemoStatus>.self,
        from: statusResponse.body
    ).payload
    #expect(statusResponse.status == 200)
    #expect(status.state == .delivered)

    let acknowledgement = FinalDeliveryAcknowledgement(
        memoID: status.memoID,
        audioSHA256: status.audioSHA256,
        stateRevision: status.stateRevision
    )
    let first = try await fixture.router.route(makeSignedFinalAcknowledgementHTTPRequest(
        acknowledgement,
        nonce: "final-ack-first"
    ))
    #expect(first.status == 204)
    #expect(first.body.isEmpty)
    #expect(try await fixture.finalStatuses.receipt(for: routerMemoID) == nil)

    let repeated = try await fixture.router.route(makeSignedFinalAcknowledgementHTTPRequest(
        acknowledgement,
        nonce: "final-ack-repeat"
    ))
    #expect(repeated.status == 204)
    #expect(repeated.body.isEmpty)
    #expect(await codexAdmissions.records.count == 1)
    #expect(await retentionEvents.values == ["retained"])
    #expect(try await fixture.intake.retainedRecord(for: routerMemoID) != nil)
}

@Test func finalAcknowledgementRejectsWrongDigestAndWrongRevisionWithoutRemovingReceipt() async throws {
    let fixture = try await RouterFixture()
    let body = Data("final-ack-identity".utf8)
    #expect(try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "final-identity-upload")
    ).status == 201)
    let intakeReceipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.markDelivered(receipt: intakeReceipt)
    try await DeliveryCompletionPublisher(
        intakeStore: fixture.intake,
        journal: fixture.journal,
        finalStatusStore: fixture.finalStatuses,
        retainDelivered: { memoID in try await fixture.retention.retainDelivered(memoID) }
    ).publishAndRetain(routerMemoID)
    let terminal = try #require(try await fixture.finalStatuses.receipt(for: routerMemoID))

    let wrongDigest = FinalDeliveryAcknowledgement(
        memoID: terminal.memoID,
        audioSHA256: AudioDigest.hex(Data("different-audio".utf8)),
        stateRevision: terminal.stateRevision
    )
    let wrongDigestResponse = try await fixture.router.route(
        makeSignedFinalAcknowledgementHTTPRequest(wrongDigest, nonce: "final-wrong-digest")
    )
    #expect(wrongDigestResponse.status == 409)
    #expect(wrongDigestResponse.body == Data("{\"error\":\"identity_conflict\"}".utf8))
    #expect(try await fixture.finalStatuses.receipt(for: routerMemoID) == terminal)

    let wrongRevision = FinalDeliveryAcknowledgement(
        memoID: terminal.memoID,
        audioSHA256: terminal.audioSHA256,
        stateRevision: terminal.stateRevision &+ 1
    )
    let wrongRevisionResponse = try await fixture.router.route(
        makeSignedFinalAcknowledgementHTTPRequest(wrongRevision, nonce: "final-wrong-revision")
    )
    #expect(wrongRevisionResponse.status == 409)
    #expect(wrongRevisionResponse.body == Data("{\"error\":\"identity_conflict\"}".utf8))
    #expect(try await fixture.finalStatuses.receipt(for: routerMemoID) == terminal)
}

@Test func unauthenticatedFinalAcknowledgementPreservesTerminalReceipt() async throws {
    let fixture = try await RouterFixture()
    let body = Data("final-ack-auth-preserve".utf8)
    #expect(try await fixture.router.route(
        makeSignedHTTPRequest(body: body, nonce: "final-auth-preserve-upload")
    ).status == 201)
    let intakeReceipt = try #require(try await fixture.intake.receipt(for: routerMemoID))
    try fixture.markDelivered(receipt: intakeReceipt)
    try await DeliveryCompletionPublisher(
        intakeStore: fixture.intake,
        journal: fixture.journal,
        finalStatusStore: fixture.finalStatuses,
        retainDelivered: { memoID in try await fixture.retention.retainDelivered(memoID) }
    ).publishAndRetain(routerMemoID)
    let terminal = try #require(try await fixture.finalStatuses.receipt(for: routerMemoID))

    var request = try makeSignedFinalAcknowledgementHTTPRequest(
        FinalDeliveryAcknowledgement(
            memoID: terminal.memoID,
            audioSHA256: terminal.audioSHA256,
            stateRevision: terminal.stateRevision
        ),
        nonce: "final-auth-preserve"
    )
    request = HTTPRequest(
        method: request.method,
        path: request.path,
        headers: request.headers.merging(["authorization": "Bearer \(String(repeating: "0", count: 64))"]) { _, new in new },
        body: request.body
    )
    let response = await fixture.router.route(request)
    #expect(response.status == 401)
    #expect(response.body == Data("{\"error\":\"unauthorized\"}".utf8))
    #expect(try await fixture.finalStatuses.receipt(for: routerMemoID) == terminal)
}

private struct RouterFixture {
    let intake: IntakeStore
    let intakeRoot: URL
    let journal: DeliveryJournal
    let journalRoot: URL
    let finalStatuses: FinalDeliveryStatusStore
    let finalStatusRoot: URL
    let retention: BridgeDeliveredRetentionController
    let router: BridgeRequestRouter

    init(
        onCommitted: (@Sendable (CommittedIntakeRecord) async -> Void)? = nil,
        minimumAvailableBytes: Int64 = 0,
        availableBytes: @escaping @Sendable () -> Int64 = { Int64.max },
        clock: @escaping @Sendable () -> Date = { routerNow },
        replayStore: any ReplayNonceStore = InMemoryReplayNonceStore(),
        pairingAttemptLimit: Int = 5,
        uploadRequestLimit: Int = 120,
        rateLimitWindow: TimeInterval = 60,
        finalStatusCapacity: Int = 4096,
        finalStatusFaultInjector: @escaping @Sendable (
            FinalDeliveryStatusStoreMutationBoundary
        ) throws -> Void = { _ in }
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bridge-router-tests-\(UUID().uuidString)", isDirectory: true)
        intakeRoot = root.appending(path: "intake", directoryHint: .isDirectory)
        intake = try IntakeStore(
            rootURL: intakeRoot,
            retentionRootURL: root.appending(path: "retained", directoryHint: .isDirectory)
        )
        journalRoot = root.appendingPathComponent("delivery", isDirectory: true)
        journal = try DeliveryJournal(root: journalRoot)
        finalStatusRoot = root.appending(path: "final-status", directoryHint: .isDirectory)
        finalStatuses = try FinalDeliveryStatusStore(
            rootURL: finalStatusRoot,
            capacity: finalStatusCapacity,
            faultInjector: finalStatusFaultInjector
        )
        retention = try BridgeDeliveredRetentionController(intakeStore: intake, journal: journal)
        let secrets = InMemorySecretStore()
        let pairing = try PairingStore(
            secretStore: secrets,
            clock: clock,
            codeGenerator: { "123456" },
            tokenGenerator: { routerToken }
        )
        _ = try await pairing.beginPairing(validFor: 600)
        _ = try await pairing.rotateCredential()
        router = try BridgeRequestRouter(
            pairingStore: pairing,
            intakeStore: intake,
            deliveryJournal: journal,
            finalStatusStore: finalStatuses,
            allowedClockSkew: 60,
            replayRetention: 600,
            clock: clock,
            replayStore: replayStore,
            onCommitted: onCommitted,
            minimumAvailableBytes: minimumAvailableBytes,
            availableBytes: availableBytes,
            pairingAttemptLimit: pairingAttemptLimit,
            uploadRequestLimit: uploadRequestLimit,
            rateLimitWindow: rateLimitWindow
        )
    }

    func markDelivered(receipt: BridgeReceipt) throws {
        try journal.create(.received(
            memoID: receipt.memoID,
            capturedAt: receipt.capturedAt,
            localeHint: receipt.localeHint,
            audioSHA256: receipt.audioSHA256,
            updatedAt: routerNow
        ))
        _ = try journal.transition(memoID: receipt.memoID, to: .transcribing)
        _ = try journal.transition(
            memoID: receipt.memoID,
            to: .readyForCodex,
            transcript: "Final acknowledgement"
        )
        _ = try journal.transition(memoID: receipt.memoID, to: .inserting)
        _ = try journal.transition(memoID: receipt.memoID, to: .reconciling)
        _ = try journal.transition(memoID: receipt.memoID, to: .delivered)
    }
}

private actor FailingReplayNonceStore: ReplayNonceStore {
    func consume(_: String, acceptedAt _: Date, expiresAt _: Date) throws -> Bool {
        throw ReplayStoreFailure.unavailable
    }
}

private enum ReplayStoreFailure: Error {
    case unavailable
}

private final class RouterClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private func makeSignedStatusHTTPRequest(
    nonce: String,
    revision: UInt64,
    timestamp: Int64 = 1_700_000_000,
    memoID: MemoID = routerMemoID
) throws -> HTTPRequest {
    let path = "/v1/memos/\(memoID.rawValue)/status"
    let digest = AudioDigest.hex(Data())
    let canonical = try CanonicalBridgeRequest(
        method: "GET",
        path: path,
        timestamp: timestamp,
        nonce: nonce,
        memoID: memoID,
        bodySHA256: digest,
        revision: revision
    )
    let signature = try RequestAuthenticator.signatureHex(
        for: canonical,
        key: SymmetricKey(data: routerToken)
    )
    return HTTPRequest(
        method: "GET",
        path: path,
        headers: [
            "authorization": "Bearer \(routerToken.map { String(format: "%02x", $0) }.joined())",
            "content-length": "0",
            "host": "localhost",
            "x-codex-body-sha256": digest,
            "x-codex-memo-id": memoID.rawValue,
            "x-codex-nonce": nonce,
            "x-codex-revision": String(revision),
            "x-codex-signature": signature,
            "x-codex-timestamp": String(timestamp),
            "x-codex-version": "1",
        ],
        body: Data()
    )
}

private func makeSignedFinalAcknowledgementHTTPRequest(
    _ acknowledgement: FinalDeliveryAcknowledgement,
    nonce: String,
    timestamp: Int64 = 1_700_000_000
) throws -> HTTPRequest {
    let path = "/v1/memos/\(acknowledgement.memoID.rawValue)/final-ack"
    let canonical = try CanonicalBridgeRequest(
        method: "POST",
        path: path,
        timestamp: timestamp,
        nonce: nonce,
        memoID: acknowledgement.memoID,
        bodySHA256: acknowledgement.audioSHA256,
        revision: acknowledgement.stateRevision
    )
    let signature = try RequestAuthenticator.signatureHex(
        for: canonical,
        key: SymmetricKey(data: routerToken)
    )
    return HTTPRequest(
        method: "POST",
        path: path,
        headers: [
            "authorization": "Bearer \(routerToken.map { String(format: "%02x", $0) }.joined())",
            "content-length": "0",
            "host": "localhost",
            "x-codex-body-sha256": acknowledgement.audioSHA256,
            "x-codex-memo-id": acknowledgement.memoID.rawValue,
            "x-codex-nonce": nonce,
            "x-codex-revision": String(acknowledgement.stateRevision),
            "x-codex-signature": signature,
            "x-codex-timestamp": String(timestamp),
            "x-codex-version": "1",
        ],
        body: Data()
    )
}

private actor AdmittedRecordRecorder {
    private(set) var records: [CommittedIntakeRecord] = []
    func record(_ record: CommittedIntakeRecord) { records.append(record) }
}

private final class FailSelectedFinalStatusWrite: @unchecked Sendable {
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
        if shouldFail { throw RouterFinalStatusFault.injected }
    }
}

private enum RouterFinalStatusFault: Error {
    case injected
}

enum DualTruthDisagreement: String, CaseIterable, Sendable {
    case digest
    case revision
    case state
    case timestamp
}

private actor RouterEventRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private func makePairingHTTPRequest(code: String) throws -> HTTPRequest {
    let body = try JSONEncoder().encode(PairingRedemptionRequest(code: code))
    return HTTPRequest(
        method: "POST",
        path: "/v1/pair",
        headers: [
            "content-length": String(body.count),
            "content-type": "application/json",
            "host": "localhost",
            "x-codex-version": "1",
        ],
        body: body
    )
}

private func makeSignedHTTPRequest(
    body: Data,
    nonce: String,
    timestamp: Int64 = 1_700_000_000,
    revision: UInt64 = 1,
    signedDigest: String? = nil
) throws -> HTTPRequest {
    let path = "/v1/memos/\(routerMemoID.rawValue)"
    let digest = signedDigest ?? AudioDigest.hex(body)
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_123)
    let localeHint = "en-US"
    let canonical = try CanonicalBridgeRequest(
        method: "POST",
        path: path,
        timestamp: timestamp,
        nonce: nonce,
        memoID: routerMemoID,
        bodySHA256: digest,
        revision: revision,
        capturedAtBits: capturedAt.timeIntervalSinceReferenceDate.bitPattern,
        localeHint: localeHint
    )
    let signature = try RequestAuthenticator.signatureHex(
        for: canonical,
        key: SymmetricKey(data: routerToken)
    )
    return HTTPRequest(
        method: "POST",
        path: path,
        headers: [
            "authorization": "Bearer \(routerToken.map { String(format: "%02x", $0) }.joined())",
            "content-length": String(body.count),
            "content-type": "audio/mp4",
            "host": "localhost",
            "x-codex-body-sha256": digest,
            "x-codex-captured-at": String(capturedAt.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            "x-codex-locale": localeHint,
            "x-codex-memo-id": routerMemoID.rawValue,
            "x-codex-nonce": nonce,
            "x-codex-revision": String(revision),
            "x-codex-signature": signature,
            "x-codex-timestamp": String(timestamp),
            "x-codex-version": "1",
        ],
        body: body
    )
}
