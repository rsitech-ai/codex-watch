@testable import CodexBridgeService
import CodexBridgeShared
import Darwin
import Foundation
import Testing

private let streamingMemoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")

@Test func streamingWriterCommitsOneByteFragmentsDurably() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("fragmented-audio".utf8)
    let request = try fixture.request(body: body)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: request)

    let temporary = try #require(try fixture.temporaryDirectories().only)
    #expect(try fixture.mode(of: temporary) == 0o700)
    #expect(try fixture.mode(of: temporary.appendingPathComponent("audio.m4a")) == 0o600)
    for byte in body {
        try await writer.append(Data([byte]))
    }
    let result = try await writer.finish(receivedAt: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(result.disposition == .created)
    #expect(result.receipt.acknowledgedRevision == 2)
    #expect(try await store.audio(for: streamingMemoID) == body)
    #expect(try fixture.temporaryDirectories().isEmpty)
    #expect(try fixture.mode(of: fixture.committedAudioURL) == 0o600)
}

@Test func streamingCreationHoldsRootTransactionLock() async throws {
    let fixture = try StreamingIntakeFixture()
    let observation = RootTransactionLockObservation(root: fixture.root)
    let body = Data("locked-creation".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .afterAudioCreation {
                observation.capture()
            }
        }
    )

    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    #expect(observation.wasHeld == true)
    await writer.cancel()
}

@Test func streamingWriterAcceptsExactlyThirtyTwoMiB() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data(repeating: 0xA5, count: 32 * 1_024 * 1_024)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    let chunkSize = 64 * 1_024

    for offset in stride(from: 0, to: body.count, by: chunkSize) {
        try await writer.append(Data(body[offset ..< min(offset + chunkSize, body.count)]))
    }
    let result = try await writer.finish(receivedAt: .distantPast)

    #expect(result.disposition == .created)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.committedAudioURL.path)
    #expect((attributes[.size] as? NSNumber)?.intValue == body.count)
}

@Test func streamingWriterRejectsShortBodyAndCleansItsTemporaryState() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("short-body".utf8)
    let request = try IntakeRequest(
        memoID: streamingMemoID,
        audioSHA256: AudioDigest.hex(body),
        byteCount: body.count,
        revision: 1
    )
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: request)
    try await writer.append(body.dropLast())

    await #expect(throws: IntakeStoreError.lengthMismatch) {
        _ = try await writer.finish(receivedAt: .distantPast)
    }
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func streamingWriterRejectsExtraBodyBeforeWritingIt() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("exact".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await writer.append(body)

    await #expect(throws: IntakeStoreError.lengthMismatch) {
        try await writer.append(Data([0]))
    }
    #expect(try fixture.temporaryDirectories().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
}

@Test func streamingWriterRejectsDigestMismatchAndCleansItsTemporaryState() async throws {
    let fixture = try StreamingIntakeFixture()
    let expected = Data("expected".utf8)
    let supplied = Data("supplied".utf8)
    let request = try IntakeRequest(
        memoID: streamingMemoID,
        audioSHA256: AudioDigest.hex(expected),
        byteCount: supplied.count,
        revision: 1
    )
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: request)
    try await writer.append(supplied)

    await #expect(throws: IntakeStoreError.digestMismatch) {
        _ = try await writer.finish(receivedAt: .distantPast)
    }
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func terminalFailureCleanupHoldsRootTransactionLock() async throws {
    let fixture = try StreamingIntakeFixture()
    let observation = RootTransactionLockObservation(root: fixture.root)
    let expected = Data("expected-lock".utf8)
    let supplied = Data("supplied-lock".utf8)
    let request = try IntakeRequest(
        memoID: streamingMemoID,
        audioSHA256: AudioDigest.hex(expected),
        byteCount: supplied.count,
        revision: 1
    )
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .beforeOwnedCleanup {
                observation.capture()
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: request)
    try await writer.append(supplied)

    await #expect(throws: IntakeStoreError.digestMismatch) {
        _ = try await writer.finish(receivedAt: .distantPast)
    }

    #expect(observation.wasHeld == true)
}

@Test func streamingWriterCancelModelsDisconnectAndIsIdempotent() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("disconnect".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await writer.append(body.prefix(3))

    await writer.cancel()
    await writer.cancel()

    #expect(try fixture.temporaryDirectories().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
}

@Test func cancellationCleanupHoldsRootTransactionLock() async throws {
    let fixture = try StreamingIntakeFixture()
    let observation = RootTransactionLockObservation(root: fixture.root)
    let body = Data("locked-cancellation".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .beforeCancellationCleanup {
                observation.capture()
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    await writer.cancel()

    #expect(observation.wasHeld == true)
}

@Test func cancellationSynchronizesRootAfterQuarantineAndFinalRemoval() async throws {
    let fixture = try StreamingIntakeFixture()
    let synchronizer = RootSyncOperation()
    let body = Data("durable-cancellation".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        rootSyncOperation: { descriptor in
            synchronizer.synchronize(descriptor)
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    await writer.cancel()

    #expect(synchronizer.callCount == 2)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func quarantineSyncFailureRestoresAndSynchronizesOriginalNamespace() async throws {
    let fixture = try StreamingIntakeFixture()
    let synchronizer = RootSyncOperation(failingCalls: [1])
    let body = Data("restore-after-sync-failure".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        rootSyncOperation: { descriptor in
            synchronizer.synchronize(descriptor)
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    await writer.cancel()

    #expect(synchronizer.callCount == 2)
    #expect(try fixture.temporaryDirectories().count == 1)
    #expect(try fixture.cleanupDirectories().isEmpty)
}

@Test func restartRecoversCrashAfterDurableQuarantineRename() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("crash-after-quarantine".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .afterQuarantineRename {
                throw StreamingFixtureError.injected
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    await writer.cancel()

    #expect(try fixture.temporaryDirectories().isEmpty)
    #expect(try fixture.cleanupDirectories().count == 1)

    _ = try IntakeStore(rootURL: fixture.root)

    #expect(try fixture.cleanupDirectories().isEmpty)
}

@Test func finalRemovalRevalidatesQuarantineNameAgainstCapturedDescriptor() async throws {
    let fixture = try StreamingIntakeFixture()
    let swap = StreamingFinalNamespaceSwap()
    defer { swap.removeDisplacedAndReplacement() }
    let body = Data("final-revalidation".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, quarantineURL in
            if boundary == .beforeFinalDirectoryRemoval {
                try swap.replaceWithEmptyDirectory(at: quarantineURL)
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    await writer.cancel()

    #expect(swap.replacementDirectoryExists)
    #expect(swap.displacedDirectoryExists)
}

@Test func cancellationQuarantinesBeforeIdentityCheckAndPreservesNamespaceReplacement() async throws {
    let fixture = try StreamingIntakeFixture()
    let swap = StreamingNamespaceSwap()
    defer { swap.removeDisplaced() }
    let body = Data("cancel-race".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, temporaryURL in
            if boundary == .beforeCancellationCleanup {
                try swap.replaceDirectory(at: temporaryURL)
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await writer.append(body.prefix(2))

    await writer.cancel()

    #expect(try swap.replacementSentinel() == Data("replacement".utf8))
    #expect(swap.displacedDirectoryExists)
}

@Test func initializationFailureNeverUnlinksAReplacementAtTheTemporaryName() async throws {
    let fixture = try StreamingIntakeFixture()
    let swap = StreamingNamespaceSwap()
    defer { swap.removeDisplaced() }
    let body = Data("initialization-race".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, temporaryURL in
            switch boundary {
            case .afterAudioCreation:
                throw StreamingFixtureError.injected
            case .beforeInitializationCleanup:
                try swap.replaceDirectory(at: temporaryURL)
            default:
                break
            }
        }
    )

    await #expect(throws: IntakeStoreError.fileSystemFailure) {
        _ = try await store.beginStreamingCommit(request: fixture.request(body: body))
    }

    #expect(try swap.replacementSentinel() == Data("replacement".utf8))
    #expect(swap.displacedDirectoryExists)
}

@Test func duplicateUploadStillConsumesAndHashesWholeStreamWithoutOverwriting() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("original".utf8)
    let request = try fixture.request(body: body, revision: 4)
    let store = try IntakeStore(rootURL: fixture.root)
    let first = try await store.beginStreamingCommit(request: request)
    try await first.append(body)
    let created = try await first.finish(receivedAt: Date(timeIntervalSince1970: 10))

    let emptyDuplicate = try await store.beginStreamingCommit(request: request)
    await #expect(throws: IntakeStoreError.lengthMismatch) {
        _ = try await emptyDuplicate.finish(receivedAt: Date(timeIntervalSince1970: 20))
    }

    let duplicateWriter = try await store.beginStreamingCommit(request: request)
    for byte in body { try await duplicateWriter.append(Data([byte])) }
    let duplicate = try await duplicateWriter.finish(receivedAt: Date(timeIntervalSince1970: 30))

    #expect(duplicate.disposition == .duplicate)
    #expect(duplicate.receipt == created.receipt)
    #expect(try await store.audio(for: streamingMemoID) == body)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func publicationHoldsRootTransactionLock() async throws {
    let fixture = try StreamingIntakeFixture()
    let observation = RootTransactionLockObservation(root: fixture.root)
    let body = Data("locked-publication".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        mutationHook: { boundary, _ in
            if boundary == .beforePublication {
                observation.capture()
            }
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await writer.append(body)

    _ = try await writer.finish(receivedAt: .distantPast)

    #expect(observation.wasHeld == true)
}

@Test func duplicateContentWithDifferentRevisionConflicts() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("same-content".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let original = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 4)
    )
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)

    let differentRevision = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 5)
    )
    try await differentRevision.append(body)

    await #expect(throws: IntakeStoreError.identityConflict) {
        _ = try await differentRevision.finish(receivedAt: .distantPast)
    }
    #expect(try await store.audio(for: streamingMemoID) == body)
}

@Test func retainedDuplicateConsumesFullStreamAndReturnsAuthoritativeReceipt() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("retained-duplicate".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 4)
    )
    try await original.append(body)
    let originalResult = try await original.finish(
        receivedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await store.retainDelivered(
        memoID: streamingMemoID,
        deliveredAt: Date(timeIntervalSince1970: 1_700_000_200)
    )

    let duplicate = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 4)
    )
    for byte in body {
        try await duplicate.append(Data([byte]))
    }
    let duplicateResult = try await duplicate.finish(receivedAt: .distantFuture)

    #expect(duplicateResult.disposition == .duplicate)
    #expect(duplicateResult.receipt == originalResult.receipt)
    #expect(try await store.committedRecord(for: streamingMemoID) == nil)
    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func retainedDuplicateWithDifferentRevisionConflictsWithoutDualTruth() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("retained-revision-conflict".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 4)
    )
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)

    let conflict = try await store.beginStreamingCommit(
        request: fixture.request(body: body, revision: 5)
    )
    try await conflict.append(body)

    await #expect(throws: IntakeStoreError.identityConflict) {
        _ = try await conflict.finish(receivedAt: .distantFuture)
    }
    #expect(try await store.committedRecord(for: streamingMemoID) == nil)
    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func retainedDuplicateWithDifferentDigestConflictsWithoutDualTruth() async throws {
    let fixture = try StreamingIntakeFixture()
    let originalBody = Data("retained-original".utf8)
    let conflictingBody = Data("retained-conflict".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(
        request: fixture.request(body: originalBody)
    )
    try await original.append(originalBody)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)

    let conflict = try await store.beginStreamingCommit(
        request: fixture.request(body: conflictingBody)
    )
    try await conflict.append(conflictingBody)

    await #expect(throws: IntakeStoreError.identityConflict) {
        _ = try await conflict.finish(receivedAt: .distantFuture)
    }
    #expect(try await store.committedRecord(for: streamingMemoID) == nil)
    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func corruptRetainedDuplicateFailsClosedWithoutDeletionOrActivePublication() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("corrupt-retained-duplicate".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    let unknown = fixture.retainedDirectory.appendingPathComponent("unknown.bin")
    try Data("unknown".utf8).write(to: unknown, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: unknown.path
    )

    let duplicate = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await duplicate.append(body)

    await #expect(throws: IntakeStoreError.corruptRecord) {
        _ = try await duplicate.finish(receivedAt: .distantFuture)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
    #expect(FileManager.default.fileExists(atPath: fixture.retainedDirectory.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func activeAndRetainedDualTruthFailsClosedWithoutDeletingEitherRecord() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("dual-truth-duplicate".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    try FileManager.default.copyItem(
        at: fixture.retainedDirectory,
        to: fixture.committedDirectory
    )

    let duplicate = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await duplicate.append(body)

    await #expect(throws: IntakeStoreError.corruptRecord) {
        _ = try await duplicate.finish(receivedAt: .distantFuture)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
    #expect(FileManager.default.fileExists(atPath: fixture.retainedDirectory.path))
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func concurrentRetainAndDuplicateRetryCompleteWithoutDualTruth() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("concurrent-retain-and-retry".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    let originalResult = try await original.finish(receivedAt: .distantPast)
    let duplicate = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await duplicate.append(body)

    async let duplicateResult = duplicate.finish(receivedAt: .distantFuture)
    async let retained: Void = store.retainDelivered(
        memoID: streamingMemoID,
        deliveredAt: .distantPast
    )
    let result = try await duplicateResult
    try await retained

    #expect(result.disposition == .duplicate)
    #expect(result.receipt == originalResult.receipt)
    #expect(try await store.committedRecord(for: streamingMemoID) == nil)
    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func retainedPurgeCannotOvertakeFullyAppendedDuplicateWriter() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("purge-versus-live-retry".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    let originalResult = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    let retry = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await retry.append(body)

    await #expect(throws: IntakeStoreError.inFlightWriter) {
        try await store.removeRetained(
            memoID: streamingMemoID,
            deliveredBeforeOrAt: .distantFuture
        )
    }
    let result = try await retry.finish(receivedAt: .distantFuture)

    #expect(result.disposition == .duplicate)
    #expect(result.receipt == originalResult.receipt)
    #expect(try await store.committedRecord(for: streamingMemoID) == nil)
    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
}

@Test func differentMemoWriterDoesNotBlockRetainedPurge() async throws {
    let fixture = try StreamingIntakeFixture()
    let retainedBody = Data("retained-for-other-writer".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(
        request: fixture.request(body: retainedBody)
    )
    try await original.append(retainedBody)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)

    let otherMemoID = try MemoID("9ae8e660-9574-4e78-bc61-e9db141bb001")
    let otherBody = Data("unrelated-live-writer".utf8)
    let otherRequest = try IntakeRequest(
        memoID: otherMemoID,
        audioSHA256: AudioDigest.hex(otherBody),
        byteCount: otherBody.count,
        revision: 1
    )
    let other = try await store.beginStreamingCommit(request: otherRequest)
    try await other.append(otherBody)

    try await store.removeRetained(
        memoID: streamingMemoID,
        deliveredBeforeOrAt: .distantFuture
    )
    #expect(try await store.retainedRecord(for: streamingMemoID) == nil)
    #expect(try await other.finish(receivedAt: .distantFuture).disposition == .created)
}

@Test func unlockedMatchingInterruptedWriterDoesNotBlockRetainedPurge() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("retained-with-interrupted-writer".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    _ = try fixture.createUnlockedIncomingDirectory(memoID: streamingMemoID)

    try await store.removeRetained(
        memoID: streamingMemoID,
        deliveredBeforeOrAt: .distantFuture
    )

    #expect(try await store.retainedRecord(for: streamingMemoID) == nil)
}

@Test func noncanonicalMatchingWriterNamespaceFailsClosedDuringPurge() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("retained-with-unsafe-writer-name".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    _ = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    _ = try fixture.createUnlockedIncomingDirectory(
        name: ".incoming-\(streamingMemoID.rawValue)--not-a-uuid"
    )

    await #expect(throws: IntakeStoreError.corruptRecord) {
        try await store.removeRetained(
            memoID: streamingMemoID,
            deliveredBeforeOrAt: .distantFuture
        )
    }

    #expect(try await store.retainedRecord(for: streamingMemoID) != nil)
}

@Test func everySameMemoWriterMustReleaseBeforeRetainedPurge() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("multiple-live-retries".utf8)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    let original = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await original.append(body)
    let originalResult = try await original.finish(receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    let first = try await store.beginStreamingCommit(request: fixture.request(body: body))
    let second = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await first.append(body)
    try await second.append(body)

    await #expect(throws: IntakeStoreError.inFlightWriter) {
        try await store.removeRetained(
            memoID: streamingMemoID,
            deliveredBeforeOrAt: .distantFuture
        )
    }
    await first.cancel()
    await #expect(throws: IntakeStoreError.inFlightWriter) {
        try await store.removeRetained(
            memoID: streamingMemoID,
            deliveredBeforeOrAt: .distantFuture
        )
    }
    let result = try await second.finish(receivedAt: .distantFuture)
    #expect(result.disposition == .duplicate)
    #expect(result.receipt == originalResult.receipt)
    try await store.removeRetained(
        memoID: streamingMemoID,
        deliveredBeforeOrAt: .distantFuture
    )
    #expect(try await store.retainedRecord(for: streamingMemoID) == nil)
}

@Test func legacyRetainedDuplicateRejectsUnknownPrivateEntry() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("legacy-retained-unknown-entry".utf8)
    let request = try fixture.request(body: body)
    let store = try IntakeStore(rootURL: fixture.root, retentionRootURL: fixture.retainedRoot)
    _ = try await store.commit(request: request, body: body, receivedAt: .distantPast)
    try await store.retainDelivered(memoID: streamingMemoID, deliveredAt: .distantPast)
    let unknown = fixture.retainedDirectory.appendingPathComponent("unknown.bin")
    try Data("unknown".utf8).write(to: unknown, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: unknown.path
    )

    await #expect(throws: IntakeStoreError.corruptRecord) {
        _ = try await store.commit(request: request, body: body, receivedAt: .distantFuture)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
    #expect(FileManager.default.fileExists(atPath: fixture.retainedDirectory.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
}

@Test func streamingWriterRejectsDecodedMaximumRevisionWithoutOverflowing() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("revision-boundary".utf8)
    let valid = try fixture.request(body: body)
    let encoded = try JSONEncoder().encode(valid)
    let raw = String(decoding: encoded, as: UTF8.self)
    let forged = raw.replacingOccurrences(
        of: "\"revision\":1",
        with: "\"revision\":18446744073709551615"
    )
    let request = try JSONDecoder().decode(IntakeRequest.self, from: Data(forged.utf8))
    #expect(request.revision == UInt64.max)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: request)
    try await writer.append(body)

    await #expect(throws: IntakeStoreError.invalidRequest) {
        _ = try await writer.finish(receivedAt: .distantPast)
    }
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func conflictingUploadNeverReplacesCommittedIntake() async throws {
    let fixture = try StreamingIntakeFixture()
    let original = Data("original".utf8)
    let different = Data("different".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let first = try await store.beginStreamingCommit(request: fixture.request(body: original))
    try await first.append(original)
    _ = try await first.finish(receivedAt: .distantPast)

    let conflict = try await store.beginStreamingCommit(request: fixture.request(body: different))
    try await conflict.append(different)
    await #expect(throws: IntakeStoreError.identityConflict) {
        _ = try await conflict.finish(receivedAt: .distantPast)
    }

    #expect(try await store.audio(for: streamingMemoID) == original)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func streamingWriterRejectsReplacedAudioPathWithoutFollowingSymlink() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("symlink-attack".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    let temporary = try #require(try fixture.temporaryDirectories().only)
    let audio = temporary.appendingPathComponent("audio.m4a")
    try FileManager.default.removeItem(at: audio)
    try FileManager.default.createSymbolicLink(
        at: audio,
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )

    await #expect(throws: IntakeStoreError.fileSystemFailure) {
        try await writer.append(body)
    }

    #expect(try fixture.temporaryDirectories().isEmpty)
    let quarantine = try #require(try fixture.cleanupDirectories().only)
    let quarantinedAudio = quarantine.appendingPathComponent("audio.m4a")
    var metadata = stat()
    #expect(lstat(quarantinedAudio.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFLNK)
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
}

@Test func streamingWriterRejectsHardLinkedTemporaryAudio() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("hard-link".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    let temporary = try #require(try fixture.temporaryDirectories().only)
    let linked = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("codex-bridge-intake-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: linked) }
    #expect(link(temporary.appendingPathComponent("audio.m4a").path, linked.path) == 0)

    await #expect(throws: IntakeStoreError.fileSystemFailure) {
        try await writer.append(body)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.committedDirectory.path))
}

@Test func streamingWriterRejectsReplacedRootAndPreservesReplacement() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("root-swap".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    let displaced = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("codex-bridge-displaced-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.root, to: displaced)
    try FileManager.default.createDirectory(
        at: fixture.root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let sentinel = fixture.root.appendingPathComponent("sentinel")
    try Data("replacement".utf8).write(to: sentinel)
    defer {
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: displaced)
    }

    await #expect(throws: IntakeStoreError.invalidRoot) {
        try await writer.append(body)
    }
    #expect(try Data(contentsOf: sentinel) == Data("replacement".utf8))
}

@Test func streamingWriterNeverTraversesConflictingDestinationSymlink() async throws {
    let fixture = try StreamingIntakeFixture()
    let body = Data("destination".utf8)
    let store = try IntakeStore(rootURL: fixture.root)
    try FileManager.default.createSymbolicLink(
        at: fixture.committedDirectory,
        withDestinationURL: URL(fileURLWithPath: "/dev/null")
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))
    try await writer.append(body)

    await #expect(throws: IntakeStoreError.corruptRecord) {
        _ = try await writer.finish(receivedAt: .distantPast)
    }
    let values = try fixture.committedDirectory.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == true)
    #expect(try fixture.temporaryDirectories().isEmpty)
}

@Test func streamingWriterRetriesEINTRAndCompletesPartialWrites() async throws {
    let fixture = try StreamingIntakeFixture()
    let writes = PartialAndInterruptedWriteOperation()
    let body = Data("partial-and-interrupted".utf8)
    let store = try IntakeStore(
        rootURL: fixture.root,
        writeOperation: { descriptor, buffer, count in
            writes.write(descriptor: descriptor, buffer: buffer, count: count)
        }
    )
    let writer = try await store.beginStreamingCommit(request: fixture.request(body: body))

    try await writer.append(body)
    let result = try await writer.finish(receivedAt: .distantPast)

    #expect(result.disposition == .created)
    #expect(writes.interruptionCount == 1)
    #expect(writes.partialWriteCount == 1)
    #expect(try Data(contentsOf: fixture.committedAudioURL) == body)
}

private final class StreamingIntakeFixture {
    let root: URL
    let retainedRoot: URL
    let committedDirectory: URL
    let committedAudioURL: URL
    var retainedDirectory: URL {
        retainedRoot.appendingPathComponent(streamingMemoID.rawValue, isDirectory: true)
    }
    private let rootDevice: dev_t
    private let rootInode: ino_t

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bridge-streaming-tests-\(UUID().uuidString)", isDirectory: true)
        retainedRoot = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-retained", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        committedDirectory = root.appendingPathComponent(streamingMemoID.rawValue, isDirectory: true)
        committedAudioURL = committedDirectory.appendingPathComponent("audio.m4a")
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0 else { throw StreamingFixtureError.setup }
        rootDevice = metadata.st_dev
        rootInode = metadata.st_ino
    }

    deinit {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_dev == rootDevice,
              metadata.st_ino == rootInode
        else { return }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: retainedRoot)
    }

    func request(body: Data, revision: UInt64 = 1) throws -> IntakeRequest {
        try IntakeRequest(
            memoID: streamingMemoID,
            audioSHA256: AudioDigest.hex(body),
            byteCount: body.count,
            revision: revision
        )
    }

    func temporaryDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".incoming-") }
    }

    func cleanupDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".cleanup-") }
    }

    func createUnlockedIncomingDirectory(memoID: MemoID) throws -> URL {
        try createUnlockedIncomingDirectory(
            name: ".incoming-\(memoID.rawValue)--\(UUID().uuidString.lowercased())"
        )
    }

    func createUnlockedIncomingDirectory(name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let audio = directory.appendingPathComponent("audio.m4a")
        try Data("interrupted".utf8).write(to: audio, options: .withoutOverwriting)
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

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private enum StreamingFixtureError: Error {
    case setup
    case injected
}

private final class StreamingNamespaceSwap: @unchecked Sendable {
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
                .appendingPathComponent("codex-bridge-displaced-temp-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: moved)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            let sentinel = url.appendingPathComponent("sentinel")
            try Data("replacement".utf8).write(to: sentinel)
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

private final class PartialAndInterruptedWriteOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private(set) var interruptionCount = 0
    private(set) var partialWriteCount = 0

    func write(descriptor: Int32, buffer: UnsafeRawPointer?, count: Int) -> Int {
        lock.withLock {
            callCount += 1
            if callCount == 1 {
                interruptionCount += 1
                errno = EINTR
                return -1
            }
            if callCount == 2 {
                partialWriteCount += 1
                return Darwin.write(descriptor, buffer, min(2, count))
            }
            return Darwin.write(descriptor, buffer, count)
        }
    }
}

private final class RootTransactionLockObservation: @unchecked Sendable {
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

private final class RootSyncOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let failingCalls: Set<Int>
    private var calls = 0

    init(failingCalls: Set<Int> = []) {
        self.failingCalls = failingCalls
    }

    var callCount: Int {
        lock.withLock { calls }
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

private final class StreamingFinalNamespaceSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var displaced: URL?
    private var replacement: URL?

    var replacementDirectoryExists: Bool {
        lock.withLock {
            guard let replacement else { return false }
            return FileManager.default.fileExists(atPath: replacement.path)
        }
    }

    var displacedDirectoryExists: Bool {
        lock.withLock {
            guard let displaced else { return false }
            return FileManager.default.fileExists(atPath: displaced.path)
        }
    }

    func replaceWithEmptyDirectory(at url: URL) throws {
        try lock.withLock {
            guard displaced == nil else { return }
            let moved = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("codex-bridge-final-displaced-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: moved)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            displaced = moved
            replacement = url
        }
    }

    func removeDisplacedAndReplacement() {
        lock.withLock {
            if let replacement { try? FileManager.default.removeItem(at: replacement) }
            if let displaced { try? FileManager.default.removeItem(at: displaced) }
            replacement = nil
            displaced = nil
        }
    }
}
