@testable import CodexWatchCore
import CodexBridgeShared
import CryptoKit
import Foundation
import Testing

private let uploadMemoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")
private let uploadToken = Data(repeating: 0x33, count: 32)

@Test func uploadRequestSignsCanonicalHeadersFromImmutableAudioMetadata() throws {
    let body = Data("watch-audio".utf8)
    let memo = try makeUploadingMemo(body: body)

    let request = try BridgeUploadRequestBuilder.make(
        memo: memo,
        contentLength: body.count,
        token: uploadToken,
        timestamp: 1_700_000_000,
        nonce: "nonce-123"
    )

    #expect(request.method == "POST")
    #expect(request.path == "/v1/memos/\(uploadMemoID.rawValue)")
    #expect(request.contentLength == body.count)
    #expect(request.headers["authorization"] == "Bearer \(String(repeating: "33", count: 32))")
    #expect(request.headers["content-length"] == String(body.count))
    #expect(request.headers["content-type"] == "audio/mp4")
    #expect(request.headers["x-codex-body-sha256"] == digest(body))
    #expect(request.headers["x-codex-captured-at"] == String(
        memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
        radix: 16
    ))
    #expect(request.headers["x-codex-memo-id"] == uploadMemoID.rawValue)
    #expect(request.headers["x-codex-nonce"] == "nonce-123")
    #expect(request.headers["x-codex-revision"] == "1")
    #expect(request.headers["x-codex-timestamp"] == "1700000000")
    #expect(request.headers["x-codex-version"] == "1")

    let canonical = try CanonicalBridgeRequest(
        method: request.method,
        path: request.path,
        timestamp: 1_700_000_000,
        nonce: "nonce-123",
        memoID: uploadMemoID,
        bodySHA256: digest(body),
        revision: 1,
        capturedAtBits: memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
        localeHint: memo.localeHint
    )
    #expect(try RequestAuthenticator.verify(
        signatureHex: try #require(request.headers["x-codex-signature"]),
        for: canonical,
        key: SymmetricKey(data: uploadToken)
    ))
}

@Test func watchUploadUsesFileMetadataWithoutThirtyTwoMiBRequestData() throws {
    let byteCount = 32 * 1_024 * 1_024
    let saved = try VoiceMemoMetadata(
        memoID: uploadMemoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioSHA256: String(repeating: "a", count: 64),
        byteCount: Int64(byteCount),
        durationMilliseconds: 15 * 60 * 1_000
    )
    let memo = try MemoStateTransition.transition(saved, to: .uploading, revision: 1)

    let request = try BridgeUploadRequestBuilder.make(
        memo: memo,
        contentLength: byteCount,
        token: uploadToken,
        timestamp: 1_700_000_000,
        nonce: "file-metadata"
    )

    #expect(request.contentLength == byteCount)
    #expect(request.headers["content-length"] == String(byteCount))
    #expect(!Mirror(reflecting: request).children.contains { $0.label == "body" })
}

@Test func missingStatusRecoverySignsTheOriginalAcceptedUploadIdentity() throws {
    let body = Data("watch-audio".utf8)
    let memo = try testMemo(state: .received, revision: 2)

    let request = try BridgeRecoveryUploadRequestBuilder.make(
        memo: memo,
        contentLength: body.count,
        token: uploadToken,
        timestamp: 1_700_000_000,
        nonce: "recovery-nonce"
    )

    #expect(request.method == "POST")
    #expect(request.path == "/v1/memos/\(memo.memoID.rawValue)")
    #expect(request.contentLength == body.count)
    #expect(request.headers["x-codex-body-sha256"] == memo.audioSHA256)
    #expect(request.headers["x-codex-captured-at"] == String(
        memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
        radix: 16
    ))
    #expect(request.headers["x-codex-revision"] == "1")
    let canonical = try CanonicalBridgeRequest(
        method: "POST",
        path: request.path,
        timestamp: 1_700_000_000,
        nonce: "recovery-nonce",
        memoID: memo.memoID,
        bodySHA256: memo.audioSHA256,
        revision: 1,
        capturedAtBits: memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
        localeHint: memo.localeHint
    )
    #expect(try RequestAuthenticator.verify(
        signatureHex: try #require(request.headers["x-codex-signature"]),
        for: canonical,
        key: SymmetricKey(data: uploadToken)
    ))
}

@Test func statusRequestIsCanonicalAuthenticatedGETWithEmptyBodyDigest() throws {
    let memo = try testMemo(state: .received, revision: 2)
    let token = Data(repeating: 0x44, count: 32)
    let request = try BridgeStatusRequestBuilder.make(
        memo: memo,
        token: token,
        timestamp: 1_700_000_000,
        nonce: "status-nonce"
    )

    #expect(request.method == "GET")
    #expect(request.path == "/v1/memos/\(memo.memoID.rawValue)/status")
    #expect(request.body.isEmpty)
    #expect(request.headers["x-codex-body-sha256"] == digest(Data()))
    #expect(request.headers["x-codex-revision"] == "2")
    let canonical = try CanonicalBridgeRequest(
        method: "GET",
        path: request.path,
        timestamp: 1_700_000_000,
        nonce: "status-nonce",
        memoID: memo.memoID,
        bodySHA256: digest(Data()),
        revision: 2
    )
    #expect(try RequestAuthenticator.verify(
        signatureHex: try #require(request.headers["x-codex-signature"]),
        for: canonical,
        key: SymmetricKey(data: token)
    ))
}

@Test func finalAcknowledgementRequestSignsIdentityHeadersWithEmptyBody() throws {
    let token = Data(repeating: 0x55, count: 32)
    let acknowledgement = FinalDeliveryAcknowledgement(
        memoID: uploadMemoID,
        audioSHA256: digest(Data("watch-audio".utf8)),
        stateRevision: 7
    )
    let request = try BridgeFinalAcknowledgementRequestBuilder.make(
        acknowledgement: acknowledgement,
        token: token,
        timestamp: 1_700_000_000,
        nonce: "final-ack-nonce"
    )

    let expectedVersion = try BridgeProtocolVersion(major: 1, minor: 3)
    #expect(BridgeProtocolVersion.current == expectedVersion)
    #expect(request.method == "POST")
    #expect(request.path == "/v1/memos/\(uploadMemoID.rawValue)/final-ack")
    #expect(request.body.isEmpty)
    #expect(request.headers["content-length"] == "0")
    #expect(request.headers["x-codex-body-sha256"] == acknowledgement.audioSHA256)
    #expect(request.headers["x-codex-revision"] == "7")
    let canonical = try CanonicalBridgeRequest(
        method: "POST",
        path: request.path,
        timestamp: 1_700_000_000,
        nonce: "final-ack-nonce",
        memoID: uploadMemoID,
        bodySHA256: acknowledgement.audioSHA256,
        revision: 7
    )
    #expect(try RequestAuthenticator.verify(
        signatureHex: try #require(request.headers["x-codex-signature"]),
        for: canonical,
        key: SymmetricKey(data: token)
    ))
    #expect(try BridgeFinalAcknowledgementResponseDecoder.acknowledged(
        statusCode: 204,
        body: Data()
    ))
}

@Test func statusResponseDecoderBoundsAuthenticationAndMapsEnvelope() throws {
    let memo = try testMemo(state: .received, revision: 2)
    let status = try BridgeMemoStatus(
        memoID: memo.memoID,
        audioSHA256: memo.audioSHA256,
        state: .transcribing,
        stateRevision: 3,
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let body = try JSONEncoder().encode(BridgeEnvelope(payload: status))
    #expect(try BridgeStatusResponseDecoder.status(statusCode: 200, body: body) == status)
    #expect(throws: WatchBridgeTransportFailure.authentication) {
        _ = try BridgeStatusResponseDecoder.status(statusCode: 401, body: Data())
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeStatusResponseDecoder.status(statusCode: 503, body: Data())
    }
    #expect(throws: WatchBridgeTransportFailure.statusAbsent) {
        _ = try BridgeStatusResponseDecoder.status(
            statusCode: 404,
            body: Data(#"{"error":"status_absent"}"#.utf8)
        )
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeStatusResponseDecoder.status(
            statusCode: 404,
            body: Data(#"{"error":"unknown"}"#.utf8)
        )
    }
}

@Test func uploadRequestRejectsAudioThatDoesNotMatchCommittedMetadata() throws {
    let committed = Data("committed".utf8)
    let changed = Data("changed".utf8)
    let memo = try makeUploadingMemo(body: committed)

    #expect(throws: BridgeUploadRequestError.audioIdentityMismatch) {
        _ = try BridgeUploadRequestBuilder.make(
            memo: memo,
            contentLength: changed.count,
            token: uploadToken,
            timestamp: 1_700_000_000,
            nonce: "nonce-123"
        )
    }
}

@Test func uploadResponseMapsReceiptAndFailuresWithoutClaimingCodexDelivery() throws {
    let body = Data("watch-audio".utf8)
    let receipt = try BridgeReceipt(
        memoID: uploadMemoID,
        audioSHA256: digest(body),
        acknowledgedRevision: 2,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let encoded = try JSONEncoder().encode(BridgeEnvelope(payload: receipt))

    #expect(try BridgeUploadResponseDecoder.receipt(statusCode: 201, body: encoded) == receipt)
    #expect(throws: WatchBridgeTransportFailure.authentication) {
        _ = try BridgeUploadResponseDecoder.receipt(statusCode: 401, body: Data())
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeUploadResponseDecoder.receipt(statusCode: 409, body: Data())
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeUploadResponseDecoder.receipt(statusCode: 503, body: Data())
    }
}

@Test func responseDecodersRetryMalformedSuccessAndUnknownProtocolResponses() {
    let unknown = Data(#"{"error":"unknown_bridge_failure"}"#.utf8)

    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeUploadResponseDecoder.receipt(
            statusCode: 201,
            body: Data(#"{"payload":"#.utf8)
        )
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeStatusResponseDecoder.status(statusCode: 200, body: Data())
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeFinalAcknowledgementResponseDecoder.acknowledged(
            statusCode: 204,
            body: Data("unexpected".utf8)
        )
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeUploadResponseDecoder.receipt(statusCode: 418, body: unknown)
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeStatusResponseDecoder.status(statusCode: 404, body: unknown)
    }
    #expect(throws: WatchBridgeTransportFailure.transient) {
        _ = try BridgeFinalAcknowledgementResponseDecoder.acknowledged(
            statusCode: 409,
            body: unknown
        )
    }
}

@Test func responseDecodersClassifyOnlyExactTerminalErrorCodes() {
    for code in [
        "corrupt_content",
        "digest_mismatch",
        "unsupported_format",
        "inconsistent_authoritative_history",
    ] {
        #expect(throws: WatchBridgeTransportFailure.permanent) {
            _ = try BridgeUploadResponseDecoder.receipt(
                statusCode: 409,
                body: Data(#"{"error":"\#(code)"}"#.utf8)
            )
        }
    }
}

@Test func currentServiceIdentityConflictIsTerminalButNearMissCodesRetry() {
    #expect(throws: WatchBridgeTransportFailure.conflict) {
        _ = try BridgeUploadResponseDecoder.receipt(
            statusCode: 409,
            body: Data(#"{"error":"identity_conflict"}"#.utf8)
        )
    }
    for code in [
        "identity_conflicts",
        "identity-conflict",
        "immutable_identity_conflict",
    ] {
        #expect(throws: WatchBridgeTransportFailure.transient) {
            _ = try BridgeUploadResponseDecoder.receipt(
                statusCode: 409,
                body: Data(#"{"error":"\#(code)"}"#.utf8)
            )
        }
    }
}

@Test func authenticationFailureInvalidatesTokenButTransientFailureRetainsIt() throws {
    let credential = try WatchBridgeCredential(
        bridgeName: "Studio Mac",
        baseURL: URL(string: "https://studio-mac.local:7443")!,
        certificatePin: CertificatePin(String(repeating: "a", count: 64)),
        tokenHex: String(repeating: "33", count: 32)
    )

    #expect(credential.retained(after: .authentication) == nil)
    #expect(credential.retained(after: .transient) == credential)
    #expect(credential.retained(after: .conflict) == credential)
}

private func makeUploadingMemo(body: Data) throws -> VoiceMemoMetadata {
    let saved = try VoiceMemoMetadata(
        memoID: uploadMemoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioSHA256: digest(body),
        byteCount: Int64(body.count),
        durationMilliseconds: 1_000
    )
    return try MemoStateTransition.transition(saved, to: .uploading, revision: 1)
}

private func testMemo(state: MemoState, revision: UInt64) throws -> VoiceMemoMetadata {
    try VoiceMemoMetadata(
        memoID: uploadMemoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioSHA256: digest(Data("watch-audio".utf8)),
        byteCount: Int64(Data("watch-audio".utf8).count),
        durationMilliseconds: 1_000,
        state: state,
        stateRevision: revision
    )
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
