@testable import CodexBridgeService
import CodexBridgeDelivery
import CodexBridgeShared
import Foundation
import Testing

@Test func terminalTruthIsDurableBeforeProductionArchival() async throws {
    let fixture = try CompletionFixture()
    try await fixture.prepareDeliveredMemo()
    let events = CompletionEventRecorder()
    let publisher = DeliveryCompletionPublisher(
        intakeStore: fixture.intake,
        journal: fixture.journal,
        finalStatusStore: fixture.finalStatuses,
        retainDelivered: { memoID in
            let receipt = try await fixture.finalStatuses.receipt(for: memoID)
            #expect(receipt != nil)
            await events.append("retained")
        }
    )

    try await publisher.publishAndRetain(fixture.memoID)

    #expect(await events.values == ["retained"])
    let receipt = try #require(try await fixture.finalStatuses.receipt(for: fixture.memoID))
    #expect(receipt.audioSHA256 == AudioDigest.hex(fixture.audio))
    #expect(receipt.stateRevision == 7)
    #expect(receipt.deliveredAt == fixture.deliveredAt)
}

@Test func terminalTruthIsDurableAcrossRetentionRetryAfterArchival() async throws {
    let fixture = try CompletionFixture()
    try await fixture.prepareDeliveredMemo()
    let attempts = CompletionAttemptCounter()
    let publisher = DeliveryCompletionPublisher(
        intakeStore: fixture.intake,
        journal: fixture.journal,
        finalStatusStore: fixture.finalStatuses,
        retainDelivered: { memoID in
            try await fixture.intake.retainDelivered(
                memoID: memoID,
                deliveredAt: fixture.deliveredAt
            )
            if await attempts.incrementAndLoad() == 1 {
                throw CompletionTestError.afterArchival
            }
        }
    )

    await #expect(throws: CompletionTestError.afterArchival) {
        try await publisher.publishAndRetain(fixture.memoID)
    }
    #expect(try await fixture.intake.committedRecord(for: fixture.memoID) == nil)
    #expect(try await fixture.intake.retainedRecord(for: fixture.memoID) != nil)
    let terminal = try #require(try await fixture.finalStatuses.receipt(for: fixture.memoID))
    #expect(try await fixture.finalStatuses.acknowledge(
        memoID: terminal.memoID,
        audioSHA256: terminal.audioSHA256,
        stateRevision: terminal.stateRevision
    ))
    #expect(try await fixture.finalStatuses.receipt(for: fixture.memoID) == nil)

    try await publisher.publishAndRetain(fixture.memoID)

    #expect(await attempts.value == 2)
}

private struct CompletionFixture: Sendable {
    let memoID = try! MemoID("71717171-7171-7171-7171-717171717171")
    let audio = Data("terminal-truth-before-archive".utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let deliveredAt: Date
    let intake: IntakeStore
    let journal: DeliveryJournal
    let finalStatuses: FinalDeliveryStatusStore

    init() throws {
        let deliveredAt = Date(timeIntervalSince1970: 1_700_000_100)
        self.deliveredAt = deliveredAt
        let root = FileManager.default.temporaryDirectory.appending(
            path: "delivery-completion-publisher-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        intake = try IntakeStore(
            rootURL: root.appending(path: "intake", directoryHint: .isDirectory),
            retentionRootURL: root.appending(path: "retained", directoryHint: .isDirectory)
        )
        journal = try DeliveryJournal(
            root: root.appending(path: "delivery", directoryHint: .isDirectory),
            clock: { deliveredAt }
        )
        finalStatuses = try FinalDeliveryStatusStore(
            rootURL: root.appending(path: "final-status", directoryHint: .isDirectory)
        )
    }

    func prepareDeliveredMemo() async throws {
        _ = try await intake.commit(
            request: IntakeRequest(
                memoID: memoID,
                audioSHA256: AudioDigest.hex(audio),
                byteCount: audio.count,
                revision: 1,
                capturedAt: capturedAt,
                localeHint: "en-US"
            ),
            body: audio,
            receivedAt: capturedAt
        )
        try journal.create(.received(
            memoID: memoID,
            capturedAt: capturedAt,
            localeHint: "en-US",
            audioSHA256: AudioDigest.hex(audio),
            updatedAt: capturedAt
        ))
        _ = try journal.transition(memoID: memoID, to: .transcribing)
        _ = try journal.transition(memoID: memoID, to: .readyForCodex, transcript: "Ship this idea")
        _ = try journal.transition(memoID: memoID, to: .inserting)
        _ = try journal.transition(memoID: memoID, to: .reconciling)
        _ = try journal.transition(memoID: memoID, to: .delivered)
    }
}

private actor CompletionEventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private actor CompletionAttemptCounter {
    private(set) var value = 0

    func incrementAndLoad() -> Int {
        value += 1
        return value
    }
}

private enum CompletionTestError: Error {
    case afterArchival
}
