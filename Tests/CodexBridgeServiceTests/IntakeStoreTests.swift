@testable import CodexBridgeService
import CodexBridgeShared
import Darwin
import Foundation
import Testing

private let intakeMemoID = try! MemoID("223e4567-e89b-12d3-a456-426614174000")

@Test func restartPreservesLiveWriterThenRecoversIncomingAfterLeaseRelease() async throws {
    let fixture = try TemporaryIntakeFixture()
    let body = Data("interrupted".utf8)
    let request = try fixture.request(body: body)
    let synchronizer = IntakeRootSyncOperation(failingCalls: [1])
    let first = try IntakeStore(
        rootURL: fixture.root,
        rootSyncOperation: { descriptor in
            synchronizer.synchronize(descriptor)
        }
    )
    let writer = try await first.beginStreamingCommit(request: request)
    try await writer.append(body.prefix(3))
    let liveIncoming = try #require(try fixture.incomingNames().only)

    _ = try IntakeStore(rootURL: fixture.root)

    #expect(try fixture.incomingNames() == [liveIncoming])
    await writer.cancel()
    #expect(try fixture.incomingNames() == [liveIncoming])

    _ = try IntakeStore(rootURL: fixture.root)

    #expect(try fixture.incomingNames().isEmpty)
}

@Test func intakeStoreStreamingCommitSurvivesRestartWithPrivateFiles() async throws {
    let fixture = try TemporaryIntakeFixture()
    let body = Data("audio-data".utf8)
    let request = try fixture.request(body: body)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: request)
    try await writer.append(body)
    let result = try await writer.finish(receivedAt: Date(timeIntervalSince1970: 1_700_000_100))
    let restarted = try IntakeStore(rootURL: fixture.root)

    #expect(result.disposition == .created)
    #expect(try await restarted.receipt(for: intakeMemoID) == result.receipt)
    #expect(try await restarted.audio(for: intakeMemoID) == body)
    let committed = try #require(try await restarted.committedAudioAsset(for: intakeMemoID))
    #expect(committed.byteCount == body.count)
    #expect(throws: Never.self) { try committed.validate() }
    #expect(try fixture.mode(of: fixture.root) == 0o700)
    #expect(try fixture.mode(of: committed.url) == 0o600)
}

@Test func restartCleanupQuarantinesBeforeCheckingCapturedDirectoryIdentity() throws {
    let fixture = try TemporaryIntakeFixture()
    let temporary = fixture.root.appendingPathComponent(
        ".incoming-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: temporary,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let audio = temporary.appendingPathComponent("audio.m4a")
    try Data("partial".utf8).write(to: audio)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: audio.path
    )
    let swap = RestartNamespaceSwap()
    defer { swap.removeDisplaced() }

    #expect(throws: IntakeStoreError.fileSystemFailure) {
        _ = try IntakeStore(
            rootURL: fixture.root,
            mutationHook: { boundary, temporaryURL in
                if boundary == .beforeRestartCleanup {
                    try swap.replaceDirectory(at: temporaryURL)
                }
            }
        )
    }

    #expect(try swap.replacementSentinel() == Data("restart-replacement".utf8))
    #expect(swap.displacedDirectoryExists)
}

@Test func restartRecoveryHoldsRootTransactionLock() throws {
    let fixture = try TemporaryIntakeFixture()
    let temporary = try fixture.createInterruptedDirectory(prefix: ".incoming-")
    let observation = IntakeRootTransactionLockObservation(root: fixture.root)

    _ = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .beforeRestartCleanup {
                observation.capture()
            }
        }
    )

    #expect(observation.wasHeld == true)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
}

@Test func restartRecoveryRemovesValidatedCleanupQuarantine() throws {
    let fixture = try TemporaryIntakeFixture()
    let quarantine = try fixture.createInterruptedDirectory(prefix: ".cleanup-")

    _ = try IntakeStore(rootURL: fixture.root)

    #expect(!FileManager.default.fileExists(atPath: quarantine.path))
    #expect(try fixture.cleanupNames().isEmpty)
}

@Test func restartRecoveryPreservesInvalidIncomingEntryInQuarantine() throws {
    let fixture = try TemporaryIntakeFixture()
    let incoming = try fixture.createInterruptedDirectory(prefix: ".incoming-")
    let unexpected = incoming.appendingPathComponent("unexpected")
    try Data("preserve-me".utf8).write(to: unexpected)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: unexpected.path
    )

    #expect(throws: IntakeStoreError.fileSystemFailure) {
        _ = try IntakeStore(rootURL: fixture.root)
    }

    #expect(try fixture.incomingNames().isEmpty)
    let quarantineName = try #require(try fixture.cleanupNames().only)
    let preserved = fixture.root.appendingPathComponent(quarantineName)
        .appendingPathComponent("unexpected")
    #expect(try Data(contentsOf: preserved) == Data("preserve-me".utf8))
}

@Test func restartRecoveryQuarantinesEntryBeforeRejectingUnprovableChildIdentity() throws {
    let fixture = try TemporaryIntakeFixture()
    let incoming = try fixture.createInterruptedDirectory(prefix: ".incoming-")
    let unexpected = incoming.appendingPathComponent("unexpected-link")
    try FileManager.default.createSymbolicLink(
        at: unexpected,
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )

    #expect(throws: IntakeStoreError.fileSystemFailure) {
        _ = try IntakeStore(rootURL: fixture.root)
    }

    #expect(try fixture.incomingNames().isEmpty)
    let quarantineName = try #require(try fixture.cleanupNames().only)
    let preserved = fixture.root.appendingPathComponent(quarantineName)
        .appendingPathComponent("unexpected-link")
    let values = try preserved.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == true)
}

@Test func restartRecoveryPreservesUnprovableTopLevelEntryInQuarantine() throws {
    let fixture = try TemporaryIntakeFixture()
    let incoming = fixture.root.appendingPathComponent(
        ".incoming-\(UUID().uuidString.lowercased())"
    )
    try FileManager.default.createSymbolicLink(
        at: incoming,
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )

    #expect(throws: IntakeStoreError.fileSystemFailure) {
        _ = try IntakeStore(rootURL: fixture.root)
    }

    #expect(try fixture.incomingNames().isEmpty)
    let quarantineName = try #require(try fixture.cleanupNames().only)
    let preserved = fixture.root.appendingPathComponent(quarantineName)
    let values = try preserved.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == true)
}

@Test func intakeStoreRepairsRootModeButRejectsRootSymlink() throws {
    let fixture = try TemporaryIntakeFixture()
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: fixture.root.path
    )
    _ = try IntakeStore(rootURL: fixture.root)
    #expect(try fixture.mode(of: fixture.root) == 0o700)

    let symlink = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("codex-bridge-intake-symlink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: symlink) }
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.root)
    #expect(throws: IntakeStoreError.invalidRoot) {
        _ = try IntakeStore(rootURL: symlink)
    }
}

@Test func intakeRequestEnforcesThirtyTwoMiBStreamingBound() {
    #expect(throws: IntakeStoreError.invalidRequest) {
        _ = try IntakeRequest(
            memoID: intakeMemoID,
            audioSHA256: String(repeating: "a", count: 64),
            byteCount: 32 * 1_024 * 1_024 + 1,
            revision: 1
        )
    }
}

@Test func legacyCompatibilityCommitAlsoRejectsDecodedMaximumRevision() async throws {
    let fixture = try TemporaryIntakeFixture()
    let body = Data("legacy-revision-boundary".utf8)
    let valid = try fixture.request(body: body)
    let encoded = try JSONEncoder().encode(valid)
    let forged = String(decoding: encoded, as: UTF8.self).replacingOccurrences(
        of: "\"revision\":1",
        with: "\"revision\":18446744073709551615"
    )
    let request = try JSONDecoder().decode(IntakeRequest.self, from: Data(forged.utf8))
    let store = try IntakeStore(rootURL: fixture.root)

    await #expect(throws: IntakeStoreError.invalidRequest) {
        _ = try await store.commit(request: request, body: body)
    }
}

@Test func legacyCompatibilityCommitHoldsRootTransactionLockDuringPublication() async throws {
    let fixture = try TemporaryIntakeFixture()
    let observation = IntakeRootTransactionLockObservation(root: fixture.root)
    let body = Data("legacy-lock".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .beforePublication {
                observation.capture()
            }
        }
    )

    _ = try await store.commit(request: fixture.request(body: body), body: body)

    #expect(observation.wasHeld == true)
}

private final class TemporaryIntakeFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bridge-intake-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func request(body: Data) throws -> IntakeRequest {
        try IntakeRequest(
            memoID: intakeMemoID,
            audioSHA256: AudioDigest.hex(body),
            byteCount: body.count,
            revision: 1
        )
    }

    func incomingNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".incoming-") }
    }

    func cleanupNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".cleanup-") }
    }

    func createInterruptedDirectory(prefix: String) throws -> URL {
        let directory = root.appendingPathComponent(
            "\(prefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let audio = directory.appendingPathComponent("audio.m4a")
        try Data("partial".utf8).write(to: audio)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: audio.path
        )
        return directory
    }

    func mode(of url: URL) throws -> Int {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o7777
    }
}

private final class RestartNamespaceSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var displaced: URL?
    private var replacement: URL?

    var displacedDirectoryExists: Bool {
        lock.withLock {
            guard let displaced else { return false }
            return FileManager.default.fileExists(atPath: displaced.path)
        }
    }

    func replaceDirectory(at url: URL) throws {
        try lock.withLock {
            guard displaced == nil else { return }
            let moved = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("codex-bridge-restart-displaced-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: moved)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let sentinel = url.appendingPathComponent("sentinel")
            try Data("restart-replacement".utf8).write(to: sentinel)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: sentinel.path
            )
            displaced = moved
            replacement = url
        }
    }

    func replacementSentinel() throws -> Data {
        try lock.withLock {
            let replacement = try #require(replacement)
            return try Data(contentsOf: replacement.appendingPathComponent("sentinel"))
        }
    }

    func removeDisplaced() {
        lock.withLock {
            if let displaced { try? FileManager.default.removeItem(at: displaced) }
            displaced = nil
        }
    }
}

private final class IntakeRootTransactionLockObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var captured: Bool?

    init(root: URL) {
        self.root = root
    }

    var wasHeld: Bool? {
        lock.withLock { captured }
    }

    func capture() {
        lock.withLock {
            let descriptor = Darwin.open(
                root.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                captured = false
                return
            }
            defer { Darwin.close(descriptor) }

            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(descriptor, LOCK_UN)
                captured = false
            } else {
                captured = errno == EWOULDBLOCK
            }
        }
    }
}

private final class IntakeRootSyncOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCalls: Set<Int>
    private var calls = 0

    init(failingCalls: Set<Int> = []) {
        self.failingCalls = failingCalls
    }

    func synchronize(_ descriptor: Int32) -> Int32 {
        let shouldFail = lock.withLock {
            calls += 1
            return failingCalls.contains(calls)
        }
        if shouldFail {
            errno = EIO
            return -1
        }
        return Darwin.fsync(descriptor)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
