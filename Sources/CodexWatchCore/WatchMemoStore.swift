import CodexBridgeShared
import CryptoKit
import Darwin
import Foundation

public enum WatchMemoStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidRecording
    case recordingTooLarge
    case identityConflict
    case notFound
    case corruptMemo
    case invalidState
    case queueFull
    case fileSystemFailure
}

public enum WatchMemoCommitCheckpoint: Equatable, Sendable {
    case audioStaged
    case metadataStaged
    case audioPublished
    case metadataPublished
}

public struct StoredWatchMemo: Equatable, Sendable {
    public let metadata: VoiceMemoMetadata
    public let audioURL: URL
    public let metadataURL: URL

    public init(metadata: VoiceMemoMetadata, audioURL: URL, metadataURL: URL) {
        self.metadata = metadata
        self.audioURL = audioURL
        self.metadataURL = metadataURL
    }
}

public struct WatchMemoUploadLease: Sendable {
    public let metadata: VoiceMemoMetadata
    public let audioURL: URL
    fileprivate let token: UUID

    fileprivate init(metadata: VoiceMemoMetadata, audioURL: URL, token: UUID) {
        self.metadata = metadata
        self.audioURL = audioURL
        self.token = token
    }
}

private struct DirectoryIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

private struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private struct StagedRecording: Sendable {
    let size: Int64
    let digest: String
    let sourceIdentity: FileIdentity
}

private final class PinnedDirectory: @unchecked Sendable {
    let url: URL
    let descriptor: Int32
    let identity: DirectoryIdentity

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        descriptor = Darwin.open(
            self.url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard descriptor >= 0 else { throw WatchMemoStoreError.invalidRoot }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else {
            Darwin.close(descriptor)
            throw WatchMemoStoreError.invalidRoot
        }
        identity = .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private struct HashedFile: Sendable {
    let size: Int64
    let digest: String
}

private struct RetryRecord: Codable, Equatable, Sendable {
    let memoID: MemoID
    let notBefore: Date
}

private struct DeliveryTimestampRecord: Codable, Equatable, Sendable {
    let memoID: MemoID
    let deliveredAt: Date
}

private enum ActiveWatchMemoUploadLease: Sendable {
    case uploading(UUID)
    case finalizing(UUID)

    var token: UUID {
        switch self {
        case let .uploading(token), let .finalizing(token): token
        }
    }

    var permitsFinalizationMutation: Bool {
        if case .finalizing = self { return true }
        return false
    }
}

public enum WatchDeliveredRetentionPolicyError: Error, Equatable, Sendable {
    case invalidRetentionInterval
}

public struct WatchDeliveredRetentionPolicy: Equatable, Sendable {
    public let retentionInterval: TimeInterval

    public init(retentionInterval: TimeInterval) throws {
        guard retentionInterval.isFinite, retentionInterval > 0 else {
            throw WatchDeliveredRetentionPolicyError.invalidRetentionInterval
        }
        self.retentionInterval = retentionInterval
    }

    public func cutoff(at now: Date) -> Date {
        now.addingTimeInterval(-retentionInterval)
    }
}

public actor WatchDeliveredRetentionMaintainer {
    private let store: WatchMemoStore
    private let policy: WatchDeliveredRetentionPolicy
    private let clock: @Sendable () -> Date

    public init(
        store: WatchMemoStore,
        policy: WatchDeliveredRetentionPolicy,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.policy = policy
        self.clock = clock
    }

    @discardableResult
    public func performMaintenance() async throws -> [MemoID] {
        try await store.purgeDelivered(before: policy.cutoff(at: clock()))
    }
}

public actor WatchMemoStore {
    public static let maximumMemoCount = 32
    public static let maximumQueuedAudioByteCount: Int64 = 256 * 1_024 * 1_024

    private let queueDirectory: URL
    private let temporaryDirectory: URL
    private let quarantineDirectory: URL
    private let retryDirectory: URL
    private let deliveredDirectory: URL
    private let fileManager: FileManager
    private let pinnedDirectories: [PinnedDirectory]
    private let commitFaultInjector: (@Sendable (WatchMemoCommitCheckpoint) throws -> Void)?
    private let clock: @Sendable () -> Date
    private var activeUploadLeases: [MemoID: ActiveWatchMemoUploadLease] = [:]

    public init(
        root: URL,
        fileManager: FileManager = .default,
        commitFaultInjector: (@Sendable (WatchMemoCommitCheckpoint) throws -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let standardizedRoot = root.standardizedFileURL
        let queueDirectory = standardizedRoot.appendingPathComponent("Queue", isDirectory: true)
        let temporaryDirectory = standardizedRoot.appendingPathComponent("Temporary", isDirectory: true)
        let quarantineDirectory = standardizedRoot.appendingPathComponent("Quarantine", isDirectory: true)
        let retryDirectory = standardizedRoot.appendingPathComponent("Retry", isDirectory: true)
        let deliveredDirectory = standardizedRoot.appendingPathComponent("Delivered", isDirectory: true)
        self.queueDirectory = queueDirectory
        self.temporaryDirectory = temporaryDirectory
        self.quarantineDirectory = quarantineDirectory
        self.retryDirectory = retryDirectory
        self.deliveredDirectory = deliveredDirectory
        self.fileManager = fileManager
        self.commitFaultInjector = commitFaultInjector
        self.clock = clock

        do {
            try Self.ensurePrivateDirectory(standardizedRoot, fileManager: fileManager)
            try Self.ensurePrivateDirectory(queueDirectory, fileManager: fileManager)
            try Self.ensurePrivateDirectory(temporaryDirectory, fileManager: fileManager)
            try Self.ensurePrivateDirectory(quarantineDirectory, fileManager: fileManager)
            try Self.ensurePrivateDirectory(retryDirectory, fileManager: fileManager)
            try Self.ensurePrivateDirectory(deliveredDirectory, fileManager: fileManager)
            pinnedDirectories = try [
                standardizedRoot,
                queueDirectory,
                temporaryDirectory,
                quarantineDirectory,
                retryDirectory,
                deliveredDirectory,
            ].map { try PinnedDirectory(url: $0) }
        } catch let error as WatchMemoStoreError {
            throw error
        } catch {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    public func temporaryRecordingURL(for memoID: MemoID) -> URL {
        temporaryDirectory.appendingPathComponent("\(memoID.rawValue).recording", isDirectory: false)
    }

    public func recoverableRecordingURLs() throws -> [URL] {
        try validateLayout()
        return try directoryContents(temporaryDirectory)
            .filter { url in
                guard url.pathExtension == "recording",
                      let memoID = try? MemoID(url.deletingPathExtension().lastPathComponent),
                      !(pathEntryExists(audioURL(for: memoID)) && pathEntryExists(metadataURL(for: memoID)))
                else { return false }
                return isOwnedSingleLinkRegularFileWithoutFollowingLinks(url)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func commitRecording(
        temporaryURL: URL,
        memoID: MemoID,
        capturedAt: Date,
        durationMilliseconds: Int64,
        localeHint: String?
    ) throws -> StoredWatchMemo {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let expectedTemporaryURL = temporaryRecordingURL(for: memoID).standardizedFileURL
        guard temporaryURL.standardizedFileURL == expectedTemporaryURL else {
            throw WatchMemoStoreError.invalidRecording
        }
        let audioURL = audioURL(for: memoID)
        let metadataURL = metadataURL(for: memoID)
        let audioStaging = temporaryDirectory
            .appendingPathComponent("\(memoID.rawValue).audio.tmp", isDirectory: false)
        let metadataStaging = temporaryDirectory
            .appendingPathComponent("\(memoID.rawValue).json.tmp", isDirectory: false)

        if pathEntryExists(audioStaging) {
            try quarantine(audioStaging, label: "stale")
        }
        if pathEntryExists(metadataStaging) {
            try quarantine(metadataStaging, label: "stale")
        }

        let staged = try stageValidatedRecording(
            from: expectedTemporaryURL,
            to: audioStaging
        )
        do {
            try commitFaultInjector?(.audioStaged)
        } catch {
            try? quarantine(audioStaging, label: "commit")
            throw WatchMemoStoreError.fileSystemFailure
        }

        if pathEntryExists(audioURL) || pathEntryExists(metadataURL)
        {
            do {
                let existing = try loadPair(memoID: memoID)
                guard existing.metadata.audioSHA256 == staged.digest else {
                    try quarantine(expectedTemporaryURL, label: "conflict")
                    try? quarantine(audioStaging, label: "conflict")
                    throw WatchMemoStoreError.identityConflict
                }
                try? removePathEntry(audioStaging, from: temporaryDirectory)
                try? removeIfIdentityMatches(expectedTemporaryURL, staged.sourceIdentity)
                return existing
            } catch WatchMemoStoreError.identityConflict {
                throw WatchMemoStoreError.identityConflict
            } catch {
                try? quarantinePair(memoID: memoID, label: "partial")
                try? quarantine(audioStaging, label: "partial")
                throw WatchMemoStoreError.corruptMemo
            }
        }

        let usage = try queueUsage()
        guard usage.count < Self.maximumMemoCount,
              usage.bytes + staged.size <= Self.maximumQueuedAudioByteCount
        else {
            try? removePathEntry(audioStaging, from: temporaryDirectory)
            throw WatchMemoStoreError.queueFull
        }

        let metadata: VoiceMemoMetadata
        do {
            metadata = try VoiceMemoMetadata(
                memoID: memoID,
                capturedAt: capturedAt,
                audioSHA256: staged.digest,
                byteCount: staged.size,
                durationMilliseconds: durationMilliseconds,
                localeHint: localeHint,
                state: .saved,
                stateRevision: 0
            )
        } catch {
            throw WatchMemoStoreError.invalidRecording
        }

        do {
            try encodedMetadata(metadata).write(to: metadataStaging, options: [.atomic])
            try setPrivateFilePermissions(metadataStaging)
            try synchronizeFile(metadataStaging)
            try commitFaultInjector?(.metadataStaged)

            try renamePath(audioStaging, to: audioURL)
            try synchronizeDirectory(queueDirectory)
            try synchronizeDirectory(temporaryDirectory)
            try commitFaultInjector?(.audioPublished)

            try renamePath(metadataStaging, to: metadataURL)
            try synchronizeDirectory(queueDirectory)
            try synchronizeDirectory(temporaryDirectory)
            try commitFaultInjector?(.metadataPublished)
            try validateLayout()
            try? removeIfIdentityMatches(expectedTemporaryURL, staged.sourceIdentity)
            return .init(metadata: metadata, audioURL: audioURL, metadataURL: metadataURL)
        } catch {
            try? quarantine(audioStaging, label: "commit")
            try? quarantine(metadataStaging, label: "commit")
            try? quarantine(audioURL, label: "commit")
            try? quarantine(metadataURL, label: "commit")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    public func loadPending() throws -> [StoredWatchMemo] {
        try validateLayout()
        var result: [StoredWatchMemo] = []
        for memoID in try pairedMemoIDs() {
            do {
                let memo = try loadPair(memoID: memoID)
                if memo.metadata.state != .delivered {
                    result.append(memo)
                }
            } catch {
                try? quarantinePair(memoID: memoID, label: "corrupt")
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.metadata.capturedAt == rhs.metadata.capturedAt {
                return lhs.metadata.memoID.rawValue < rhs.metadata.memoID.rawValue
            }
            return lhs.metadata.capturedAt < rhs.metadata.capturedAt
        }
    }

    public func loadPendingMetadata() throws -> [VoiceMemoMetadata] {
        try validateLayout()
        var result: [VoiceMemoMetadata] = []
        for memoID in try pairedMemoIDs() {
            do {
                let metadata = try loadMetadata(memoID: memoID)
                if metadata.state != .delivered {
                    result.append(metadata)
                }
            } catch {
                try? quarantinePair(memoID: memoID, label: "corrupt")
            }
        }
        return sortedByCaptureTime(result)
    }

    public func loadAllMetadata() throws -> [VoiceMemoMetadata] {
        try validateLayout()
        var result: [VoiceMemoMetadata] = []
        for memoID in try pairedMemoIDs() {
            do {
                result.append(try loadMetadata(memoID: memoID))
            } catch {
                try? quarantinePair(memoID: memoID, label: "corrupt")
            }
        }
        return sortedByCaptureTime(result)
    }

    public func load(memoID: MemoID) throws -> StoredWatchMemo {
        try validateLayout()
        do {
            return try loadPair(memoID: memoID)
        } catch WatchMemoStoreError.corruptMemo {
            try? quarantinePair(memoID: memoID, label: "corrupt")
            throw WatchMemoStoreError.corruptMemo
        }
    }

    public func retryNotBefore(memoID: MemoID) throws -> Date? {
        try validateLayout()
        let url = retryURL(for: memoID)
        guard pathEntryExists(url) else { return nil }
        do {
            let data = try readValidatedFile(
                at: url,
                requirePrivate: true,
                maximumByteCount: 4 * 1_024
            )
            let record = try JSONDecoder().decode(RetryRecord.self, from: data)
            guard record.memoID == memoID,
                  record.notBefore.timeIntervalSinceReferenceDate.isFinite
            else {
                throw WatchMemoStoreError.corruptMemo
            }
            return record.notBefore
        } catch {
            try? quarantine(url, label: "retry")
            return nil
        }
    }

    public func pairingIsRequired() throws -> Bool {
        try validateLayout()
        // Presence is deliberately fail-closed. A damaged or replaced marker
        // must never silently re-enable authenticated network attempts.
        return pathEntryExists(pairingBarrierURL)
    }

    public func clearPairingRequirement() throws {
        try validateLayout()
        guard pathEntryExists(pairingBarrierURL) else { return }
        try removePathEntry(pairingBarrierURL, from: retryDirectory)
    }

    public func markPairingRequired() throws {
        try validateLayout()
        try writePairingBarrier()
    }

    public func setRetryNotBefore(memoID: MemoID, date: Date) throws {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw WatchMemoStoreError.invalidState
        }
        let destination = retryURL(for: memoID)
        let staging = temporaryDirectory
            .appendingPathComponent("\(memoID.rawValue).retry.tmp", isDirectory: false)
        do {
            if pathEntryExists(staging) {
                try quarantine(staging, label: "stale")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(RetryRecord(memoID: memoID, notBefore: date))
                .write(to: staging, options: [.atomic])
            try setPrivateFilePermissions(staging)
            try synchronizeFile(staging)
            if pathEntryExists(destination) {
                try replacePath(staging, to: destination)
            } else {
                try renamePath(staging, to: destination)
            }
            try synchronizeDirectory(retryDirectory)
        } catch let error as WatchMemoStoreError {
            throw error
        } catch {
            try? quarantine(staging, label: "retry")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    public func clearRetryNotBefore(memoID: MemoID) throws {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let url = retryURL(for: memoID)
        guard pathEntryExists(url) else { return }
        try removePathEntry(url, from: retryDirectory)
    }

    public func pendingFinalAcknowledgements() throws -> [FinalDeliveryAcknowledgement] {
        try validateLayout()
        try recoverStagedFinalAcknowledgements()
        var acknowledgements: [FinalDeliveryAcknowledgement] = []
        for url in try directoryContents(deliveredDirectory) {
            guard let memoID = finalAcknowledgementMemoID(for: url) else { continue }
            do {
                acknowledgements.append(try loadFinalAcknowledgement(at: url, expectedMemoID: memoID))
            } catch {
                try? quarantine(url, label: "final-ack")
            }
        }
        return acknowledgements.sorted { $0.memoID.rawValue < $1.memoID.rawValue }
    }

    public func markFinalAcknowledged(_ acknowledgement: FinalDeliveryAcknowledgement) throws {
        try validateLayout()
        try requireNoActiveUploadLease(for: acknowledgement.memoID)
        let destination = finalAcknowledgementURL(for: acknowledgement.memoID)
        guard pathEntryExists(destination) else { return }
        guard try loadFinalAcknowledgement(
            at: destination,
            expectedMemoID: acknowledgement.memoID
        ) == acknowledgement else {
            throw WatchMemoStoreError.invalidState
        }
        try removePathEntry(destination, from: deliveredDirectory)
    }

    private func persistDeliveryTimestamp(
        memoID: MemoID,
        replacingExistingTimestamp: Bool
    ) throws {
        if replacingExistingTimestamp {
            try writeDeliveryTimestamp(memoID: memoID, deliveredAt: clock())
            return
        }
        guard try deliveryTimestamp(memoID: memoID) == nil else { return }
        try writeDeliveryTimestamp(memoID: memoID, deliveredAt: clock())
    }

    private func deliveryTimestamp(memoID: MemoID) throws -> Date? {
        let url = deliveryTimestampURL(for: memoID)
        guard pathEntryExists(url) else { return nil }
        do {
            let data = try readValidatedFile(
                at: url,
                requirePrivate: true,
                maximumByteCount: 4 * 1_024
            )
            let record = try JSONDecoder().decode(DeliveryTimestampRecord.self, from: data)
            guard record.memoID == memoID,
                  record.deliveredAt.timeIntervalSinceReferenceDate.isFinite
            else {
                throw WatchMemoStoreError.corruptMemo
            }
            return record.deliveredAt
        } catch {
            try? quarantine(url, label: "delivery")
            return nil
        }
    }

    private func writeDeliveryTimestamp(memoID: MemoID, deliveredAt: Date) throws {
        guard deliveredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WatchMemoStoreError.invalidState
        }
        let destination = deliveryTimestampURL(for: memoID)
        let staging = temporaryDirectory
            .appendingPathComponent("\(memoID.rawValue).delivered.tmp", isDirectory: false)
        do {
            if pathEntryExists(staging) {
                try quarantine(staging, label: "stale")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(DeliveryTimestampRecord(memoID: memoID, deliveredAt: deliveredAt))
                .write(to: staging, options: [.atomic])
            try setPrivateFilePermissions(staging)
            try synchronizeFile(staging)
            if pathEntryExists(destination) {
                try replacePath(staging, to: destination)
            } else {
                try renamePath(staging, to: destination)
            }
            try synchronizeDirectory(deliveredDirectory)
        } catch let error as WatchMemoStoreError {
            throw error
        } catch {
            try? quarantine(staging, label: "delivery")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    @discardableResult
    public func transition(memoID: MemoID, to state: MemoState) throws -> VoiceMemoMetadata {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let stored = try loadPair(memoID: memoID)
        let updated: VoiceMemoMetadata
        do {
            updated = try MemoStateTransition.transition(
                stored.metadata,
                to: state,
                revision: stored.metadata.stateRevision + 1
            )
        } catch {
            throw WatchMemoStoreError.invalidState
        }
        if updated.state == .delivered {
            try persistDeliveryTimestamp(
                memoID: memoID,
                replacingExistingTimestamp: stored.metadata.state != .delivered
            )
            let acknowledgement = FinalDeliveryAcknowledgement(
                memoID: updated.memoID,
                audioSHA256: updated.audioSHA256,
                stateRevision: updated.stateRevision
            )
            try stageFinalAcknowledgement(acknowledgement)
            try replaceMetadata(updated, at: stored.metadataURL)
            try publishStagedFinalAcknowledgement(acknowledgement)
            return updated
        }
        try replaceMetadata(updated, at: stored.metadataURL)
        return updated
    }

    public func acquireUploadLease(memoID: MemoID) throws -> WatchMemoUploadLease {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let stored = try loadPair(memoID: memoID)
        let uploading: VoiceMemoMetadata
        do {
            uploading = try MemoStateTransition.transition(
                stored.metadata,
                to: .uploading,
                revision: stored.metadata.stateRevision + 1
            )
        } catch {
            throw WatchMemoStoreError.invalidState
        }
        try replaceMetadata(uploading, at: stored.metadataURL)
        let token = UUID()
        activeUploadLeases[memoID] = .uploading(token)
        return WatchMemoUploadLease(
            metadata: uploading,
            audioURL: stored.audioURL,
            token: token
        )
    }

    @discardableResult
    public func releaseUploadLease(_ lease: WatchMemoUploadLease) -> Bool {
        guard activeUploadLeases[lease.metadata.memoID]?.token == lease.token else { return false }
        activeUploadLeases.removeValue(forKey: lease.metadata.memoID)
        return true
    }

    @discardableResult
    public func finishUploadLease(
        _ lease: WatchMemoUploadLease,
        state: MemoState,
        authoritativeRevision: UInt64? = nil,
        retryNotBefore: Date? = nil,
        pairingRequired: Bool = false
    ) throws -> VoiceMemoMetadata {
        let memoID = lease.metadata.memoID
        guard case let .uploading(token) = activeUploadLeases[memoID],
              token == lease.token
        else {
            throw WatchMemoStoreError.invalidState
        }
        guard (retryNotBefore == nil && !pairingRequired)
                || (state == .saved && authoritativeRevision == nil)
        else {
            throw WatchMemoStoreError.invalidState
        }
        activeUploadLeases[memoID] = .finalizing(lease.token)
        defer {
            if activeUploadLeases[memoID]?.token == lease.token {
                activeUploadLeases.removeValue(forKey: memoID)
            }
        }
        if let retryNotBefore {
            try setRetryNotBefore(memoID: memoID, date: retryNotBefore)
        }
        if pairingRequired {
            try writePairingBarrier()
        }
        if let authoritativeRevision {
            return try reconcileAuthoritative(
                memoID: memoID,
                state: state,
                revision: authoritativeRevision
            )
        }
        return try transition(memoID: memoID, to: state)
    }

    @discardableResult
    public func recoverInterruptedUpload(memoID: MemoID) throws -> VoiceMemoMetadata? {
        try validateLayout()
        guard activeUploadLeases[memoID] == nil else { return nil }
        let stored = try loadPair(memoID: memoID)
        guard stored.metadata.state == .uploading else { return nil }
        return try transition(memoID: memoID, to: .saved)
    }

    /// Persists an authenticated bridge state with its authoritative absolute
    /// revision. Callers must validate remote identity and reachability first.
    @discardableResult
    public func reconcileAuthoritative(
        memoID: MemoID,
        state: MemoState,
        revision: UInt64
    ) throws -> VoiceMemoMetadata {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let stored = try loadPair(memoID: memoID)
        guard state != .saved, state != .uploading, revision > 0 else {
            throw WatchMemoStoreError.invalidState
        }
        let updated: VoiceMemoMetadata
        do {
            updated = try VoiceMemoMetadata(
                memoID: stored.metadata.memoID,
                capturedAt: stored.metadata.capturedAt,
                audioSHA256: stored.metadata.audioSHA256,
                byteCount: stored.metadata.byteCount,
                durationMilliseconds: stored.metadata.durationMilliseconds,
                formatVersion: stored.metadata.formatVersion,
                localeHint: stored.metadata.localeHint,
                state: state,
                stateRevision: revision
            )
        } catch {
            throw WatchMemoStoreError.invalidState
        }
        if updated.state == .delivered {
            try persistDeliveryTimestamp(
                memoID: memoID,
                replacingExistingTimestamp: stored.metadata.state != .delivered
            )
            let acknowledgement = FinalDeliveryAcknowledgement(
                memoID: updated.memoID,
                audioSHA256: updated.audioSHA256,
                stateRevision: updated.stateRevision
            )
            try stageFinalAcknowledgement(acknowledgement)
            try replaceMetadata(updated, at: stored.metadataURL)
            try publishStagedFinalAcknowledgement(acknowledgement)
            return updated
        }
        try replaceMetadata(updated, at: stored.metadataURL)
        return updated
    }

    public func deleteLocal(memoID: MemoID) throws {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let stored = try loadPair(memoID: memoID)
        guard stored.metadata.state == .saved || stored.metadata.state == .needsAttention else {
            throw WatchMemoStoreError.invalidState
        }
        try removePair(stored)
    }

    public func deleteConfirmedLocal(memoID: MemoID) throws {
        try validateLayout()
        try requireNoActiveUploadLease(for: memoID)
        let stored = try loadPair(memoID: memoID)
        let finalAcknowledgement = finalAcknowledgementURL(for: memoID)
        let stagedFinalAcknowledgement = stagedFinalAcknowledgementURL(for: memoID)
        if pathEntryExists(finalAcknowledgement) {
            try validateDeletableFile(finalAcknowledgement)
        }
        if pathEntryExists(stagedFinalAcknowledgement) {
            try validateDeletableFile(stagedFinalAcknowledgement)
        }
        try removePair(stored)
        if pathEntryExists(finalAcknowledgement) {
            try removePathEntry(finalAcknowledgement, from: deliveredDirectory)
        }
        if pathEntryExists(stagedFinalAcknowledgement) {
            try removePathEntry(stagedFinalAcknowledgement, from: temporaryDirectory)
        }
        try synchronizeDirectory(deliveredDirectory)
        try synchronizeDirectory(temporaryDirectory)
    }

    @discardableResult
    public func purgeDelivered(before cutoff: Date) throws -> [MemoID] {
        try validateLayout()
        var purged: [MemoID] = []
        for url in try directoryContents(queueDirectory) where url.pathExtension == "json" {
            guard let memoID = try? MemoID(url.deletingPathExtension().lastPathComponent),
                  activeUploadLeases[memoID] == nil,
                  let stored = try? loadPair(memoID: memoID),
                  stored.metadata.state == .delivered
            else { continue }
            guard let deliveredAt = try deliveryTimestamp(memoID: memoID) else {
                try writeDeliveryTimestamp(memoID: memoID, deliveredAt: clock())
                continue
            }
            guard deliveredAt < cutoff else { continue }
            try removePair(stored)
            purged.append(memoID)
        }
        return purged.sorted { $0.rawValue < $1.rawValue }
    }

    public func quarantinedEntryNames() throws -> [String] {
        try validateLayout()
        return try directoryContents(quarantineDirectory)
            .map(\.lastPathComponent)
            .sorted()
    }

    private func loadPair(memoID: MemoID) throws -> StoredWatchMemo {
        let audioURL = audioURL(for: memoID)
        let metadataURL = metadataURL(for: memoID)
        guard pathEntryExists(audioURL), pathEntryExists(metadataURL)
        else {
            throw WatchMemoStoreError.notFound
        }
        let metadata = try loadMetadata(memoID: memoID)

        let audio = try hashValidatedFile(
            at: audioURL,
            requirePrivate: true,
            maximumByteCount: VoiceMemoMetadata.maximumAudioByteCount
        )
        guard metadata.memoID == memoID,
              metadata.byteCount == audio.size,
              metadata.audioSHA256 == audio.digest
        else {
            throw WatchMemoStoreError.corruptMemo
        }
        return .init(metadata: metadata, audioURL: audioURL, metadataURL: metadataURL)
    }

    private func loadMetadata(memoID: MemoID) throws -> VoiceMemoMetadata {
        do {
            let metadataURL = metadataURL(for: memoID)
            let metadata = try JSONDecoder().decode(
                VoiceMemoMetadata.self,
                from: readValidatedFile(
                    at: metadataURL,
                    requirePrivate: true,
                    maximumByteCount: 64 * 1_024
                )
            )
            guard metadata.memoID == memoID else {
                throw WatchMemoStoreError.corruptMemo
            }
            return metadata
        } catch {
            throw WatchMemoStoreError.corruptMemo
        }
    }

    private func pairedMemoIDs() throws -> [MemoID] {
        var contents: [URL] = []
        for url in try directoryContents(queueDirectory) {
            guard isOwnedSingleLinkRegularFileWithoutFollowingLinks(url) else {
                try? quarantine(url, label: "unsafe")
                continue
            }
            guard url.pathExtension == "json" || url.pathExtension == "m4a" else {
                try? quarantine(url, label: "unknown")
                continue
            }
            contents.append(url)
        }
        let metadataNames = Set(contents.filter { $0.pathExtension == "json" }.map {
            $0.deletingPathExtension().lastPathComponent
        })
        let audioNames = Set(contents.filter { $0.pathExtension == "m4a" }.map {
            $0.deletingPathExtension().lastPathComponent
        })

        for orphan in metadataNames.symmetricDifference(audioNames) {
            if let memoID = try? MemoID(orphan) {
                try? quarantinePair(memoID: memoID, label: "orphan")
            } else {
                for url in contents where url.deletingPathExtension().lastPathComponent == orphan {
                    try? quarantine(url, label: "unknown")
                }
            }
        }

        var memoIDs: [MemoID] = []
        for name in metadataNames.intersection(audioNames) {
            if let memoID = try? MemoID(name) {
                memoIDs.append(memoID)
            } else {
                for url in contents where url.deletingPathExtension().lastPathComponent == name {
                    try? quarantine(url, label: "unknown")
                }
            }
        }
        return memoIDs.sorted { $0.rawValue < $1.rawValue }
    }

    private func sortedByCaptureTime(
        _ metadata: [VoiceMemoMetadata]
    ) -> [VoiceMemoMetadata] {
        metadata.sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.memoID.rawValue < rhs.memoID.rawValue
            }
            return lhs.capturedAt < rhs.capturedAt
        }
    }

    private func replaceMetadata(_ metadata: VoiceMemoMetadata, at destination: URL) throws {
        try requireNoActiveUploadLease(for: metadata.memoID)
        let staging = temporaryDirectory
            .appendingPathComponent("\(metadata.memoID.rawValue).state.tmp", isDirectory: false)
        do {
            try encodedMetadata(metadata).write(to: staging, options: [.atomic])
            try setPrivateFilePermissions(staging)
            try synchronizeFile(staging)
            try replacePath(staging, to: destination)
            try setPrivateFilePermissions(destination)
            try synchronizeFile(destination)
            try synchronizeDirectory(queueDirectory)
        } catch {
            try? quarantine(staging, label: "state")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func removePair(_ stored: StoredWatchMemo) throws {
        try requireNoActiveUploadLease(for: stored.metadata.memoID)
        do {
            let retry = retryURL(for: stored.metadata.memoID)
            let deliveryTimestamp = deliveryTimestampURL(for: stored.metadata.memoID)
            try validateDeletableFile(stored.audioURL)
            try validateDeletableFile(stored.metadataURL)
            if pathEntryExists(retry) {
                try validateDeletableFile(retry)
            }
            if pathEntryExists(deliveryTimestamp) {
                try validateDeletableFile(deliveryTimestamp)
            }
            try clearRetryNotBefore(memoID: stored.metadata.memoID)
            if pathEntryExists(deliveryTimestamp) {
                try removePathEntry(deliveryTimestamp, from: deliveredDirectory)
            }
            try removePathEntry(stored.audioURL, from: queueDirectory)
            try removePathEntry(stored.metadataURL, from: queueDirectory)
            try synchronizeDirectory(queueDirectory)
        } catch {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func validateDeletableFile(_ url: URL) throws {
        let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        let blockingFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_flags & blockingFlags == 0
        else { throw WatchMemoStoreError.fileSystemFailure }
    }

    private func quarantinePair(memoID: MemoID, label: String) throws {
        try requireNoActiveUploadLease(for: memoID)
        try quarantine(audioURL(for: memoID), label: label)
        try quarantine(metadataURL(for: memoID), label: label)
    }

    private func quarantine(_ url: URL, label: String) throws {
        try requireNoActiveUploadLease(forPath: url)
        var sourceMetadata = stat()
        guard metadataWithoutFollowingLinks(at: url, into: &sourceMetadata) else { return }
        let destination = quarantineDirectory.appendingPathComponent(
            "\(url.lastPathComponent).\(label).\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try renamePath(url, to: destination)
            try synchronizeDirectory(url.deletingLastPathComponent())
            try synchronizeDirectory(quarantineDirectory)
            if sourceMetadata.st_mode & S_IFMT == S_IFREG,
               sourceMetadata.st_uid == getuid(),
               sourceMetadata.st_nlink == 1
            {
                try setPrivateFilePermissions(destination)
                try synchronizeFile(destination)
            }
        } catch {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func audioURL(for memoID: MemoID) -> URL {
        queueDirectory.appendingPathComponent("\(memoID.rawValue).m4a", isDirectory: false)
    }

    private func metadataURL(for memoID: MemoID) -> URL {
        queueDirectory.appendingPathComponent("\(memoID.rawValue).json", isDirectory: false)
    }

    private func retryURL(for memoID: MemoID) -> URL {
        retryDirectory.appendingPathComponent("\(memoID.rawValue).retry", isDirectory: false)
    }

    private var pairingBarrierURL: URL {
        retryDirectory.appendingPathComponent("pairing-required", isDirectory: false)
    }

    private func writePairingBarrier() throws {
        let staging = temporaryDirectory
            .appendingPathComponent("pairing-required.tmp", isDirectory: false)
        do {
            if pathEntryExists(staging) {
                try quarantine(staging, label: "stale")
            }
            try Data([1]).write(to: staging, options: [.atomic])
            try setPrivateFilePermissions(staging)
            try synchronizeFile(staging)
            if pathEntryExists(pairingBarrierURL) {
                try replacePath(staging, to: pairingBarrierURL)
            } else {
                try renamePath(staging, to: pairingBarrierURL)
            }
            try synchronizeDirectory(retryDirectory)
        } catch let error as WatchMemoStoreError {
            throw error
        } catch {
            try? quarantine(staging, label: "pairing")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func deliveryTimestampURL(for memoID: MemoID) -> URL {
        deliveredDirectory.appendingPathComponent("\(memoID.rawValue).delivered", isDirectory: false)
    }

    private func finalAcknowledgementURL(for memoID: MemoID) -> URL {
        deliveredDirectory.appendingPathComponent("\(memoID.rawValue).final-ack", isDirectory: false)
    }

    private func stagedFinalAcknowledgementURL(for memoID: MemoID) -> URL {
        temporaryDirectory.appendingPathComponent("\(memoID.rawValue).final-ack.tmp", isDirectory: false)
    }

    private func finalAcknowledgementMemoID(for url: URL) -> MemoID? {
        let suffix = ".final-ack"
        let name = url.lastPathComponent
        guard name.hasSuffix(suffix) else { return nil }
        return try? MemoID(String(name.dropLast(suffix.count)))
    }

    private func stagedFinalAcknowledgementMemoID(for url: URL) -> MemoID? {
        let suffix = ".final-ack.tmp"
        let name = url.lastPathComponent
        guard name.hasSuffix(suffix) else { return nil }
        return try? MemoID(String(name.dropLast(suffix.count)))
    }

    private func loadFinalAcknowledgement(
        at url: URL,
        expectedMemoID: MemoID
    ) throws -> FinalDeliveryAcknowledgement {
        let data = try readValidatedFile(
            at: url,
            requirePrivate: true,
            maximumByteCount: 4 * 1_024
        )
        let acknowledgement = try JSONDecoder().decode(FinalDeliveryAcknowledgement.self, from: data)
        guard acknowledgement.memoID == expectedMemoID,
              SHA256Hex.isValid(acknowledgement.audioSHA256),
              acknowledgement.stateRevision > 0
        else { throw WatchMemoStoreError.corruptMemo }
        return acknowledgement
    }

    private func stageFinalAcknowledgement(
        _ acknowledgement: FinalDeliveryAcknowledgement
    ) throws {
        guard SHA256Hex.isValid(acknowledgement.audioSHA256),
              acknowledgement.stateRevision > 0
        else { throw WatchMemoStoreError.invalidState }
        let staging = stagedFinalAcknowledgementURL(for: acknowledgement.memoID)
        if pathEntryExists(staging) {
            if let existing = try? loadFinalAcknowledgement(
                at: staging,
                expectedMemoID: acknowledgement.memoID
            ), existing == acknowledgement {
                return
            }
            try quarantine(staging, label: "final-ack")
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(acknowledgement).write(to: staging, options: [.atomic])
            try setPrivateFilePermissions(staging)
            try synchronizeFile(staging)
            try synchronizeDirectory(temporaryDirectory)
        } catch let error as WatchMemoStoreError {
            throw error
        } catch {
            try? quarantine(staging, label: "final-ack")
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func publishStagedFinalAcknowledgement(
        _ acknowledgement: FinalDeliveryAcknowledgement
    ) throws {
        let staging = stagedFinalAcknowledgementURL(for: acknowledgement.memoID)
        let destination = finalAcknowledgementURL(for: acknowledgement.memoID)
        if pathEntryExists(destination) {
            guard try loadFinalAcknowledgement(
                at: destination,
                expectedMemoID: acknowledgement.memoID
            ) == acknowledgement else { throw WatchMemoStoreError.invalidState }
            if pathEntryExists(staging) {
                try removePathEntry(staging, from: temporaryDirectory)
            }
            return
        }
        guard pathEntryExists(staging) else { throw WatchMemoStoreError.fileSystemFailure }
        try renamePath(staging, to: destination)
        try synchronizeDirectory(temporaryDirectory)
        try synchronizeDirectory(deliveredDirectory)
    }

    private func recoverStagedFinalAcknowledgements() throws {
        for url in try directoryContents(temporaryDirectory) {
            guard let memoID = stagedFinalAcknowledgementMemoID(for: url) else { continue }
            do {
                let acknowledgement = try loadFinalAcknowledgement(at: url, expectedMemoID: memoID)
                guard let metadata = try? loadMetadata(memoID: memoID),
                      metadata.state == .delivered,
                      metadata.audioSHA256 == acknowledgement.audioSHA256,
                      metadata.stateRevision == acknowledgement.stateRevision
                else { continue }
                try publishStagedFinalAcknowledgement(acknowledgement)
            } catch {
                try? quarantine(url, label: "final-ack")
            }
        }
    }

    private func directoryContents(_ directory: URL) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func stageValidatedRecording(from source: URL, to destination: URL) throws -> StagedRecording {
        let sourceDescriptor = openDescriptor(
            at: source,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard sourceDescriptor >= 0 else { throw WatchMemoStoreError.invalidRecording }
        defer { Darwin.close(sourceDescriptor) }

        let sourceIdentity = try validatedFileIdentity(
            descriptor: sourceDescriptor,
            requirePrivate: false,
            maximumByteCount: VoiceMemoMetadata.maximumAudioByteCount
        )
        guard sourceIdentity.size > 0 else { throw WatchMemoStoreError.invalidRecording }

        let destinationDescriptor = openDescriptor(
            at: destination,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
        var destinationNeedsRemoval = true
        defer {
            Darwin.close(destinationDescriptor)
            if destinationNeedsRemoval {
                try? removePathEntry(destination, from: temporaryDirectory)
            }
        }

        var hasher = SHA256()
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let readCount = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            guard readCount >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
            if readCount == 0 { break }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written
                    )
                }
                guard writeCount > 0 else { throw WatchMemoStoreError.fileSystemFailure }
                written += writeCount
            }
            hasher.update(data: Data(buffer[0 ..< readCount]))
            copied += Int64(readCount)
        }
        guard copied == sourceIdentity.size else { throw WatchMemoStoreError.invalidRecording }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw WatchMemoStoreError.fileSystemFailure
        }
        _ = try validatedFileIdentity(
            descriptor: destinationDescriptor,
            requirePrivate: true,
            maximumByteCount: VoiceMemoMetadata.maximumAudioByteCount
        )
        destinationNeedsRemoval = false
        try synchronizeDirectory(temporaryDirectory)
        return .init(
            size: copied,
            digest: hexDigest(hasher.finalize()),
            sourceIdentity: sourceIdentity
        )
    }

    private func hashValidatedFile(
        at url: URL,
        requirePrivate: Bool,
        maximumByteCount: Int64
    ) throws -> HashedFile {
        let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WatchMemoStoreError.corruptMemo }
        defer { Darwin.close(descriptor) }
        let identity = try validatedFileIdentity(
            descriptor: descriptor,
            requirePrivate: requirePrivate,
            maximumByteCount: maximumByteCount
        )
        guard identity.size > 0 else { throw WatchMemoStoreError.corruptMemo }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
            if readCount == 0 { break }
            total += Int64(readCount)
            guard total <= maximumByteCount else { throw WatchMemoStoreError.corruptMemo }
            hasher.update(data: Data(buffer[0 ..< readCount]))
        }
        guard total == identity.size else { throw WatchMemoStoreError.corruptMemo }
        return .init(size: total, digest: hexDigest(hasher.finalize()))
    }

    private func readValidatedFile(
        at url: URL,
        requirePrivate: Bool,
        maximumByteCount: Int64
    ) throws -> Data {
        let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WatchMemoStoreError.corruptMemo }
        defer { Darwin.close(descriptor) }
        let identity = try validatedFileIdentity(
            descriptor: descriptor,
            requirePrivate: requirePrivate,
            maximumByteCount: maximumByteCount
        )
        var result = Data()
        result.reserveCapacity(Int(identity.size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let readCount = Darwin.read(descriptor, &buffer, buffer.count)
            guard readCount >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
            if readCount == 0 { break }
            result.append(contentsOf: buffer[0 ..< readCount])
            guard result.count <= maximumByteCount else { throw WatchMemoStoreError.corruptMemo }
        }
        guard result.count == identity.size else { throw WatchMemoStoreError.corruptMemo }
        return result
    }

    private func validatedFileIdentity(
        descriptor: Int32,
        requirePrivate: Bool,
        maximumByteCount: Int64
    ) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount,
              !requirePrivate || metadata.st_mode & 0o077 == 0
        else {
            throw requirePrivate ? WatchMemoStoreError.corruptMemo : WatchMemoStoreError.invalidRecording
        }
        return .init(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    private func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isOwnedSingleLinkRegularFileWithoutFollowingLinks(_ url: URL) -> Bool {
        var metadata = stat()
        return metadataWithoutFollowingLinks(at: url, into: &metadata)
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
    }

    private func encodedMetadata(_ metadata: VoiceMemoMetadata) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(metadata)
        } catch {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func setPrivateFilePermissions(_ url: URL) throws {
        let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func queueUsage() throws -> (count: Int, bytes: Int64) {
        var memoIDs = Set<String>()
        var bytes: Int64 = 0
        for url in try directoryContents(queueDirectory) where url.pathExtension == "m4a" {
            guard isOwnedSingleLinkRegularFileWithoutFollowingLinks(url) else { continue }
            let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
            defer { Darwin.close(descriptor) }
            let identity = try validatedFileIdentity(
                descriptor: descriptor,
                requirePrivate: true,
                maximumByteCount: VoiceMemoMetadata.maximumAudioByteCount
            )
            memoIDs.insert(url.deletingPathExtension().lastPathComponent)
            bytes += identity.size
        }
        return (memoIDs.count, bytes)
    }

    private func pathEntryExists(_ url: URL) -> Bool {
        var metadata = stat()
        return metadataWithoutFollowingLinks(at: url, into: &metadata)
    }

    private func requireNoActiveUploadLease(for memoID: MemoID) throws {
        if let activeLease = activeUploadLeases[memoID],
           !activeLease.permitsFinalizationMutation
        {
            throw WatchMemoStoreError.invalidState
        }
    }

    private func requireNoActiveUploadLease(forPath url: URL) throws {
        let memoComponent = url.lastPathComponent.split(separator: ".", maxSplits: 1).first
        guard let memoComponent,
              let memoID = try? MemoID(String(memoComponent))
        else { return }
        try requireNoActiveUploadLease(for: memoID)
    }

    private func renamePath(_ source: URL, to destination: URL) throws {
        try requireNoActiveUploadLease(forPath: source)
        try requireNoActiveUploadLease(forPath: destination)
        guard renameRelative(source, to: destination, flags: UInt32(RENAME_EXCL)) == 0 else {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func replacePath(_ source: URL, to destination: URL) throws {
        try requireNoActiveUploadLease(forPath: source)
        try requireNoActiveUploadLease(forPath: destination)
        guard renameRelative(source, to: destination, flags: 0) == 0 else {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func removePathEntry(_ url: URL, from directory: URL) throws {
        try requireNoActiveUploadLease(forPath: url)
        guard pathEntryExists(url) else { return }
        guard let (parent, name) = pinnedParentAndName(for: url),
              name.withCString({ unlinkat(parent.descriptor, $0, 0) }) == 0
        else { throw WatchMemoStoreError.fileSystemFailure }
        try synchronizeDirectory(directory)
    }

    private func removeIfIdentityMatches(_ url: URL, _ identity: FileIdentity) throws {
        try requireNoActiveUploadLease(forPath: url)
        var metadata = stat()
        guard metadataWithoutFollowingLinks(at: url, into: &metadata) else { return }
        let current = FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              current == identity
        else {
            throw WatchMemoStoreError.invalidRecording
        }
        try removePathEntry(url, from: temporaryDirectory)
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = openDescriptor(at: url, flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw WatchMemoStoreError.fileSystemFailure }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        guard let directory = pinnedDirectories.first(where: {
            $0.url == url.standardizedFileURL
        }), Darwin.fsync(directory.descriptor) == 0 else {
            throw WatchMemoStoreError.fileSystemFailure
        }
    }

    private static func ensurePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else { throw WatchMemoStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR | S_IXUSR) == 0
        else {
            throw WatchMemoStoreError.invalidRoot
        }
    }

    private func validateLayout() throws {
        for directory in pinnedDirectories {
            guard try Self.validatedPrivateDirectoryIdentity(directory.url) == directory.identity else {
                throw WatchMemoStoreError.invalidRoot
            }
        }
    }

    private func pinnedParentAndName(for url: URL) -> (PinnedDirectory, String)? {
        let standardized = url.standardizedFileURL
        let parentURL = standardized.deletingLastPathComponent()
        guard standardized.lastPathComponent != ".",
              standardized.lastPathComponent != "..",
              let parent = pinnedDirectories.first(where: { $0.url == parentURL })
        else { return nil }
        return (parent, standardized.lastPathComponent)
    }

    private func openDescriptor(at url: URL, flags: Int32, mode: mode_t = 0) -> Int32 {
        guard let (parent, name) = pinnedParentAndName(for: url) else { return -1 }
        return name.withCString { openat(parent.descriptor, $0, flags, mode) }
    }

    private func metadataWithoutFollowingLinks(at url: URL, into metadata: inout stat) -> Bool {
        guard let (parent, name) = pinnedParentAndName(for: url) else { return false }
        return name.withCString {
            fstatat(parent.descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        } == 0
    }

    private func renameRelative(_ source: URL, to destination: URL, flags: UInt32) -> Int32 {
        guard let (sourceParent, sourceName) = pinnedParentAndName(for: source),
              let (destinationParent, destinationName) = pinnedParentAndName(for: destination)
        else { return -1 }
        return sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                renameatx_np(
                    sourceParent.descriptor,
                    sourcePointer,
                    destinationParent.descriptor,
                    destinationPointer,
                    flags
                )
            }
        }
    }

    private static func validatedPrivateDirectoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else { throw WatchMemoStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0
        else {
            throw WatchMemoStoreError.invalidRoot
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }
}
