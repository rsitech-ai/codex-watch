@testable import CodexBridgeShared
import Foundation
import Testing

private let memoUUIDText = "123e4567-e89b-12d3-a456-426614174000"
private let audioDigest = String(repeating: "a", count: 64)

@Test func memoIDCanonicalizesAndEncodesLowercaseUUIDText() throws {
    let id = try MemoID("123E4567-E89B-12D3-A456-426614174000")

    #expect(id.rawValue == memoUUIDText)
    #expect(String(data: try JSONEncoder().encode(id), encoding: .utf8) == #""123e4567-e89b-12d3-a456-426614174000""#)
}

@Test func memoIDRejectsInvalidConstructionAndDecoding() {
    #expect(throws: MemoIDError.self) {
        _ = try MemoID("memo-not-a-uuid")
    }
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(MemoID.self, from: Data(#""memo-not-a-uuid""#.utf8))
    }
}

@Test func voiceMemoMetadataRoundTripsImmutableAudioIdentity() throws {
    let metadata = try makeMetadata()

    let roundTripped = try JSONDecoder().decode(
        VoiceMemoMetadata.self,
        from: JSONEncoder().encode(metadata)
    )

    #expect(roundTripped == metadata)
    #expect(roundTripped.memoID.rawValue == memoUUIDText)
    #expect(roundTripped.audioSHA256 == audioDigest)
    #expect(roundTripped.byteCount == 42)
    #expect(roundTripped.durationMilliseconds == 1_250)
    #expect(roundTripped.formatVersion == VoiceMemoMetadata.currentFormatVersion)
    #expect(roundTripped.localeHint == "en-US")
    #expect(roundTripped.state == .saved)
    #expect(roundTripped.stateRevision == 0)
}

@Test(arguments: [
    "",
    "abc",
    String(repeating: "g", count: 64),
    String(repeating: "a", count: 63),
    String(repeating: "a", count: 65),
])
func voiceMemoMetadataRejectsInvalidAudioDigest(_ digest: String) {
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(audioSHA256: digest)
    }
}

@Test func voiceMemoMetadataRejectsNegativeAndOutOfBoundsValues() {
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(byteCount: 0)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(byteCount: -1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(byteCount: VoiceMemoMetadata.maximumAudioByteCount + 1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(durationMilliseconds: 0)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(durationMilliseconds: -1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(durationMilliseconds: VoiceMemoMetadata.maximumDurationMilliseconds + 1)
    }
}

@Test func memoTransitionCanReturnToSavedForRetryWithoutLosingRevision() throws {
    let saved = try makeMetadata()
    let uploading = try MemoStateTransition.transition(saved, to: .uploading, revision: 1)
    let waiting = try MemoStateTransition.transition(uploading, to: .saved, revision: 2)

    #expect(waiting.state == .saved)
    #expect(waiting.stateRevision == 2)
    #expect(waiting.memoID == saved.memoID)
    #expect(waiting.audioSHA256 == saved.audioSHA256)
}

@Test func voiceMemoMetadataRejectsUnsupportedFormatAndInconsistentStateRevision() {
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(formatVersion: VoiceMemoMetadata.currentFormatVersion + 1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(state: .delivered, stateRevision: 0)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(state: .saved, stateRevision: 1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(state: .transcribing, stateRevision: 1)
    }
    #expect(throws: VoiceMemoValidationError.self) {
        _ = try makeMetadata(state: .delivered, stateRevision: 2)
    }
}

@Test func voiceMemoMetadataAcceptsOnlyReachableLoopAndTerminalRevisions() throws {
    let savedAfterRetry = try makeMetadata(state: .saved, stateRevision: 2)
    let deliveredDirectly = try makeMetadata(state: .delivered, stateRevision: 6)
    let deliveredAfterReconciliation = try makeMetadata(state: .delivered, stateRevision: 7)

    #expect(savedAfterRetry.stateRevision == 2)
    #expect(deliveredDirectly.stateRevision == 6)
    #expect(deliveredAfterReconciliation.stateRevision == 7)
}

@Test func memoTransitionAdvancesOnlyAcrossLegalStatesWithNewerRevision() throws {
    let saved = try makeMetadata()
    let uploading = try MemoStateTransition.transition(saved, to: .uploading, revision: 1)
    let received = try MemoStateTransition.transition(uploading, to: .received, revision: 2)

    #expect(uploading.state == .uploading)
    #expect(uploading.stateRevision == 1)
    #expect(received.state == .received)
    #expect(received.stateRevision == 2)
    #expect(received.memoID == saved.memoID)
    #expect(received.audioSHA256 == saved.audioSHA256)
}

@Test func memoTransitionRejectsStaleRevisionRegressionAndSkippedState() throws {
    let saved = try makeMetadata()
    let uploading = try MemoStateTransition.transition(saved, to: .uploading, revision: 1)
    let received = try MemoStateTransition.transition(uploading, to: .received, revision: 2)

    #expect(throws: MemoTransitionError.self) {
        _ = try MemoStateTransition.transition(uploading, to: .received, revision: 1)
    }
    #expect(throws: MemoTransitionError.self) {
        _ = try MemoStateTransition.transition(received, to: .uploading, revision: 3)
    }
    #expect(throws: MemoTransitionError.self) {
        _ = try MemoStateTransition.transition(saved, to: .transcribing, revision: 1)
    }
}

@Test func bridgeDTOsRejectUnsupportedMajorVersion() throws {
    let invalidVersion = Data(#"{"major":2,"minor":0}"#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(BridgeProtocolVersion.self, from: invalidVersion)
    }

    let invalidEnvelope = Data(#"{"protocolVersion":{"major":2,"minor":0},"payload":"memo"}"#.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(BridgeEnvelope<String>.self, from: invalidEnvelope)
    }
}

@Test func receiptAndStatusValidateMemoDigestAndRevisionAcknowledgements() throws {
    let uploading = try MemoStateTransition.transition(makeMetadata(), to: .uploading, revision: 1)
    let receipt = try BridgeReceipt(
        memoID: uploading.memoID,
        audioSHA256: uploading.audioSHA256,
        acknowledgedRevision: 2,
        capturedAt: uploading.capturedAt,
        localeHint: uploading.localeHint,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let status = try BridgeMemoStatus(
        memoID: uploading.memoID,
        audioSHA256: uploading.audioSHA256,
        state: .received,
        stateRevision: 2,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )

    try receipt.validateAcknowledgement(for: uploading, expectedRevision: 2)
    try status.validateAcknowledgement(for: uploading, expectedRevision: 2)

    let otherMemo = try MemoID("223e4567-e89b-12d3-a456-426614174000")
    let wrongMemo = try BridgeReceipt(
        memoID: otherMemo,
        audioSHA256: uploading.audioSHA256,
        acknowledgedRevision: 2,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let wrongDigest = try BridgeReceipt(
        memoID: uploading.memoID,
        audioSHA256: String(repeating: "b", count: 64),
        acknowledgedRevision: 2,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let wrongRevision = try BridgeReceipt(
        memoID: uploading.memoID,
        audioSHA256: uploading.audioSHA256,
        acknowledgedRevision: 3,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )

    #expect(throws: BridgeAcknowledgementError.self) {
        try wrongMemo.validateAcknowledgement(for: uploading, expectedRevision: 2)
    }
    #expect(throws: BridgeAcknowledgementError.self) {
        try wrongDigest.validateAcknowledgement(for: uploading, expectedRevision: 2)
    }
    #expect(throws: BridgeAcknowledgementError.self) {
        try wrongRevision.validateAcknowledgement(for: uploading, expectedRevision: 2)
    }
}

@Test func statusAcknowledgementRequiresAReachablePathForItsRevisionDelta() throws {
    let uploading = try MemoStateTransition.transition(makeMetadata(), to: .uploading, revision: 1)
    let reachableDelivered = try BridgeMemoStatus(
        memoID: uploading.memoID,
        audioSHA256: uploading.audioSHA256,
        state: .delivered,
        stateRevision: 6,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )

    #expect(throws: BridgeProtocolError.self) {
        _ = try BridgeMemoStatus(
            memoID: uploading.memoID,
            audioSHA256: uploading.audioSHA256,
            state: .delivered,
            stateRevision: 2,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }
    try reachableDelivered.validateAcknowledgement(for: uploading, expectedRevision: 6)

    let received = try MemoStateTransition.transition(uploading, to: .received, revision: 2)
    let transcribing = try MemoStateTransition.transition(received, to: .transcribing, revision: 3)
    let backwardStatus = try BridgeMemoStatus(
        memoID: uploading.memoID,
        audioSHA256: uploading.audioSHA256,
        state: .received,
        stateRevision: 4,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(throws: BridgeAcknowledgementError.self) {
        try backwardStatus.validateAcknowledgement(for: transcribing, expectedRevision: 4)
    }
}

@Test func receiptAndStatusDecodingRevalidatesBoundaryFields() {
    let invalidReceipt = Data("""
    {"memoID":"\(memoUUIDText)","audioSHA256":"bad","acknowledgedRevision":2,"receivedAt":0}
    """.utf8)
    let invalidStatus = Data("""
    {"memoID":"\(memoUUIDText)","audioSHA256":"\(audioDigest)","state":"received","stateRevision":0,"updatedAt":0}
    """.utf8)

    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(BridgeReceipt.self, from: invalidReceipt)
    }
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(BridgeMemoStatus.self, from: invalidStatus)
    }
}

private func makeMetadata(
    audioSHA256: String = audioDigest,
    byteCount: Int64 = 42,
    durationMilliseconds: Int64 = 1_250,
    formatVersion: Int = 1,
    state: MemoState = .saved,
    stateRevision: UInt64 = 0
) throws -> VoiceMemoMetadata {
    try VoiceMemoMetadata(
        memoID: MemoID(memoUUIDText),
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        audioSHA256: audioSHA256,
        byteCount: byteCount,
        durationMilliseconds: durationMilliseconds,
        formatVersion: formatVersion,
        localeHint: "en-US",
        state: state,
        stateRevision: stateRevision
    )
}
