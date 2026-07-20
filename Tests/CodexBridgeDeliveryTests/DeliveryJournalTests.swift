@testable import CodexBridgeDelivery
import CodexBridgeShared
import Foundation
import Testing

@Test func journalAtomicallyPersistsPrivateRecordsAndRecoversAfterRestart() throws {
    let root = privateTemporaryDirectory("delivery-restart")
    let memoID = try MemoID("11111111-1111-1111-1111-111111111111")
    let journal = try DeliveryJournal(root: root)
    let received = DeliveryRecord.received(
        memoID: memoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        localeHint: "pl-PL",
        audioSHA256: deliveryDigest
    )

    try journal.create(received)
    let transcribing = try journal.transition(memoID: memoID, to: .transcribing)
    let ready = try journal.transition(
        memoID: memoID,
        to: .readyForCodex,
        transcript: "Kup mleko"
    )

    #expect(transcribing.revision == 1)
    #expect(ready.revision == 2)
    #expect(try DeliveryJournal(root: root).load(memoID: memoID) == ready)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: root.appending(path: "\(memoID.rawValue).json").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
        !$0.contains(".tmp-")
    })
}

@Test func journalPersistsTruthfulUpdatedAtAndAdvancesItFromInjectedClock() throws {
    let root = privateTemporaryDirectory("delivery-updated-at")
    let memoID = try MemoID("12121212-1212-1212-1212-121212121212")
    let receivedAt = Date(timeIntervalSince1970: 1_700_000_001)
    let transitionedAt = Date(timeIntervalSince1970: 1_700_000_002)
    let journal = try DeliveryJournal(root: root, clock: { transitionedAt })
    let received = DeliveryRecord.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest,
        updatedAt: receivedAt
    )

    try journal.create(received)
    let transitioned = try journal.transition(memoID: memoID, to: .transcribing)

    #expect(received.updatedAt == receivedAt)
    #expect(transitioned.updatedAt == transitionedAt)
    #expect(try DeliveryJournal(root: root).load(memoID: memoID).updatedAt == transitionedAt)
}

@Test func journalRejectsLegacyRecordThatCannotProveStateChronology() throws {
    let root = privateTemporaryDirectory("delivery-legacy-timestamp")
    let memoID = try MemoID("13131313-1313-1313-1313-131313131313")
    let journal = try DeliveryJournal(root: root)
    try journal.create(.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest,
        updatedAt: Date(timeIntervalSince1970: 1)
    ))
    let url = root.appending(path: "\(memoID.rawValue).json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    object["updatedAt"] = nil
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)

    #expect(throws: DeliveryJournalError.invalidRecord) {
        _ = try journal.load(memoID: memoID)
    }
}

@Test func journalRejectsIllegalTransitionsAndPreservesPreviousRecordOnRenameFailure() throws {
    let root = privateTemporaryDirectory("delivery-transition")
    let memoID = try MemoID("22222222-2222-2222-2222-222222222222")
    let base = try DeliveryJournal(root: root)
    try base.create(.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest
    ))

    #expect(throws: DeliveryJournalError.invalidTransition) {
        _ = try base.transition(memoID: memoID, to: .delivered)
    }

    let failing = try DeliveryJournal(root: root) { boundary in
        if boundary == .beforeRename { throw DeliveryJournalError.fileSystemFailure }
    }
    #expect(throws: DeliveryJournalError.fileSystemFailure) {
        _ = try failing.transition(memoID: memoID, to: .transcribing)
    }
    #expect(try base.load(memoID: memoID).state == .received)
}

@Test func needsAttentionPreservesAnAlreadyPreparedTranscript() throws {
    let root = privateTemporaryDirectory("delivery-attention")
    let memoID = try MemoID("33333333-3333-3333-3333-333333333333")
    let journal = try DeliveryJournal(root: root)
    try journal.create(.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest
    ))
    _ = try journal.transition(memoID: memoID, to: .transcribing)
    _ = try journal.transition(memoID: memoID, to: .readyForCodex, transcript: "Keep this idea")

    let attention = try journal.transition(memoID: memoID, to: .needsAttention)

    #expect(attention.state == .needsAttention)
    #expect(attention.transcript == "Keep this idea")
}

@Test func explicitRetryReopensOnlyTranscriptlessTranscriptionFailures() throws {
    let root = privateTemporaryDirectory("delivery-safe-retry")
    let safeID = try MemoID("34343434-3434-3434-3434-343434343434")
    let ambiguousID = try MemoID("35353535-3535-3535-3535-353535353535")
    let journal = try DeliveryJournal(root: root)
    for id in [safeID, ambiguousID] {
        try journal.create(.received(memoID: id, capturedAt: .distantPast, localeHint: nil, audioSHA256: deliveryDigest))
        _ = try journal.transition(memoID: id, to: .transcribing)
    }
    _ = try journal.transition(memoID: safeID, to: .needsAttention)
    _ = try journal.transition(memoID: ambiguousID, to: .readyForCodex, transcript: "may already be inserted")
    _ = try journal.transition(memoID: ambiguousID, to: .needsAttention)

    #expect(try journal.retry(memoID: safeID).state == .received)
    #expect(throws: DeliveryJournalError.invalidTransition) {
        _ = try journal.retry(memoID: ambiguousID)
    }
    #expect(try journal.load(memoID: ambiguousID).state == .needsAttention)
}

@Test func safeRetryBoundariesPreservePreparedTranscriptAndAdvanceRevision() throws {
    let root = privateTemporaryDirectory("delivery-boundary-retry")
    let notAcceptedID = try MemoID("36363636-3636-3636-3636-363636363636")
    let absentID = try MemoID("37373737-3737-3737-3737-373737373737")
    let clock = Date(timeIntervalSince1970: 1_700_000_010)
    let journal = try DeliveryJournal(root: root, clock: { clock })
    for id in [notAcceptedID, absentID] {
        try journal.create(.received(
            memoID: id,
            capturedAt: .distantPast,
            localeHint: nil,
            audioSHA256: deliveryDigest
        ))
        _ = try journal.transition(memoID: id, to: .transcribing)
        _ = try journal.transition(memoID: id, to: .readyForCodex, transcript: "Stable idea")
        _ = try journal.transition(memoID: id, to: .inserting)
    }
    _ = try journal.transition(memoID: absentID, to: .reconciling)

    let reopenedNotAccepted = try journal.reopenForSafeRetry(
        memoID: notAcceptedID,
        boundary: .definitelyNotAccepted
    )
    let reopenedAbsent = try journal.reopenForSafeRetry(
        memoID: absentID,
        boundary: .authoritativelyAbsent
    )

    #expect(reopenedNotAccepted.state == .readyForCodex)
    #expect(reopenedNotAccepted.transcript == "Stable idea")
    #expect(reopenedNotAccepted.revision == 4)
    #expect(reopenedNotAccepted.updatedAt == clock)
    #expect(reopenedAbsent.state == .readyForCodex)
    #expect(reopenedAbsent.transcript == "Stable idea")
    #expect(reopenedAbsent.revision == 5)
    #expect(try journal.load(memoID: absentID) == reopenedAbsent)
}

@Test func safeRetryBoundaryRejectsMismatchedStateAndProof() throws {
    let root = privateTemporaryDirectory("delivery-boundary-mismatch")
    let memoID = try MemoID("38383838-3838-3838-3838-383838383838")
    let journal = try DeliveryJournal(root: root)
    try journal.create(.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest
    ))
    _ = try journal.transition(memoID: memoID, to: .transcribing)
    _ = try journal.transition(memoID: memoID, to: .readyForCodex, transcript: "Stable idea")
    _ = try journal.transition(memoID: memoID, to: .inserting)

    #expect(throws: DeliveryJournalError.invalidTransition) {
        _ = try journal.reopenForSafeRetry(memoID: memoID, boundary: .authoritativelyAbsent)
    }
    #expect(try journal.load(memoID: memoID).state == .inserting)
}

@Test func journalRejectsRootDirectoryReplacementAfterInitialization() throws {
    let root = privateTemporaryDirectory("delivery-root-identity")
    let displaced = root.deletingLastPathComponent().appending(
        path: "delivery-displaced-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let memoID = try MemoID("77777777-7777-7777-7777-777777777777")
    let journal = try DeliveryJournal(root: root)
    try journal.create(.received(
        memoID: memoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: deliveryDigest
    ))

    try FileManager.default.moveItem(at: root, to: displaced)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: root.path
    )

    #expect(throws: DeliveryJournalError.invalidRoot) {
        _ = try journal.load(memoID: memoID)
    }
    #expect(try DeliveryJournal(root: displaced).load(memoID: memoID).state == .received)
}

private func privateTemporaryDirectory(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
        path: "\(prefix)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
}

private let deliveryDigest = String(repeating: "ab", count: 32)
