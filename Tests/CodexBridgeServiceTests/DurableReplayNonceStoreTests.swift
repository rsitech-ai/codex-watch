@testable import CodexBridgeService
import Darwin
import Foundation
import Testing

@Test func acceptedNonceRemainsRejectedAfterRestartAndBackwardClockChange() async throws {
    let fixture = try ReplayFixture()
    let acceptedAt = Date(timeIntervalSince1970: 10_000)
    let first = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await first.consume(
        "nonce-1",
        acceptedAt: acceptedAt,
        expiresAt: acceptedAt.addingTimeInterval(600)
    ))

    let restarted = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await restarted.consume(
        "nonce-1",
        acceptedAt: acceptedAt.addingTimeInterval(-60),
        expiresAt: acceptedAt.addingTimeInterval(540)
    ) == false)
    try await restarted.prune(now: acceptedAt.addingTimeInterval(599))
    #expect(try await restarted.consume(
        "nonce-1",
        acceptedAt: acceptedAt,
        expiresAt: acceptedAt.addingTimeInterval(600)
    ) == false)
}

@Test func replayLedgerUsesPrivateRootAndLedgerPermissions() async throws {
    let fixture = try ReplayFixture()
    let store = try DurableReplayNonceStore(rootURL: fixture.root)
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(try await store.consume("permissions", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))

    var root = stat()
    var ledger = stat()
    #expect(lstat(fixture.root.path, &root) == 0)
    #expect(lstat(fixture.root.appendingPathComponent("replay-nonces.json").path, &ledger) == 0)
    #expect(root.st_mode & 0o7777 == 0o700)
    #expect(ledger.st_mode & 0o7777 == 0o600)
}

@Test func malformedReplayLedgerFailsClosed() async throws {
    let fixture = try ReplayFixture()
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
    try Data("not a replay ledger".utf8).write(
        to: fixture.root.appendingPathComponent("replay-nonces.json"),
        options: .atomic
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fixture.root.appendingPathComponent("replay-nonces.json").path
    )
    #expect(throws: DurableReplayNonceStoreError.self) {
        _ = try DurableReplayNonceStore(rootURL: fixture.root)
    }
}

@Test func replayLedgerRejectsSymlinkAndRootReplacement() async throws {
    let fixture = try ReplayFixture()
    let target = fixture.parent.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let symlink = fixture.parent.appendingPathComponent("symlink", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    #expect(throws: DurableReplayNonceStoreError.self) {
        _ = try DurableReplayNonceStore(rootURL: symlink)
    }

    let store = try DurableReplayNonceStore(rootURL: fixture.root)
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(try await store.consume("first", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))
    let moved = fixture.parent.appendingPathComponent("original", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)

    await #expect(throws: DurableReplayNonceStoreError.self) {
        try await store.consume("second", acceptedAt: now, expiresAt: now.addingTimeInterval(600))
    }
}

@Test func replayLedgerPrunesExpiredEntriesBeforeCapacityCheck() async throws {
    let fixture = try ReplayFixture()
    let store = try DurableReplayNonceStore(rootURL: fixture.root, capacity: 1)
    let now = Date(timeIntervalSince1970: 10_000)
    #expect(try await store.consume("old", acceptedAt: now, expiresAt: now.addingTimeInterval(1)))
    #expect(try await store.consume(
        "fresh",
        acceptedAt: now.addingTimeInterval(1),
        expiresAt: now.addingTimeInterval(601)
    ))
}

@Test func failedAtomicRenamePreservesPreviouslyAcceptedNonce() async throws {
    let fixture = try ReplayFixture()
    let now = Date(timeIntervalSince1970: 10_000)
    let first = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await first.consume("persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))
    let failing = try DurableReplayNonceStore(
        rootURL: fixture.root,
        faultInjector: { boundary in
            if boundary == .beforeRename { throw ReplayLedgerInjectedFailure.rename }
        }
    )

    await #expect(throws: DurableReplayNonceStoreError.self) {
        try await failing.consume("not-persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600))
    }

    let restarted = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await restarted.consume("persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600)) == false)
    #expect(try await restarted.consume("not-persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))
}

@Test func deletingInitializedLedgerFailsClosedForExistingAndReconstructedStores() async throws {
    let fixture = try ReplayFixture()
    let now = Date(timeIntervalSince1970: 10_000)
    let store = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await store.consume("persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("replay-nonces.json"))

    await #expect(throws: DurableReplayNonceStoreError.self) {
        try await store.consume("must-not-reset", acceptedAt: now, expiresAt: now.addingTimeInterval(600))
    }
    #expect(throws: DurableReplayNonceStoreError.self) {
        _ = try DurableReplayNonceStore(rootURL: fixture.root)
    }
}

@Test func rootNamespaceSwapAfterOpenFailsBeforeWritingAndBlocksRestart() async throws {
    let fixture = try ReplayFixture()
    let now = Date(timeIntervalSince1970: 10_000)
    let initial = try DurableReplayNonceStore(rootURL: fixture.root)
    #expect(try await initial.consume("persisted", acceptedAt: now, expiresAt: now.addingTimeInterval(600)))
    let swapper = RootNamespaceSwapper(parent: fixture.parent, root: fixture.root)
    let racing = try DurableReplayNonceStore(
        rootURL: fixture.root,
        faultInjector: { boundary in
            if boundary == .afterOpenBeforeMutation { try swapper.replaceRoot() }
        }
    )

    await #expect(throws: DurableReplayNonceStoreError.self) {
        try await racing.consume("must-not-write", acceptedAt: now, expiresAt: now.addingTimeInterval(600))
    }
    let displacedLedger = try String(
        decoding: Data(contentsOf: swapper.displacedRoot.appendingPathComponent("replay-nonces.json")),
        as: UTF8.self
    )
    #expect(!displacedLedger.contains("must-not-write"))
    #expect(throws: DurableReplayNonceStoreError.self) {
        _ = try DurableReplayNonceStore(rootURL: fixture.root)
    }
}

@Test func hugeReplayLedgerCapacityFailsValidationInsteadOfOverflowing() throws {
    let fixture = try ReplayFixture()

    #expect(throws: DurableReplayNonceStoreError.self) {
        _ = try DurableReplayNonceStore(rootURL: fixture.root, capacity: .max)
    }
}

@Test func maximumEscapedNoncesFitTheConfiguredLedgerCapacity() async throws {
    let fixture = try ReplayFixture()
    let capacity = 16
    let store = try DurableReplayNonceStore(rootURL: fixture.root, capacity: capacity)
    let now = Date(timeIntervalSince1970: 10_000)

    for index in 0 ..< capacity {
        let suffix = String(UnicodeScalar(0x20 + index)!)
        let nonce = String(repeating: "\\", count: 127) + suffix
        #expect(try await store.consume(
            nonce,
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(600)
        ))
    }

    await #expect(throws: DurableReplayNonceStoreError.self) {
        try await store.consume(
            "one-entry-too-many",
            acceptedAt: now,
            expiresAt: now.addingTimeInterval(600)
        )
    }
}

private enum ReplayLedgerInjectedFailure: Error {
    case rename
}

private final class RootNamespaceSwapper: @unchecked Sendable {
    let parent: URL
    let root: URL
    let displacedRoot: URL

    init(parent: URL, root: URL) {
        self.parent = parent
        self.root = root
        displacedRoot = parent.appendingPathComponent("displaced", isDirectory: true)
    }

    func replaceRoot() throws {
        try FileManager.default.moveItem(at: root, to: displacedRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

private final class ReplayFixture {
    let parent: URL
    let root: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "durable-replay-nonce-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        root = parent.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: parent)
    }
}
