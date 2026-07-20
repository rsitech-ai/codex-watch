import CodexBridgeShared
import Darwin
import Foundation

public enum DeliveryJournalError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidRecord
    case alreadyExists
    case notFound
    case invalidTransition
    case fileSystemFailure
}

enum DeliveryJournalMutationBoundary: Equatable, Sendable {
    case beforeTemporaryCreation
    case beforeRename
    case beforeTemporaryCleanup
}

public struct DeliveryJournal: Sendable {
    private static let maximumRecordBytes = 256 * 1_024

    private let root: URL
    private let rootIdentity: FileIdentity
    private let clock: @Sendable () -> Date
    private let faultInjector: @Sendable (DeliveryJournalMutationBoundary) throws -> Void

    public init(
        root: URL,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        try self.init(root: root, clock: clock, faultInjector: { _ in })
    }

    init(
        root: URL,
        faultInjector: @escaping @Sendable (DeliveryJournalMutationBoundary) throws -> Void
    ) throws {
        try self.init(root: root, clock: Date.init, faultInjector: faultInjector)
    }

    init(
        root: URL,
        clock: @escaping @Sendable () -> Date,
        faultInjector: @escaping @Sendable (DeliveryJournalMutationBoundary) throws -> Void
    ) throws {
        let standardizedRoot = root.standardizedFileURL
        let identity = try Self.prepareRoot(standardizedRoot)
        self.root = standardizedRoot
        rootIdentity = identity
        self.clock = clock
        self.faultInjector = faultInjector
    }

    public func create(_ record: DeliveryRecord) throws {
        guard record.state == .received, record.revision == 0 else {
            throw DeliveryJournalError.invalidRecord
        }
        _ = try record.validated()
        try withLockedDirectory { descriptor in
            try write(record, descriptor: descriptor, replacing: false)
        }
    }

    public func load(memoID: MemoID) throws -> DeliveryRecord {
        try withLockedDirectory { descriptor in
            try read(memoID: memoID, descriptor: descriptor)
        }
    }

    @discardableResult
    public func transition(
        memoID: MemoID,
        to state: MemoState,
        transcript: String? = nil
    ) throws -> DeliveryRecord {
        try withLockedDirectory { descriptor in
            let previous = try read(memoID: memoID, descriptor: descriptor)
            guard DeliveryRecord.transitionAllowed(from: previous.state, to: state),
                  previous.revision < UInt64.max
            else { throw DeliveryJournalError.invalidTransition }
            let nextTranscript = transcript ?? previous.transcript
            let updated = DeliveryRecord(
                memoID: previous.memoID,
                capturedAt: previous.capturedAt,
                localeHint: previous.localeHint,
                audioSHA256: previous.audioSHA256,
                state: state,
                revision: previous.revision + 1,
                updatedAt: clock(),
                transcript: nextTranscript
            )
            do {
                _ = try updated.validated()
            } catch {
                throw DeliveryJournalError.invalidTransition
            }
            try write(updated, descriptor: descriptor, replacing: true)
            return updated
        }
    }

    /// Explicit operator retry only reopens an unresolved memo. Delivered
    /// records remain immutable and cannot be resubmitted accidentally.
    @discardableResult
    public func retry(memoID: MemoID) throws -> DeliveryRecord {
        try withLockedDirectory { descriptor in
            let previous = try read(memoID: memoID, descriptor: descriptor)
            // A transcript-bearing needs-attention record may be an ambiguous
            // or duplicate App Server delivery. Reopening it could submit the
            // same marker twice, so explicit retry is only safe for the
            // transcript-less transcription failure boundary.
            guard previous.state == .needsAttention,
                  previous.transcript == nil,
                  previous.revision < UInt64.max
            else {
                throw DeliveryJournalError.invalidTransition
            }
            let retried = DeliveryRecord(
                memoID: previous.memoID,
                capturedAt: previous.capturedAt,
                localeHint: previous.localeHint,
                audioSHA256: previous.audioSHA256,
                state: .received,
                revision: previous.revision + 1,
                updatedAt: clock(),
                transcript: previous.transcript
            )
            _ = try retried.validated()
            try write(retried, descriptor: descriptor, replacing: true)
            return retried
        }
    }

    @discardableResult
    public func reopenForSafeRetry(
        memoID: MemoID,
        boundary: DeliverySafeRetryBoundary
    ) throws -> DeliveryRecord {
        try withLockedDirectory { descriptor in
            let previous = try read(memoID: memoID, descriptor: descriptor)
            let boundaryMatchesState = switch boundary {
            case .definitelyNotAccepted:
                previous.state == .inserting
            case .authoritativelyAbsent:
                previous.state == .reconciling
            }
            guard boundaryMatchesState,
                  previous.transcript != nil,
                  previous.revision < UInt64.max
            else { throw DeliveryJournalError.invalidTransition }
            let reopened = DeliveryRecord(
                memoID: previous.memoID,
                capturedAt: previous.capturedAt,
                localeHint: previous.localeHint,
                audioSHA256: previous.audioSHA256,
                state: .readyForCodex,
                revision: previous.revision + 1,
                updatedAt: clock(),
                transcript: previous.transcript
            )
            do {
                _ = try reopened.validated()
            } catch {
                throw DeliveryJournalError.invalidTransition
            }
            try write(reopened, descriptor: descriptor, replacing: true)
            return reopened
        }
    }

    public func removeDelivered(memoID: MemoID, deliveredBeforeOrAt cutoff: Date) throws {
        guard cutoff.timeIntervalSinceReferenceDate.isFinite else {
            throw DeliveryJournalError.invalidTransition
        }
        try withLockedDirectory { descriptor in
            let record = try read(memoID: memoID, descriptor: descriptor)
            guard record.state == .delivered, record.updatedAt <= cutoff else {
                throw DeliveryJournalError.invalidTransition
            }
            let name = recordName(memoID)
            guard let identity = Self.entryIdentity(name, directoryDescriptor: descriptor) else {
                throw DeliveryJournalError.invalidRecord
            }
            Self.unlinkIfIdentityMatches(
                name,
                identity: identity,
                directoryDescriptor: descriptor
            )
            guard Self.entryIdentity(name, directoryDescriptor: descriptor) == nil,
                  fsync(descriptor) == 0
            else { throw DeliveryJournalError.fileSystemFailure }
        }
    }

    private func withLockedDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DeliveryJournalError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              FileIdentity(metadata) == rootIdentity,
              flock(descriptor, LOCK_EX) == 0
        else { throw DeliveryJournalError.invalidRoot }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(descriptor)
    }

    private func read(memoID: MemoID, descriptor: Int32) throws -> DeliveryRecord {
        let name = recordName(memoID)
        let file = name.withCString { openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard file >= 0 else {
            if errno == ENOENT { throw DeliveryJournalError.notFound }
            throw DeliveryJournalError.fileSystemFailure
        }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0,
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumRecordBytes
        else { throw DeliveryJournalError.invalidRecord }
        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(file, base.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        guard bytesRead == data.count else { throw DeliveryJournalError.fileSystemFailure }
        do {
            let record = try JSONDecoder().decode(DeliveryRecord.self, from: data)
            guard record.memoID == memoID else { throw DeliveryJournalError.invalidRecord }
            return try record.validated()
        } catch let error as DeliveryJournalError {
            throw error
        } catch {
            throw DeliveryJournalError.invalidRecord
        }
    }

    private func write(
        _ record: DeliveryRecord,
        descriptor: Int32,
        replacing: Bool
    ) throws {
        try faultInjector(.beforeTemporaryCreation)
        let temporaryName = ".\(record.memoID.rawValue).tmp-\(UUID().uuidString.lowercased())"
        let destinationName = recordName(record.memoID)
        var createdTemporary = false
        var temporaryIdentity: FileIdentity?
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(record)
            guard !encoded.isEmpty, encoded.count <= Self.maximumRecordBytes else {
                throw DeliveryJournalError.invalidRecord
            }
            let file = temporaryName.withCString {
                openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard file >= 0 else { throw DeliveryJournalError.fileSystemFailure }
            createdTemporary = true
            do {
                var metadata = stat()
                guard fstat(file, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_uid == getuid(),
                      metadata.st_nlink == 1,
                      metadata.st_mode & 0o077 == 0
                else { throw DeliveryJournalError.fileSystemFailure }
                temporaryIdentity = FileIdentity(metadata)
                try Self.writeAll(encoded, descriptor: file)
                guard fsync(file) == 0 else { throw DeliveryJournalError.fileSystemFailure }
            } catch {
                Darwin.close(file)
                throw error
            }
            Darwin.close(file)
            try faultInjector(.beforeRename)
            guard let temporaryIdentity,
                  Self.entryIdentity(
                      temporaryName,
                      directoryDescriptor: descriptor
                  ) == temporaryIdentity
            else { throw DeliveryJournalError.fileSystemFailure }
            let result = temporaryName.withCString { source in
                destinationName.withCString { destination in
                    renameatx_np(
                        descriptor,
                        source,
                        descriptor,
                        destination,
                        replacing ? 0 : UInt32(RENAME_EXCL)
                    )
                }
            }
            guard result == 0 else {
                if !replacing, errno == EEXIST { throw DeliveryJournalError.alreadyExists }
                throw DeliveryJournalError.fileSystemFailure
            }
            createdTemporary = false
            guard Self.entryIdentity(
                destinationName,
                directoryDescriptor: descriptor
            ) == temporaryIdentity else {
                throw DeliveryJournalError.fileSystemFailure
            }
            guard fsync(descriptor) == 0 else { throw DeliveryJournalError.fileSystemFailure }
        } catch let error as DeliveryJournalError {
            if createdTemporary {
                try? faultInjector(.beforeTemporaryCleanup)
                Self.unlinkIfIdentityMatches(
                    temporaryName,
                    identity: temporaryIdentity,
                    directoryDescriptor: descriptor
                )
            }
            throw error
        } catch {
            if createdTemporary {
                try? faultInjector(.beforeTemporaryCleanup)
                Self.unlinkIfIdentityMatches(
                    temporaryName,
                    identity: temporaryIdentity,
                    directoryDescriptor: descriptor
                )
            }
            throw DeliveryJournalError.fileSystemFailure
        }
    }

    private func recordName(_ memoID: MemoID) -> String {
        "\(memoID.rawValue).json"
    }

    private static func prepareRoot(_ root: URL) throws -> FileIdentity {
        do {
            if mkdir(root.path, 0o700) != 0, errno != EEXIST {
                throw DeliveryJournalError.invalidRoot
            }
            let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw DeliveryJournalError.invalidRoot }
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(),
                  fchmod(descriptor, 0o700) == 0,
                  fsync(descriptor) == 0
            else { throw DeliveryJournalError.invalidRoot }
            return FileIdentity(metadata)
        } catch let error as DeliveryJournalError {
            throw error
        } catch {
            throw DeliveryJournalError.invalidRoot
        }
    }

    private static func entryIdentity(
        _ name: String,
        directoryDescriptor: Int32
    ) -> FileIdentity? {
        var metadata = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0
        else { return nil }
        return FileIdentity(metadata)
    }

    private static func unlinkIfIdentityMatches(
        _ name: String,
        identity: FileIdentity?,
        directoryDescriptor: Int32
    ) {
        guard let identity,
              entryIdentity(name, directoryDescriptor: directoryDescriptor) == identity
        else { return }
        _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw DeliveryJournalError.fileSystemFailure }
                offset += written
            }
        }
    }
}

private struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}
