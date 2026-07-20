@testable import CodexBridgeService
import CodexBridgeShared
import Darwin
import Foundation
import Testing

@Test func finalReceiptSurvivesRestartAndAcknowledgesIdempotently() async throws {
    let fixture = try FinalStatusFixture()
    let receipt = try fixture.receipt(revision: 8)
    let first = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 2)
    try await first.publish(receipt)

    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 2)
    #expect(try await restarted.receipt(for: receipt.memoID) == receipt)
    #expect(try await restarted.acknowledge(
        memoID: receipt.memoID,
        audioSHA256: receipt.audioSHA256,
        stateRevision: receipt.stateRevision
    ))
    #expect(try await restarted.receipt(for: receipt.memoID) == nil)
    let afterAcknowledgement = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 2)
    #expect(try await afterAcknowledgement.receipt(for: receipt.memoID) == nil)
    #expect(try await afterAcknowledgement.acknowledge(
        memoID: receipt.memoID,
        audioSHA256: receipt.audioSHA256,
        stateRevision: receipt.stateRevision
    ))
}

@Test func finalReceiptRejectsConflictingIdentityWithoutReplacingTruth() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 2)
    let original = try fixture.receipt(revision: 8)
    let duplicate = try FinalDeliveryReceipt(
        memoID: original.memoID,
        audioSHA256: original.audioSHA256,
        stateRevision: original.stateRevision,
        deliveredAt: original.deliveredAt.addingTimeInterval(1)
    )
    let conflict = try FinalDeliveryReceipt(
        memoID: original.memoID,
        audioSHA256: String(repeating: "b", count: 64),
        stateRevision: original.stateRevision,
        deliveredAt: original.deliveredAt
    )

    try await store.publish(original)
    try await store.publish(duplicate)
    await #expect(throws: FinalDeliveryStatusStoreError.identityConflict) {
        try await store.publish(conflict)
    }

    #expect(try await store.receipt(for: original.memoID) == original)
    #expect(try await store.acknowledge(
        memoID: original.memoID,
        audioSHA256: String(repeating: "c", count: 64),
        stateRevision: original.stateRevision
    ) == false)
    #expect(try await store.receipt(for: original.memoID) == original)
}

@Test func finalReceiptCapacityNeverEvictsUnacknowledgedTruth() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let first = try fixture.receipt(id: "81818181-8181-8181-8181-818181818181", revision: 8)
    let second = try fixture.receipt(id: "82828282-8282-8282-8282-828282828282", revision: 8)
    try await store.publish(first)
    await #expect(throws: FinalDeliveryStatusStoreError.capacityExceeded) {
        try await store.publish(second)
    }
    #expect(try await store.receipt(for: first.memoID) == first)
    #expect(try await store.count() == 1)
}

@Test func capacityReservationSurvivesRestartAndConvertsWithoutOverbooking() async throws {
    let fixture = try FinalStatusFixture()
    let first = try fixture.receipt(id: "83838383-8383-8383-8383-838383838383", revision: 8)
    let second = try fixture.receipt(id: "84848484-8484-8484-8484-848484848484", revision: 8)
    let initial = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)

    _ = try await initial.reserveCapacity(
        memoID: first.memoID,
        audioSHA256: first.audioSHA256
    )

    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    #expect(try await restarted.occupiedCount() == 1)
    await #expect(throws: FinalDeliveryStatusStoreError.capacityExceeded) {
        _ = try await restarted.reserveCapacity(
            memoID: second.memoID,
            audioSHA256: second.audioSHA256
        )
    }

    try await restarted.reconcileCapacityReservations(with: [
        first.memoID: first.audioSHA256,
    ])
    try await restarted.publish(first)
    #expect(try await restarted.receipt(for: first.memoID) == first)
    #expect(try await restarted.occupiedCount() == 1)
}

@Test func capacityReservationCancellationReleasesOnlyTheCallingLease() async throws {
    let fixture = try FinalStatusFixture()
    let receipt = try fixture.receipt(id: "85858585-8585-8585-8585-858585858585", revision: 8)
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let first = try await store.reserveCapacity(
        memoID: receipt.memoID,
        audioSHA256: receipt.audioSHA256
    )
    let second = try await store.reserveCapacity(
        memoID: receipt.memoID,
        audioSHA256: receipt.audioSHA256
    )

    try await store.cancelCapacityReservation(first)
    #expect(try await store.occupiedCount() == 1)
    try await store.cancelCapacityReservation(second)
    #expect(try await store.occupiedCount() == 0)
}

@Test func capacityReservationCommitSurvivesRequestLeaseCancellation() async throws {
    let fixture = try FinalStatusFixture()
    let receipt = try fixture.receipt(id: "86868686-8686-8686-8686-868686868686", revision: 8)
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let lease = try await store.reserveCapacity(
        memoID: receipt.memoID,
        audioSHA256: receipt.audioSHA256
    )

    try await store.commitCapacityReservation(lease)
    try await store.cancelCapacityReservation(lease)

    #expect(try await store.occupiedCount() == 1)
    try await store.reconcileCapacityReservations(with: [:])
    #expect(try await store.occupiedCount() == 0)
}

@Test func startupReconciliationBackfillsLegacyIntakeEvenAboveCapacity() async throws {
    let fixture = try FinalStatusFixture()
    let terminal = try fixture.receipt(id: "87878787-8787-8787-8787-878787878787", revision: 8)
    let legacy = try fixture.receipt(id: "88888888-8888-8888-8888-888888888888", revision: 8)
    let rejected = try fixture.receipt(id: "89898989-8989-8989-8989-898989898989", revision: 8)
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    try await store.publish(terminal)

    try await store.reconcileCapacityReservations(with: [
        legacy.memoID: legacy.audioSHA256,
    ])

    #expect(try await store.occupiedCount() == 2)
    #expect(try await store.receipt(for: legacy.memoID) == nil)
    await #expect(throws: FinalDeliveryStatusStoreError.capacityExceeded) {
        _ = try await store.reserveCapacity(
            memoID: rejected.memoID,
            audioSHA256: rejected.audioSHA256
        )
    }
    try await store.publish(legacy)
    #expect(try await store.receipt(for: legacy.memoID) == legacy)
    #expect(try await store.occupiedCount() == 2)
}

@Test func finalReceiptWriteFailureCleansTemporaryReceipt() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(
        rootURL: fixture.root,
        capacity: 1,
        faultInjector: { boundary in
            if boundary == .beforeRename { throw FinalStatusFault.injected }
        }
    )

    await #expect(throws: FinalDeliveryStatusStoreError.fileSystemFailure) {
        try await store.publish(try fixture.receipt(revision: 8))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
}

@Test func startupReconciliationRemovesSyncedOwnedTemporaryReceiptAfterAbruptExit() async throws {
    let fixture = try FinalStatusFixture()
    let receipt = try fixture.receipt(revision: 8)
    let temporaryURL = fixture.root.appending(
        path: ".final-receipt-11111111-2222-3333-4444-555555555555"
    )
    try fixture.writePrivate(JSONEncoder().encode(receipt), to: temporaryURL)
    let file = try FileHandle(forWritingTo: temporaryURL)
    try file.synchronize()
    try file.close()

    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    try await restarted.reconcileCapacityReservations(with: [:])

    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(try await restarted.occupiedCount() == 0)
}

@Test func startupReconciliationRejectsSymlinkAtOwnedTemporaryName() async throws {
    let fixture = try FinalStatusFixture()
    let temporaryURL = fixture.root.appending(
        path: ".final-receipt-21111111-2222-3333-4444-555555555555"
    )
    try FileManager.default.createSymbolicLink(
        at: temporaryURL,
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )
    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        try await restarted.reconcileCapacityReservations(with: [:])
    }
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
}

@Test func startupReconciliationRejectsHardLinkedOwnedTemporaryName() async throws {
    let fixture = try FinalStatusFixture()
    let sourceURL = FileManager.default.temporaryDirectory.appending(
        path: "codex-bridge-final-status-hardlink-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    try fixture.writePrivate(Data("orphan".utf8), to: sourceURL)
    let temporaryURL = fixture.root.appending(
        path: ".final-receipt-31111111-2222-3333-4444-555555555555"
    )
    guard link(sourceURL.path, temporaryURL.path) == 0 else {
        throw FinalStatusFault.injected
    }
    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        try await restarted.reconcileCapacityReservations(with: [:])
    }
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
}

@Test func startupReconciliationRejectsWrongModeOwnedTemporaryName() async throws {
    let fixture = try FinalStatusFixture()
    let temporaryURL = fixture.root.appending(
        path: ".final-receipt-41111111-2222-3333-4444-555555555555"
    )
    try fixture.writePrivate(Data("orphan".utf8), to: temporaryURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o640)],
        ofItemAtPath: temporaryURL.path
    )
    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        try await restarted.reconcileCapacityReservations(with: [:])
    }
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
}

@Test func startupReconciliationRejectsUnknownEntryWithoutRemovingIt() async throws {
    let fixture = try FinalStatusFixture()
    let unknownURL = fixture.root.appending(path: ".final-receipt-not-a-canonical-uuid")
    try fixture.writePrivate(Data("unknown".utf8), to: unknownURL)
    let restarted = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        try await restarted.reconcileCapacityReservations(with: [:])
    }
    #expect(FileManager.default.fileExists(atPath: unknownURL.path))
}

@Test func finalReceiptRejectsUnexpectedTopLevelContent() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)
    let receiptURL = fixture.root.appending(path: "\(receipt.memoID.rawValue).json")
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
    )
    object["transcript"] = "must not be accepted"
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: receiptURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: receiptURL.path
    )

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        _ = try await store.receipt(for: receipt.memoID)
    }
}

@Test func finalReceiptPinsRootAndReceiptToOwnerOnlyModes() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)

    #expect(try fixture.mode(of: fixture.root) == 0o700)
    try await store.publish(receipt)
    #expect(try fixture.mode(of: fixture.receiptURL(for: receipt)) == 0o600)
}

@Test func finalReceiptRejectsSymlinkReceiptFile() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)
    try FileManager.default.createSymbolicLink(
        at: fixture.receiptURL(for: receipt),
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )

    await #expect(throws: FinalDeliveryStatusStoreError.fileSystemFailure) {
        _ = try await store.receipt(for: receipt.memoID)
    }
}

@Test func finalReceiptRejectsReplacedRootDirectory() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    try FileManager.default.removeItem(at: fixture.root)
    try FileManager.default.createDirectory(
        at: fixture.root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    await #expect(throws: FinalDeliveryStatusStoreError.invalidRoot) {
        _ = try await store.count()
    }
}

@Test func finalReceiptRejectsHardLinkedReceiptFile() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)
    try await store.publish(receipt)
    let receiptURL = fixture.receiptURL(for: receipt)
    let linkURL = fixture.root.appending(path: "receipt-hard-link")
    guard link(receiptURL.path, linkURL.path) == 0 else {
        throw FinalStatusFault.injected
    }

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        _ = try await store.receipt(for: receipt.memoID)
    }
}

@Test func finalReceiptRejectsOversizedReceiptFile() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)
    try fixture.writePrivate(
        Data(repeating: 0, count: 4 * 1_024 + 1),
        to: fixture.receiptURL(for: receipt)
    )

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        _ = try await store.receipt(for: receipt.memoID)
    }
}

@Test func finalReceiptRejectsCorruptReceiptFile() async throws {
    let fixture = try FinalStatusFixture()
    let store = try FinalDeliveryStatusStore(rootURL: fixture.root, capacity: 1)
    let receipt = try fixture.receipt(revision: 8)
    try fixture.writePrivate(Data("not a receipt".utf8), to: fixture.receiptURL(for: receipt))

    await #expect(throws: FinalDeliveryStatusStoreError.invalidReceipt) {
        _ = try await store.receipt(for: receipt.memoID)
    }
}

@Test func finalReceiptFixtureRemovesItsOwnedTemporaryRoot() throws {
    var fixture: FinalStatusFixture? = try FinalStatusFixture()
    let root = try #require(fixture?.root)
    #expect(FileManager.default.fileExists(atPath: root.path))

    fixture = nil

    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test func finalReceiptFixturePreservesReplacementRootItDoesNotOwn() throws {
    var fixture: FinalStatusFixture? = try FinalStatusFixture()
    let root = try #require(fixture?.root)
    try FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    fixture = nil

    #expect(FileManager.default.fileExists(atPath: root.path))
}

private final class FinalStatusFixture {
    let root: URL
    private let deliveredAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let rootDevice: dev_t
    private let rootInode: ino_t

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "codex-bridge-final-status-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR
        else { throw FinalStatusFault.injected }
        rootDevice = metadata.st_dev
        rootInode = metadata.st_ino
    }

    deinit {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_dev == rootDevice,
              metadata.st_ino == rootInode
        else { return }
        try? FileManager.default.removeItem(at: root)
    }

    func receipt(
        id: String = "80808080-8080-8080-8080-808080808080",
        revision: UInt64
    ) throws -> FinalDeliveryReceipt {
        try FinalDeliveryReceipt(
            memoID: MemoID(id),
            audioSHA256: String(repeating: "a", count: 64),
            stateRevision: revision,
            deliveredAt: deliveredAt
        )
    }

    func receiptURL(for receipt: FinalDeliveryReceipt) -> URL {
        root.appending(path: "\(receipt.memoID.rawValue).json")
    }

    func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    func mode(of url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o7777
    }
}

private enum FinalStatusFault: Error {
    case injected
}
