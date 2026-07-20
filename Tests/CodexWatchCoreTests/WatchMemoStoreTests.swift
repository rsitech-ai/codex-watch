@testable import CodexWatchCore
import CodexBridgeShared
import Darwin
import Foundation
import Testing

private let storeMemoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")
private let secondMemoID = try! MemoID("223e4567-e89b-12d3-a456-426614174000")

@Test func finalAcknowledgementAndDeliveredStateSurviveRestartUntilAcknowledged() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        let audio = Data("durable final acknowledgement".utf8)
        try audio.write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let delivered = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .delivered,
            revision: 7
        )
        let acknowledgement = FinalDeliveryAcknowledgement(
            memoID: storeMemoID,
            audioSHA256: delivered.audioSHA256,
            stateRevision: delivered.stateRevision
        )

        #expect(try await store.pendingFinalAcknowledgements() == [acknowledgement])
        let restarted = try WatchMemoStore(root: root)
        #expect(try await restarted.load(memoID: storeMemoID).metadata == delivered)
        #expect(try await restarted.pendingFinalAcknowledgements() == [acknowledgement])

        try await restarted.markFinalAcknowledged(acknowledgement)
        #expect(try await restarted.pendingFinalAcknowledgements().isEmpty)
        #expect(try await restarted.load(memoID: storeMemoID).metadata == delivered)
    }
}

@Test func stagedFinalAcknowledgementRecoversAfterDeliveredMetadataCrashWindow() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("crash-window final acknowledgement".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let delivered = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .delivered,
            revision: 9
        )
        let acknowledgement = FinalDeliveryAcknowledgement(
            memoID: storeMemoID,
            audioSHA256: delivered.audioSHA256,
            stateRevision: delivered.stateRevision
        )
        // ponytail: simulate crash after delivered metadata, before pending-ack publish
        let published = root
            .appendingPathComponent("Delivered", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).final-ack", isDirectory: false)
        let staged = root
            .appendingPathComponent("Temporary", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).final-ack.tmp", isDirectory: false)
        try FileManager.default.moveItem(at: published, to: staged)

        let recovered = try WatchMemoStore(root: root)
        #expect(try await recovered.load(memoID: storeMemoID).metadata == delivered)
        #expect(try await recovered.pendingFinalAcknowledgements() == [acknowledgement])
        #expect(FileManager.default.fileExists(atPath: published.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}

@Test func committedRecordingSurvivesStoreRelaunchWithPrivatePermissions() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("durable voice idea".utf8).write(to: temporary)

        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 1_250,
            localeHint: "en-US"
        )
        let relaunched = try WatchMemoStore(root: root)
        let pending = try await relaunched.loadPending()

        #expect(pending.count == 1)
        #expect(pending.first?.metadata == committed.metadata)
        #expect(try Data(contentsOf: committed.audioURL) == Data("durable voice idea".utf8))
        #expect(try permissions(of: root) == 0o700)
        #expect(try permissions(of: committed.audioURL) == 0o600)
        #expect(try permissions(of: committed.metadataURL) == 0o600)
    }
}

@Test func pairingBarrierSurvivesStoreRelaunchUntilExplicitlyCleared() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)

        try await store.markPairingRequired()
        #expect(try await store.pairingIsRequired())

        let relaunched = try WatchMemoStore(root: root)
        #expect(try await relaunched.pairingIsRequired())

        try await relaunched.clearPairingRequirement()
        #expect(try await !relaunched.pairingIsRequired())
        #expect(try await !WatchMemoStore(root: root).pairingIsRequired())
    }
}

@Test func duplicateCommitIsIdempotentOnlyForIdenticalAudio() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let first = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("same".utf8).write(to: first)
        let committed = try await store.commitRecording(
            temporaryURL: first,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 100,
            localeHint: nil
        )

        let duplicate = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("same".utf8).write(to: duplicate)
        let existing = try await store.commitRecording(
            temporaryURL: duplicate,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_999),
            durationMilliseconds: 999,
            localeHint: "pl-PL"
        )
        #expect(existing.metadata == committed.metadata)

        let conflict = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("different".utf8).write(to: conflict)
        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: conflict,
                memoID: storeMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }
    }
}

@Test func emptyOversizedAndSymlinkRecordingsFailClosed() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let empty = await store.temporaryRecordingURL(for: storeMemoID)
        try Data().write(to: empty)
        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: empty,
                memoID: storeMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }

        let outside = root.appendingPathComponent("outside.m4a")
        try Data("audio".utf8).write(to: outside)
        let linked = await store.temporaryRecordingURL(for: secondMemoID)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: linked,
                memoID: secondMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }
    }
}

@Test func corruptCommittedPairIsQuarantinedAndNeverReturned() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("original".utf8).write(to: temporary)
        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(),
            durationMilliseconds: 100,
            localeHint: nil
        )
        try Data("tampered".utf8).write(to: committed.audioURL)

        #expect(try await store.loadPending().isEmpty)
        #expect(try await store.quarantinedEntryNames().count == 2)
    }
}

@Test func activeUploadLeasePreventsCorruptPairQuarantineUntilReleased() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("leased quarantine".utf8).write(to: temporary)
        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let lease = try await store.acquireUploadLease(memoID: storeMemoID)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: committed.metadataURL.path
        )
        #expect(try await store.loadPending().isEmpty)
        #expect(try await store.quarantinedEntryNames().isEmpty)
        #expect(FileManager.default.fileExists(atPath: committed.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: committed.metadataURL.path))

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: committed.metadataURL.path
        )
        #expect(await store.releaseUploadLease(lease))
        #expect(!(await store.releaseUploadLease(lease)))

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: committed.metadataURL.path
        )
        #expect(try await store.loadPending().isEmpty)
        #expect(try await store.quarantinedEntryNames().count == 2)
        #expect(!FileManager.default.fileExists(atPath: committed.audioURL.path))
        #expect(!FileManager.default.fileExists(atPath: committed.metadataURL.path))
    }
}

@Test func transientFinalizationRequiresCurrentTokenAndPublishesStateWithRetry() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("exact transient token".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let staleLease = try await store.acquireUploadLease(memoID: storeMemoID)
        #expect(await store.releaseUploadLease(staleLease))
        _ = try await store.recoverInterruptedUpload(memoID: storeMemoID)
        let currentLease = try await store.acquireUploadLease(memoID: storeMemoID)
        let retryDate = Date(timeIntervalSince1970: 1_700_000_002)

        await #expect(throws: WatchMemoStoreError.invalidState) {
            _ = try await store.finishUploadLease(
                staleLease,
                state: .saved,
                retryNotBefore: retryDate
            )
        }
        #expect(try await store.load(memoID: storeMemoID).metadata == currentLease.metadata)
        #expect(try await store.retryNotBefore(memoID: storeMemoID) == nil)

        let saved = try await store.finishUploadLease(
            currentLease,
            state: .saved,
            retryNotBefore: retryDate
        )
        #expect(saved.state == .saved)
        #expect(saved.stateRevision == 4)
        #expect(try await store.retryNotBefore(memoID: storeMemoID) == retryDate)
        #expect(!(await store.releaseUploadLease(currentLease)))
    }
}

@Test func sameSizeAudioTamperingWithRestoredModificationTimeIsDetected() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("original".utf8).write(to: temporary)
        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(),
            durationMilliseconds: 100,
            localeHint: nil
        )
        _ = try await store.load(memoID: storeMemoID)

        var originalMetadata = stat()
        #expect(lstat(committed.audioURL.path, &originalMetadata) == 0)
        try Data("tampered".utf8).write(to: committed.audioURL)
        var times = [originalMetadata.st_atimespec, originalMetadata.st_mtimespec]
        let restoreResult = times.withUnsafeMutableBufferPointer { buffer in
            utimensat(AT_FDCWD, committed.audioURL.path, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
        }
        #expect(restoreResult == 0)

        #expect(try await store.loadPending().isEmpty)
        #expect(try await store.quarantinedEntryNames().count == 2)
    }
}

@Test func relaxedCommittedPermissionsAreQuarantined() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("private".utf8).write(to: temporary)
        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(),
            durationMilliseconds: 100,
            localeHint: nil
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: committed.audioURL.path
        )

        #expect(try await store.loadPending().isEmpty)
        #expect(try await store.quarantinedEntryNames().count == 2)
    }
}

@Test func recoverableRecordingsExcludeSymlinksAndUnexpectedNames() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let regular = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("recover me".utf8).write(to: regular)
        let outside = root.appendingPathComponent("outside.m4a")
        try Data("outside".utf8).write(to: outside)
        let linked = await store.temporaryRecordingURL(for: secondMemoID)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let unexpected = regular.deletingLastPathComponent().appendingPathComponent("not-a-memo.recording")
        try Data("unexpected".utf8).write(to: unexpected)

        let recovered = try await store.recoverableRecordingURLs()
        #expect(recovered.map(\.lastPathComponent) == [regular.lastPathComponent])
    }
}

@Test func failedCommitAfterAudioPublicationKeepsOriginalRecordingRecoverable() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(
            root: root,
            commitFaultInjector: { checkpoint in
                if checkpoint == .audioPublished {
                    throw InjectedCommitFailure.expected
                }
            }
        )
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("survive interrupted commit".utf8).write(to: temporary)

        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: temporary,
                memoID: storeMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }

        let relaunched = try WatchMemoStore(root: root)
        let recoverable = try await relaunched.recoverableRecordingURLs()
        #expect(recoverable.map(\.lastPathComponent) == [temporary.lastPathComponent])
    }
}

@Test func queueReplacementDuringCommitNeverPublishesIntoReplacementDirectory() async throws {
    try await withTemporaryRoot { root in
        let queue = root.appendingPathComponent("Queue", isDirectory: true)
        let originalQueue = root.appendingPathComponent("Queue-original", isDirectory: true)
        let store = try WatchMemoStore(
            root: root,
            commitFaultInjector: { checkpoint in
                guard checkpoint == .metadataStaged else { return }
                try FileManager.default.moveItem(at: queue, to: originalQueue)
                try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: queue.path
                )
            }
        )
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("survive namespace replacement".utf8).write(to: temporary)

        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: temporary,
                memoID: storeMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: originalQueue.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
    }
}

@Test func queueSymlinkQuarantineNeverChangesExternalTargetPermissions() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("audio".utf8).write(to: temporary)
        let committed = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(),
            durationMilliseconds: 100,
            localeHint: nil
        )
        try FileManager.default.removeItem(at: committed.metadataURL)
        let outside = root.appendingPathComponent("external.json")
        try Data("external".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: outside.path
        )
        try FileManager.default.createSymbolicLink(
            at: committed.metadataURL,
            withDestinationURL: outside
        )

        #expect(try await store.loadPending().isEmpty)
        #expect(try permissions(of: outside) == 0o644)
    }
}

@Test func hardLinkedRecordingIsRejectedWithoutMutatingExternalFile() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let outside = root.appendingPathComponent("external.m4a")
        try Data("external audio".utf8).write(to: outside)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: outside.path
        )
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try FileManager.default.linkItem(at: outside, to: recording)

        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.commitRecording(
                temporaryURL: recording,
                memoID: storeMemoID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }
        #expect(try permissions(of: outside) == 0o644)
        #expect(try Data(contentsOf: outside) == Data("external audio".utf8))
    }
}

@Test func queueCountIsBoundedBeforeOfflineStorageCanGrowWithoutLimit() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        for index in 0 ..< WatchMemoStore.maximumMemoCount {
            let memoID = try MemoID(String(format: "00000000-0000-4000-8000-%012x", index))
            let recording = await store.temporaryRecordingURL(for: memoID)
            try Data("idea-\(index)".utf8).write(to: recording)
            _ = try await store.commitRecording(
                temporaryURL: recording,
                memoID: memoID,
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }

        let overflowID = try MemoID("00000000-0000-4000-8000-000000000999")
        let overflow = await store.temporaryRecordingURL(for: overflowID)
        try Data("one too many".utf8).write(to: overflow)
        await #expect(throws: WatchMemoStoreError.queueFull) {
            _ = try await store.commitRecording(
                temporaryURL: overflow,
                memoID: overflowID,
                capturedAt: Date(),
                durationMilliseconds: 100,
                localeHint: nil
            )
        }
    }
}

@Test func stateTransitionPersistsAndDeletionNeverRemovesUnresolvedReceivedAudio() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("idea".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(),
            durationMilliseconds: 100,
            localeHint: nil
        )
        _ = try await store.transition(memoID: storeMemoID, to: .uploading)
        let received = try await store.transition(memoID: storeMemoID, to: .received)

        let relaunched = try WatchMemoStore(root: root)
        #expect(try await relaunched.load(memoID: storeMemoID).metadata == received)
        await #expect(throws: WatchMemoStoreError.self) {
            try await relaunched.deleteLocal(memoID: storeMemoID)
        }
        #expect(FileManager.default.fileExists(atPath: (try await relaunched.load(memoID: storeMemoID)).audioURL.path))
    }
}

@Test func deleteLocalAllowsSavedMemo() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let savedURL = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("saved".utf8).write(to: savedURL)
        _ = try await store.commitRecording(
            temporaryURL: savedURL,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let deliveryRecord = root
            .appendingPathComponent("Delivered", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).delivered", isDirectory: false)
        let payload: [String: Any] = [
            "memoID": storeMemoID.rawValue,
            "deliveredAt": Date(timeIntervalSince1970: 1).timeIntervalSinceReferenceDate,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: deliveryRecord)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: deliveryRecord.path
        )

        try await store.deleteLocal(memoID: storeMemoID)
        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.load(memoID: storeMemoID)
        }
        #expect(!FileManager.default.fileExists(atPath: deliveryRecord.path))
    }
}

@Test func failedConfirmedDeleteKeepsRawAudioVisibleAndRecoverable() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let savedURL = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("saved".utf8).write(to: savedURL)
        let committed = try await store.commitRecording(
            temporaryURL: savedURL,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: nil
        )
        #expect(chflags(committed.audioURL.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(committed.audioURL.path, 0) }

        await #expect(throws: WatchMemoStoreError.fileSystemFailure) {
            try await store.deleteLocal(memoID: storeMemoID)
        }

        #expect(FileManager.default.fileExists(atPath: committed.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: committed.metadataURL.path))
        #expect(try await store.loadPendingMetadata().map(\.memoID) == [storeMemoID])
    }
}

@Test func failedConfirmedDeleteNeverHidesImmutableMetadata() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let savedURL = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("saved".utf8).write(to: savedURL)
        let committed = try await store.commitRecording(
            temporaryURL: savedURL,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: "en-GB"
        )
        #expect(chflags(committed.metadataURL.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(committed.metadataURL.path, 0) }

        await #expect(throws: WatchMemoStoreError.fileSystemFailure) {
            try await store.deleteLocal(memoID: storeMemoID)
        }

        #expect(FileManager.default.fileExists(atPath: committed.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: committed.metadataURL.path))
        #expect(try await store.loadPendingMetadata().map(\.memoID) == [storeMemoID])
    }
}

@Test func immutableRetryMarkerFailsBeforeConfirmedDeleteRemovesRecording() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let savedURL = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("saved".utf8).write(to: savedURL)
        let committed = try await store.commitRecording(
            temporaryURL: savedURL,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: "en-GB"
        )
        try await store.setRetryNotBefore(
            memoID: storeMemoID,
            date: Date(timeIntervalSince1970: 20)
        )
        let retryURL = root
            .appendingPathComponent("Retry", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).retry")
        #expect(chflags(retryURL.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(retryURL.path, 0) }

        await #expect(throws: WatchMemoStoreError.fileSystemFailure) {
            try await store.deleteLocal(memoID: storeMemoID)
        }

        #expect(FileManager.default.fileExists(atPath: committed.audioURL.path))
        #expect(FileManager.default.fileExists(atPath: committed.metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: retryURL.path))
        #expect(try await store.loadPendingMetadata().map(\.memoID) == [storeMemoID])
    }
}

@Test func deliveredRetentionStartsAtVerifiedDeliveryInsteadOfCapture() async throws {
    try await withTemporaryRoot { root in
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("old capture, new delivery".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )

        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: storeMemoID, to: state)
        }

        let retention = try WatchDeliveredRetentionPolicy(retentionInterval: 10)
        let maintainer = WatchDeliveredRetentionMaintainer(
            store: store,
            policy: retention,
            clock: { clock.now }
        )
        clock.now = Date(timeIntervalSince1970: 1_010)
        #expect(try await maintainer.performMaintenance().isEmpty)
        _ = try await store.load(memoID: storeMemoID)

        clock.now = Date(timeIntervalSince1970: 1_011)
        #expect(try await maintainer.performMaintenance() == [storeMemoID])
        let deliveryRecord = root
            .appendingPathComponent("Delivered", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).delivered", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: deliveryRecord.path))
    }
}

@Test func deliveredRetentionTimestampSurvivesRelaunch() async throws {
    try await withTemporaryRoot { root in
        let deliveryClock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { deliveryClock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("durable delivery time".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )

        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: storeMemoID, to: state)
        }

        let relaunched = try WatchMemoStore(
            root: root,
            clock: { Date(timeIntervalSince1970: 10_000) }
        )
        #expect(try await relaunched.purgeDelivered(before: Date(timeIntervalSince1970: 1_000)).isEmpty)
        _ = try await relaunched.load(memoID: storeMemoID)
        #expect(try await relaunched.purgeDelivered(before: Date(timeIntervalSince1970: 1_001)) == [storeMemoID])
    }
}

@Test func legacyDeliveredMemoGetsAFullRetentionWindow() async throws {
    try await withTemporaryRoot { root in
        let deliveryClock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { deliveryClock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("legacy delivery".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )
        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: storeMemoID, to: state)
        }

        let deliveryRecord = root
            .appendingPathComponent("Delivered", isDirectory: true)
            .appendingPathComponent("\(storeMemoID.rawValue).delivered", isDirectory: false)
        try? FileManager.default.removeItem(at: deliveryRecord)

        let adoptionClock = MutableWatchTestClock(Date(timeIntervalSince1970: 2_000))
        let relaunched = try WatchMemoStore(root: root, clock: { adoptionClock.now })
        let retention = try WatchDeliveredRetentionPolicy(retentionInterval: 10)
        let maintainer = WatchDeliveredRetentionMaintainer(
            store: relaunched,
            policy: retention,
            clock: { adoptionClock.now }
        )
        #expect(try await maintainer.performMaintenance().isEmpty)
        _ = try await relaunched.load(memoID: storeMemoID)
        #expect(FileManager.default.fileExists(atPath: deliveryRecord.path))

        adoptionClock.now = Date(timeIntervalSince1970: 2_010)
        #expect(try await maintainer.performMaintenance().isEmpty)
        adoptionClock.now = Date(timeIntervalSince1970: 2_011)
        #expect(try await maintainer.performMaintenance() == [storeMemoID])
    }
}

@Test func firstLocalDeliveredTransitionReplacesPreexistingPastDeliveryTimestamp() async throws {
    try await withTemporaryRoot { root in
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("first local delivery".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )
        try writeDeliveryTimestampRecord(
            root: root,
            memoID: storeMemoID,
            deliveredAt: Date(timeIntervalSince1970: 1)
        )

        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: storeMemoID, to: state)
        }

        #expect(try await store.purgeDelivered(before: clock.now).isEmpty)
        #expect(try await store.purgeDelivered(before: clock.now.addingTimeInterval(1)) == [storeMemoID])
    }
}

@Test func firstAuthoritativeDeliveredTransitionReplacesPreexistingFutureDeliveryTimestamp() async throws {
    try await withTemporaryRoot { root in
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("first authoritative delivery".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )
        try writeDeliveryTimestampRecord(
            root: root,
            memoID: storeMemoID,
            deliveredAt: Date(timeIntervalSince1970: 10_000)
        )
        _ = try await store.transition(memoID: storeMemoID, to: .uploading)
        _ = try await store.transition(memoID: storeMemoID, to: .received)

        _ = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .delivered,
            revision: 6
        )

        #expect(try await store.purgeDelivered(before: clock.now).isEmpty)
        #expect(try await store.purgeDelivered(before: clock.now.addingTimeInterval(1)) == [storeMemoID])
    }
}

@Test func idempotentDeliveredReconciliationPreservesFirstDeliveryTimestamp() async throws {
    try await withTemporaryRoot { root in
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("idempotent delivery".utf8).write(to: recording)
        _ = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )
        _ = try await store.transition(memoID: storeMemoID, to: .uploading)
        _ = try await store.transition(memoID: storeMemoID, to: .received)
        _ = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .delivered,
            revision: 6
        )

        clock.now = Date(timeIntervalSince1970: 2_000)
        _ = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .delivered,
            revision: 6
        )

        #expect(try await store.purgeDelivered(before: Date(timeIntervalSince1970: 1_001)) == [storeMemoID])
    }
}

@Test func unresolvedContentCannotBeUnlockedByForgedDeliveryTimestamp() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let recording = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("unresolved".utf8).write(to: recording)
        let committed = try await store.commitRecording(
            temporaryURL: recording,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 1),
            durationMilliseconds: 100,
            localeHint: nil
        )
        let deliveredDirectory = root.appendingPathComponent("Delivered", isDirectory: true)
        try FileManager.default.createDirectory(at: deliveredDirectory, withIntermediateDirectories: true)
        let forgedRecord = deliveredDirectory
            .appendingPathComponent("\(storeMemoID.rawValue).delivered", isDirectory: false)
        let payload: [String: Any] = [
            "memoID": storeMemoID.rawValue,
            "deliveredAt": Date(timeIntervalSince1970: 1).timeIntervalSinceReferenceDate,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: forgedRecord)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: forgedRecord.path
        )

        #expect(try await store.purgeDelivered(before: .distantFuture).isEmpty)
        #expect(try await store.load(memoID: storeMemoID) == committed)
    }
}

@Test func deliveredRetentionPurgesOnlyMemosBeforeInjectedCutoff() async throws {
    try await withTemporaryRoot { root in
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 10))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("delivered".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: nil
        )
        for state in [
            MemoState.uploading,
            .received,
            .transcribing,
            .readyForCodex,
            .inserting,
            .delivered,
        ] {
            _ = try await store.transition(memoID: storeMemoID, to: state)
        }

        #expect(try await store.purgeDelivered(before: Date(timeIntervalSince1970: 10)).isEmpty)
        #expect(try await store.purgeDelivered(before: Date(timeIntervalSince1970: 11)) == [storeMemoID])
        await #expect(throws: WatchMemoStoreError.self) {
            _ = try await store.load(memoID: storeMemoID)
        }
    }
}

@Test func deliveredRetentionMaintenanceReconsidersAcrossLifecyclesWithoutTouchingUnresolved() async throws {
    try await withTemporaryRoot { root in
        let deliveredID = try MemoID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let receivedID = try MemoID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        let attentionID = try MemoID("cccccccc-cccc-cccc-cccc-cccccccccccc")
        let capturedAt = Date(timeIntervalSince1970: 100)
        let retention = try WatchDeliveredRetentionPolicy(retentionInterval: 7 * 24 * 60 * 60)
        let clock = MutableWatchTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        for (memoID, state) in [
            (deliveredID, MemoState.delivered),
            (receivedID, .received),
            (attentionID, .needsAttention),
        ] {
            let temporary = await store.temporaryRecordingURL(for: memoID)
            try Data(memoID.rawValue.utf8).write(to: temporary)
            _ = try await store.commitRecording(
                temporaryURL: temporary,
                memoID: memoID,
                capturedAt: capturedAt,
                durationMilliseconds: 100,
                localeHint: nil
            )
            switch state {
            case .delivered:
                for next in [
                    MemoState.uploading, .received, .transcribing,
                    .readyForCodex, .inserting, .delivered,
                ] {
                    _ = try await store.transition(memoID: memoID, to: next)
                }
            case .received:
                _ = try await store.transition(memoID: memoID, to: .uploading)
                _ = try await store.transition(memoID: memoID, to: .received)
            case .needsAttention:
                _ = try await store.transition(memoID: memoID, to: .needsAttention)
            default:
                Issue.record("unexpected fixture state")
            }
        }

        let maintainer = WatchDeliveredRetentionMaintainer(
            store: store,
            policy: retention,
            clock: { clock.now }
        )

        #expect(try await maintainer.performMaintenance().isEmpty)
        _ = try await store.load(memoID: deliveredID)

        clock.now = clock.now.addingTimeInterval(retention.retentionInterval + 1)
        #expect(try await maintainer.performMaintenance() == [deliveredID])
        await #expect(throws: WatchMemoStoreError.notFound) {
            _ = try await store.load(memoID: deliveredID)
        }
        #expect(try await store.load(memoID: receivedID).metadata.state == .received)
        #expect(try await store.load(memoID: attentionID).metadata.state == .needsAttention)
    }
}

@Test func authoritativeReconciliationPersistsExactRemoteRevisionAtomically() async throws {
    try await withTemporaryRoot { root in
        let store = try WatchMemoStore(root: root)
        let temporary = await store.temporaryRecordingURL(for: storeMemoID)
        try Data("reconcile".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: storeMemoID,
            capturedAt: Date(timeIntervalSince1970: 10),
            durationMilliseconds: 100,
            localeHint: nil
        )
        _ = try await store.transition(memoID: storeMemoID, to: .uploading)
        _ = try await store.transition(memoID: storeMemoID, to: .saved)
        _ = try await store.transition(memoID: storeMemoID, to: .uploading)

        let reconciled = try await store.reconcileAuthoritative(
            memoID: storeMemoID,
            state: .received,
            revision: 2
        )

        #expect(reconciled.state == .received)
        #expect(reconciled.stateRevision == 2)
        #expect(try await store.load(memoID: storeMemoID).metadata == reconciled)
    }
}

private func withTemporaryRoot(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-core-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private enum InjectedCommitFailure: Error {
    case expected
}

private func writeDeliveryTimestampRecord(
    root: URL,
    memoID: MemoID,
    deliveredAt: Date
) throws {
    let record = root
        .appendingPathComponent("Delivered", isDirectory: true)
        .appendingPathComponent("\(memoID.rawValue).delivered", isDirectory: false)
    let payload: [String: Any] = [
        "memoID": memoID.rawValue,
        "deliveredAt": deliveredAt.timeIntervalSinceReferenceDate,
    ]
    try JSONSerialization.data(withJSONObject: payload).write(to: record)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: record.path
    )
}

private final class MutableWatchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
