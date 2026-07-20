@testable import CodexBridgeService
import CodexBridgeDelivery
import CodexBridgeShared
import Darwin
import Foundation
import Testing

private let retainedMemoID = try! MemoID("51515151-5151-5151-5151-515151515151")

@Test func deliveredRetentionArchivesVerifiedAudioThenPurgesBothDurableLayersAfterSevenDays() async throws {
    let fixture = try DeliveredRetentionFixture()
    let deliveredAt = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try IntakeStore(
        rootURL: fixture.intake,
        retentionRootURL: fixture.retained
    )
    let journal = try DeliveryJournal(root: fixture.delivery, clock: { deliveredAt })
    try await fixture.commit(into: store)
    try fixture.markDelivered(in: journal, at: deliveredAt)
    let beforeCutoff = try BridgeDeliveredRetentionController(
        intakeStore: store,
        journal: journal,
        retentionInterval: 7 * 24 * 60 * 60,
        clock: { deliveredAt.addingTimeInterval(6 * 24 * 60 * 60) }
    )

    let archived = try await beforeCutoff.performMaintenance()

    #expect(archived.archivedMemoIDs == [retainedMemoID])
    #expect(archived.purgedMemoIDs.isEmpty)
    #expect(try await store.committedRecord(for: retainedMemoID) == nil)
    let retained = try #require(try await store.retainedRecord(for: retainedMemoID))
    #expect(retained.memoID == retainedMemoID)
    #expect(retained.audioSHA256 == AudioDigest.hex(fixture.audio))
    #expect(retained.deliveredAt == deliveredAt)
    #expect(try Data(contentsOf: retained.audioURL) == fixture.audio)
    #expect(try journal.load(memoID: retainedMemoID).state == .delivered)

    let afterCutoff = try BridgeDeliveredRetentionController(
        intakeStore: store,
        journal: journal,
        retentionInterval: 7 * 24 * 60 * 60,
        clock: { deliveredAt.addingTimeInterval(8 * 24 * 60 * 60) }
    )
    let purged = try await afterCutoff.performMaintenance()

    #expect(purged.archivedMemoIDs.isEmpty)
    #expect(purged.purgedMemoIDs == [retainedMemoID])
    #expect(try await store.retainedRecord(for: retainedMemoID) == nil)
    #expect(throws: DeliveryJournalError.notFound) {
        _ = try journal.load(memoID: retainedMemoID)
    }
}

@Test func deliveredRetentionNeverArchivesOrPurgesAnUnresolvedMemo() async throws {
    let fixture = try DeliveredRetentionFixture()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try IntakeStore(
        rootURL: fixture.intake,
        retentionRootURL: fixture.retained
    )
    let journal = try DeliveryJournal(root: fixture.delivery, clock: { now })
    try await fixture.commit(into: store)
    try journal.create(.received(
        memoID: retainedMemoID,
        capturedAt: fixture.capturedAt,
        localeHint: "en-US",
        audioSHA256: AudioDigest.hex(fixture.audio),
        updatedAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
    ))
    let controller = try BridgeDeliveredRetentionController(
        intakeStore: store,
        journal: journal,
        retentionInterval: 7 * 24 * 60 * 60,
        clock: { now }
    )

    let result = try await controller.performMaintenance()

    #expect(result.archivedMemoIDs.isEmpty)
    #expect(result.purgedMemoIDs.isEmpty)
    #expect(try await store.committedRecord(for: retainedMemoID) != nil)
    #expect(try await store.retainedRecord(for: retainedMemoID) == nil)
    #expect(try journal.load(memoID: retainedMemoID).state == .received)
}

@Test func deliveredRetentionDefersPurgeForLiveRetryAndRecoversAfterJournalRemoval() async throws {
    let fixture = try DeliveredRetentionFixture()
    let deliveredAt = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try IntakeStore(
        rootURL: fixture.intake,
        retentionRootURL: fixture.retained
    )
    let journal = try DeliveryJournal(root: fixture.delivery, clock: { deliveredAt })
    try await fixture.commit(into: store)
    try fixture.markDelivered(in: journal, at: deliveredAt)
    let lease = RetentionPurgeRaceLease(root: fixture.intake, memoID: retainedMemoID)
    let request = try IntakeRequest(
        memoID: retainedMemoID,
        audioSHA256: AudioDigest.hex(fixture.audio),
        byteCount: fixture.audio.count,
        revision: 1,
        capturedAt: fixture.capturedAt,
        localeHint: "en-US"
    )
    let controller = try BridgeDeliveredRetentionController(
        intakeStore: store,
        journal: journal,
        retentionInterval: 7 * 24 * 60 * 60,
        clock: {
            lease.acquireOnce()
            return deliveredAt.addingTimeInterval(8 * 24 * 60 * 60)
        }
    )
    try await controller.retainDelivered(retainedMemoID)

    await #expect(throws: IntakeStoreError.inFlightWriter) {
        _ = try await controller.performMaintenance()
    }
    #expect(throws: DeliveryJournalError.notFound) {
        _ = try journal.load(memoID: retainedMemoID)
    }
    #expect(try await store.retainedRecord(for: retainedMemoID) != nil)

    lease.release()
    let retry = try await store.beginStreamingCommit(request: request)
    try await retry.append(fixture.audio)
    #expect(try await retry.finish(receivedAt: .distantFuture).disposition == .duplicate)
    let recovered = try await controller.performMaintenance()

    #expect(recovered.archivedMemoIDs.isEmpty)
    #expect(recovered.purgedMemoIDs == [retainedMemoID])
    #expect(try await store.retainedRecord(for: retainedMemoID) == nil)
    #expect(try await store.committedRecord(for: retainedMemoID) == nil)
}

@Test func deliveredRetentionMaintenanceLoopRunsPeriodicallyAndStopsOnCancellation() async {
    let sleeps = RetentionLoopSleepCounter()
    let probe = RetentionLoopProbe()
    let loop = Task {
        await BridgeRetentionMaintenanceLoop.run(
            interval: .seconds(60),
            sleep: { _ in
                if sleeps.incrementAndLoad() == 1 { return }
                try await Task.sleep(for: .seconds(60))
            },
            maintenance: {
                await probe.recordMaintenance()
            }
        )
    }

    await probe.waitForMaintenance()
    loop.cancel()
    await loop.value

    #expect(await probe.maintenanceCount == 1)
    #expect(sleeps.value >= 2)
}

@Test func deliveredRetentionMaintenanceLoopReportsFailureThenRetries() async {
    let probe = RetentionFailureProbe()
    let loop = Task {
        await BridgeRetentionMaintenanceLoop.run(
            interval: .seconds(60),
            sleep: { _ in try await probe.sleep() },
            onFailure: { await probe.recordFailure() },
            maintenance: { try await probe.performMaintenance() }
        )
    }

    await probe.waitForSuccess()
    loop.cancel()
    await loop.value

    #expect(await probe.failureCount == 1)
    #expect(await probe.maintenanceAttemptCount == 2)
}

private struct DeliveredRetentionFixture {
    let root: URL
    let intake: URL
    let retained: URL
    let delivery: URL
    let audio = Data("private-retained-audio".utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_699_999_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-delivered-retention-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        intake = root.appending(path: "intake", directoryHint: .isDirectory)
        retained = root.appending(path: "retained", directoryHint: .isDirectory)
        delivery = root.appending(path: "delivery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    func commit(into store: IntakeStore) async throws {
        _ = try await store.commit(
            request: IntakeRequest(
                memoID: retainedMemoID,
                audioSHA256: AudioDigest.hex(audio),
                byteCount: audio.count,
                revision: 1,
                capturedAt: capturedAt,
                localeHint: "en-US"
            ),
            body: audio,
            receivedAt: capturedAt
        )
    }

    func markDelivered(in journal: DeliveryJournal, at deliveredAt: Date) throws {
        try journal.create(.received(
            memoID: retainedMemoID,
            capturedAt: capturedAt,
            localeHint: "en-US",
            audioSHA256: AudioDigest.hex(audio),
            updatedAt: deliveredAt.addingTimeInterval(-1)
        ))
        _ = try journal.transition(memoID: retainedMemoID, to: .transcribing)
        _ = try journal.transition(
            memoID: retainedMemoID,
            to: .readyForCodex,
            transcript: "Retain this private idea"
        )
        _ = try journal.transition(memoID: retainedMemoID, to: .inserting)
        _ = try journal.transition(memoID: retainedMemoID, to: .reconciling)
        _ = try journal.transition(memoID: retainedMemoID, to: .delivered)
    }
}

private final class RetentionLoopSleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func incrementAndLoad() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class RetentionPurgeRaceLease: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var descriptor: Int32 = -1
    private var acquired = false

    init(root: URL, memoID: MemoID) {
        url = root.appending(
            path: ".incoming-\(memoID.rawValue)--\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
    }

    deinit {
        release()
    }

    func acquireOnce() {
        lock.withLock {
            guard !acquired else { return }
            acquired = true
            try! FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            precondition(descriptor >= 0)
            precondition(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        }
    }

    func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            descriptor = -1
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private actor RetentionLoopProbe {
    private(set) var maintenanceCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func recordMaintenance() {
        maintenanceCount += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForMaintenance() async {
        guard maintenanceCount == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor RetentionFailureProbe {
    enum ExpectedFailure: Error {
        case maintenance
    }

    private(set) var failureCount = 0
    private(set) var maintenanceAttemptCount = 0
    private var successWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepCount = 0

    func sleep() async throws {
        sleepCount += 1
        if sleepCount <= 2 { return }
        try await Task.sleep(for: .seconds(60))
    }

    func recordFailure() {
        failureCount += 1
    }

    func performMaintenance() throws {
        maintenanceAttemptCount += 1
        if maintenanceAttemptCount == 1 {
            throw ExpectedFailure.maintenance
        }
        let pending = successWaiters
        successWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForSuccess() async {
        guard maintenanceAttemptCount < 2 else { return }
        await withCheckedContinuation { successWaiters.append($0) }
    }
}
