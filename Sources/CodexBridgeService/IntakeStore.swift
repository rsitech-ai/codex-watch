import CodexBridgeShared
import Darwin
import Foundation

public enum IntakeStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidRoot
    case lengthMismatch
    case digestMismatch
    case identityConflict
    case corruptRecord
    case inFlightWriter
    case fileSystemFailure
    case invalidEnumerationLimit
    case tooManyRecords
}

public struct IntakeRequest: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let byteCount: Int
    public let revision: UInt64
    public let capturedAt: Date
    public let localeHint: String?

    public init(
        memoID: MemoID,
        audioSHA256: String,
        byteCount: Int,
        revision: UInt64,
        capturedAt: Date = .distantPast,
        localeHint: String? = nil
    ) throws {
        guard AudioDigest.isValidHex(audioSHA256),
              (1 ... BridgeConfiguration.defaultMaximumBodyBytes).contains(byteCount),
              revision > 0,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              revision < UInt64.max
        else {
            throw IntakeStoreError.invalidRequest
        }
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.byteCount = byteCount
        self.revision = revision
        self.capturedAt = capturedAt
        if let localeHint {
            guard !localeHint.isEmpty,
                  localeHint.utf8.count <= 64,
                  localeHint.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F })
            else { throw IntakeStoreError.invalidRequest }
        }
        self.localeHint = localeHint
    }
}

public enum IntakeCommitDisposition: Equatable, Sendable {
    case created
    case duplicate
}

public struct IntakeCommitResult: Equatable, Sendable {
    public let receipt: BridgeReceipt
    public let disposition: IntakeCommitDisposition

    public init(receipt: BridgeReceipt, disposition: IntakeCommitDisposition) {
        self.receipt = receipt
        self.disposition = disposition
    }
}

public struct CommittedIntakeRecord: Sendable {
    public let memoID: MemoID
    public let receipt: BridgeReceipt
    public let committedAudio: CommittedAudioAsset

    public init(memoID: MemoID, receipt: BridgeReceipt, committedAudio: CommittedAudioAsset) {
        self.memoID = memoID
        self.receipt = receipt
        self.committedAudio = committedAudio
    }
}

public struct CommittedIntakePage: Sendable {
    public let records: [CommittedIntakeRecord]
    public let hasMore: Bool

    public init(records: [CommittedIntakeRecord], hasMore: Bool) {
        self.records = records
        self.hasMore = hasMore
    }
}

public struct RetainedIntakeRecord: Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let deliveredAt: Date
    public let audioURL: URL

    public init(
        memoID: MemoID,
        audioSHA256: String,
        deliveredAt: Date,
        audioURL: URL
    ) {
        self.memoID = memoID
        self.audioSHA256 = audioSHA256
        self.deliveredAt = deliveredAt
        self.audioURL = audioURL
    }
}

public struct RetainedIntakePage: Sendable {
    public let records: [RetainedIntakeRecord]
    public let hasMore: Bool

    public init(records: [RetainedIntakeRecord], hasMore: Bool) {
        self.records = records
        self.hasMore = hasMore
    }
}

struct RetentionManifest: Codable, Equatable, Sendable {
    let memoID: MemoID
    let audioSHA256: String
    let deliveredAt: Date
}

public actor IntakeStore {
    private static let audioName = "audio.m4a"
    private static let receiptName = "receipt.json"
    private static let retentionManifestName = "retention.json"
    private static let temporaryPrefix = ".incoming-"

    private let rootURL: URL
    private let rootIdentity: IntakeFileIdentity
    private let retentionRootURL: URL?
    private let retentionRootIdentity: IntakeFileIdentity?
    private let fileManager: FileManager
    private let mutationHook: StreamingIntakeMutationHook
    private let writeOperation: StreamingIntakeWriteOperation
    private let rootSyncOperation: StreamingIntakeRootSyncOperation

    public init(
        rootURL: URL,
        retentionRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            rootURL: rootURL,
            retentionRootURL: retentionRootURL,
            fileManager: fileManager,
            mutationHook: { _, _ in },
            writeOperation: { descriptor, buffer, count in
                Darwin.write(descriptor, buffer, count)
            },
            rootSyncOperation: { descriptor in
                Darwin.fsync(descriptor)
            }
        )
    }

    init(
        rootURL: URL,
        mutationHook: @escaping StreamingIntakeMutationHook
    ) throws {
        try self.init(
            rootURL: rootURL,
            mutationHook: mutationHook,
            writeOperation: { descriptor, buffer, count in
                Darwin.write(descriptor, buffer, count)
            },
            rootSyncOperation: { descriptor in
                Darwin.fsync(descriptor)
            }
        )
    }

    init(
        rootURL: URL,
        writeOperation: @escaping StreamingIntakeWriteOperation
    ) throws {
        try self.init(
            rootURL: rootURL,
            mutationHook: { _, _ in },
            writeOperation: writeOperation,
            rootSyncOperation: { descriptor in
                Darwin.fsync(descriptor)
            }
        )
    }

    init(
        rootURL: URL,
        rootSyncOperation: @escaping StreamingIntakeRootSyncOperation
    ) throws {
        try self.init(
            rootURL: rootURL,
            mutationHook: { _, _ in },
            writeOperation: { descriptor, buffer, count in
                Darwin.write(descriptor, buffer, count)
            },
            rootSyncOperation: rootSyncOperation
        )
    }

    init(
        rootURL: URL,
        retentionRootURL: URL? = nil,
        fileManager: FileManager = .default,
        mutationHook: @escaping StreamingIntakeMutationHook,
        writeOperation: @escaping StreamingIntakeWriteOperation,
        rootSyncOperation: @escaping StreamingIntakeRootSyncOperation
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.retentionRootURL = retentionRootURL?.standardizedFileURL
        self.fileManager = fileManager
        self.mutationHook = mutationHook
        self.writeOperation = writeOperation
        self.rootSyncOperation = rootSyncOperation
        self.rootIdentity = try Self.prepareRoot(self.rootURL, fileManager: fileManager)
        if let retentionRootURL = self.retentionRootURL {
            guard retentionRootURL != self.rootURL else { throw IntakeStoreError.invalidRoot }
            self.retentionRootIdentity = try Self.prepareRoot(
                retentionRootURL,
                fileManager: fileManager
            )
            try Self.requireSameVolume(self.rootURL, retentionRootURL)
        } else {
            self.retentionRootIdentity = nil
        }
        try StreamingIntakeWriter.cleanInterruptedDirectories(
            rootURL: self.rootURL,
            rootIdentity: rootIdentity,
            mutationHook: mutationHook,
            rootSyncOperation: rootSyncOperation
        )
    }

    public func beginStreamingCommit(request: IntakeRequest) throws -> StreamingIntakeWriter {
        try StreamingIntakeWriter(
            rootURL: rootURL,
            rootIdentity: rootIdentity,
            retentionRootURL: retentionRootURL,
            retentionRootIdentity: retentionRootIdentity,
            request: request,
            mutationHook: mutationHook,
            writeOperation: writeOperation,
            rootSyncOperation: rootSyncOperation
        )
    }

    public func commit(
        request: IntakeRequest,
        body: Data,
        receivedAt: Date = Date()
    ) throws -> IntakeCommitResult {
        let (acknowledgedRevision, revisionOverflowed) = request.revision.addingReportingOverflow(1)
        guard !revisionOverflowed else { throw IntakeStoreError.invalidRequest }
        guard body.count == request.byteCount else { throw IntakeStoreError.lengthMismatch }
        guard AudioDigest.hex(body) == request.audioSHA256 else { throw IntakeStoreError.digestMismatch }

        return try withLockedIntakeRoot { _ in
            if let retained = try withLockedRetentionRoot({
                try retainedDuplicate(
                    request: request,
                    acknowledgedRevision: acknowledgedRevision
                )
            }) {
                return retained
            }
            let destination = directory(for: request.memoID)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try loadReceipt(at: destination, expectedMemoID: request.memoID)
                guard existing.audioSHA256 == request.audioSHA256,
                      existing.acknowledgedRevision == acknowledgedRevision,
                      existing.capturedAt == request.capturedAt,
                      existing.localeHint == request.localeHint
                else {
                    throw IntakeStoreError.identityConflict
                }
                let existingAudio = try loadAudio(at: destination)
                guard AudioDigest.hex(existingAudio) == existing.audioSHA256 else {
                    throw IntakeStoreError.corruptRecord
                }
                return IntakeCommitResult(receipt: existing, disposition: .duplicate)
            }

            let temporary = rootURL.appendingPathComponent(
                Self.temporaryPrefix + UUID().uuidString,
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: temporary,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try Self.setPermissions(0o700, at: temporary)

                let audioURL = temporary.appendingPathComponent(Self.audioName)
                try body.write(to: audioURL, options: .withoutOverwriting)
                try Self.setPermissions(0o600, at: audioURL)
                try Self.synchronizeFile(audioURL)

                let receipt = try BridgeReceipt(
                    memoID: request.memoID,
                    audioSHA256: request.audioSHA256,
                    acknowledgedRevision: acknowledgedRevision,
                    capturedAt: request.capturedAt,
                    localeHint: request.localeHint,
                    receivedAt: receivedAt
                )
                let receiptURL = temporary.appendingPathComponent(Self.receiptName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(receipt).write(to: receiptURL, options: .withoutOverwriting)
                try Self.setPermissions(0o600, at: receiptURL)
                try Self.synchronizeFile(receiptURL)
                try Self.synchronizeDirectory(temporary)

                try mutationHook(.beforePublication, temporary)
                try fileManager.moveItem(at: temporary, to: destination)
                try Self.synchronizeDirectory(rootURL)
                return IntakeCommitResult(receipt: receipt, disposition: .created)
            } catch let error as IntakeStoreError {
                try? fileManager.removeItem(at: temporary)
                throw error
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw IntakeStoreError.fileSystemFailure
            }
        }
    }

    private func retainedDuplicate(
        request: IntakeRequest,
        acknowledgedRevision: UInt64
    ) throws -> IntakeCommitResult? {
        guard let retentionRootURL else { return nil }
        let active = directory(for: request.memoID)
        let retained = retentionDirectory(for: request.memoID, root: retentionRootURL)
        let activeExists = fileManager.fileExists(atPath: active.path)
        let retainedExists = fileManager.fileExists(atPath: retained.path)
        guard !(activeExists && retainedExists) else { throw IntakeStoreError.corruptRecord }
        guard retainedExists else { return nil }
        guard try retainedRecord(for: request.memoID) != nil else {
            throw IntakeStoreError.corruptRecord
        }
        let existing = try loadReceipt(at: retained, expectedMemoID: request.memoID)
        guard existing.audioSHA256 == request.audioSHA256,
              existing.acknowledgedRevision == acknowledgedRevision,
              existing.capturedAt == request.capturedAt,
              existing.localeHint == request.localeHint
        else { throw IntakeStoreError.identityConflict }
        let existingAudio = try loadAudio(at: retained)
        let manifest = try loadRetentionManifest(at: retained, expectedMemoID: request.memoID)
        guard existingAudio.count == request.byteCount,
              AudioDigest.hex(existingAudio) == existing.audioSHA256,
              manifest.audioSHA256 == existing.audioSHA256
        else { throw IntakeStoreError.corruptRecord }
        return IntakeCommitResult(receipt: existing, disposition: .duplicate)
    }

    private func withLockedIntakeRoot<T>(_ operation: (Int32) throws -> T) throws -> T {
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw IntakeStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        try verifyIntakeRoot(descriptor)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw IntakeStoreError.fileSystemFailure
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try verifyIntakeRoot(descriptor)
        return try operation(descriptor)
    }

    private func verifyIntakeRoot(_ descriptor: Int32) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(rootURL.path, &named) == 0,
              IntakeFileSecurity.isPrivateDirectory(opened),
              IntakeFileSecurity.isPrivateDirectory(named),
              IntakeFileIdentity(opened) == rootIdentity,
              IntakeFileIdentity(named) == rootIdentity
        else { throw IntakeStoreError.invalidRoot }
    }

    private func withLockedRetentionRoot<T>(_ operation: () throws -> T) throws -> T {
        guard let retentionRootURL, let retentionRootIdentity else {
            return try operation()
        }
        let descriptor = Darwin.open(
            retentionRootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw IntakeStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        try Self.verifyRoot(
            descriptor,
            rootURL: retentionRootURL,
            rootIdentity: retentionRootIdentity
        )
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw IntakeStoreError.fileSystemFailure
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Self.verifyRoot(
            descriptor,
            rootURL: retentionRootURL,
            rootIdentity: retentionRootIdentity
        )
        return try operation()
    }

    public func receipt(for memoID: MemoID) throws -> BridgeReceipt? {
        let destination = directory(for: memoID)
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        return try loadReceipt(at: destination, expectedMemoID: memoID)
    }

    public func audio(for memoID: MemoID) throws -> Data? {
        let destination = directory(for: memoID)
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        return try loadAudio(at: destination)
    }

    public func committedAudioURL(for memoID: MemoID) throws -> URL? {
        try committedAudioAsset(for: memoID)?.url
    }

    public func committedAudioAsset(for memoID: MemoID) throws -> CommittedAudioAsset? {
        let destination = directory(for: memoID)
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        let receipt = try loadReceipt(at: destination, expectedMemoID: memoID)
        let audioURL = destination.appendingPathComponent(Self.audioName).standardizedFileURL
        do {
            return try CommittedAudioAsset(
                url: audioURL,
                expectedSHA256: receipt.audioSHA256
            )
        } catch {
            throw IntakeStoreError.corruptRecord
        }
    }

    public func committedRecord(for memoID: MemoID) throws -> CommittedIntakeRecord? {
        let destination = directory(for: memoID)
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        let receipt = try loadReceipt(at: destination, expectedMemoID: memoID)
        guard let committedAudio = try committedAudioAsset(for: memoID) else {
            throw IntakeStoreError.corruptRecord
        }
        return CommittedIntakeRecord(
            memoID: memoID,
            receipt: receipt,
            committedAudio: committedAudio
        )
    }

    public func retainDelivered(memoID: MemoID, deliveredAt: Date) throws {
        guard deliveredAt.timeIntervalSinceReferenceDate.isFinite,
              let retentionRootURL
        else { throw IntakeStoreError.invalidRequest }
        try withLockedIntakeRoot { _ in
            try withLockedRetentionRoot {
                let source = directory(for: memoID)
                guard fileManager.fileExists(atPath: source.path) else {
                    if try retainedRecord(for: memoID) != nil { return }
                    throw IntakeStoreError.corruptRecord
                }
                let receipt = try loadReceipt(at: source, expectedMemoID: memoID)
                _ = try loadAudio(at: source)
                let manifest = RetentionManifest(
                    memoID: memoID,
                    audioSHA256: receipt.audioSHA256,
                    deliveredAt: deliveredAt
                )
                let manifestURL = source.appendingPathComponent(Self.retentionManifestName)
                if fileManager.fileExists(atPath: manifestURL.path) {
                    guard try loadRetentionManifest(
                        at: source,
                        expectedMemoID: memoID
                    ) == manifest else {
                        throw IntakeStoreError.identityConflict
                    }
                } else {
                    do {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        try encoder.encode(manifest).write(
                            to: manifestURL,
                            options: .withoutOverwriting
                        )
                        try Self.setPermissions(0o600, at: manifestURL)
                        try Self.synchronizeFile(manifestURL)
                        try Self.synchronizeDirectory(source)
                    } catch let error as IntakeStoreError {
                        throw error
                    } catch {
                        throw IntakeStoreError.fileSystemFailure
                    }
                }

                let destination = retentionDirectory(for: memoID, root: retentionRootURL)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw IntakeStoreError.identityConflict
                }
                guard rename(source.path, destination.path) == 0 else {
                    throw IntakeStoreError.fileSystemFailure
                }
                try Self.synchronizeDirectory(rootURL)
                try Self.synchronizeDirectory(retentionRootURL)
            }
        }
    }

    public func retainedRecord(for memoID: MemoID) throws -> RetainedIntakeRecord? {
        guard let retentionRootURL else { throw IntakeStoreError.invalidRoot }
        let directory = retentionDirectory(for: memoID, root: retentionRootURL)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try Self.requirePrivateDirectory(directory)
        let allowedNames = Set([Self.audioName, Self.receiptName, Self.retentionManifestName])
        let names = try Set(fileManager.contentsOfDirectory(atPath: directory.path))
        guard names == allowedNames else { throw IntakeStoreError.corruptRecord }
        let receipt = try loadReceipt(at: directory, expectedMemoID: memoID)
        let manifest = try loadRetentionManifest(at: directory, expectedMemoID: memoID)
        guard manifest.audioSHA256 == receipt.audioSHA256 else {
            throw IntakeStoreError.corruptRecord
        }
        let audioURL = directory.appendingPathComponent(Self.audioName).standardizedFileURL
        let committedAudio: CommittedAudioAsset
        do {
            committedAudio = try CommittedAudioAsset(
                url: audioURL,
                expectedSHA256: receipt.audioSHA256
            )
        } catch {
            throw IntakeStoreError.corruptRecord
        }
        return RetainedIntakeRecord(
            memoID: memoID,
            audioSHA256: committedAudio.expectedSHA256,
            deliveredAt: manifest.deliveredAt,
            audioURL: audioURL
        )
    }

    public func retainedRecordPage(
        maximumEntries: Int,
        afterMemoID: MemoID? = nil
    ) throws -> RetainedIntakePage {
        guard maximumEntries > 0, let retentionRootURL else {
            throw IntakeStoreError.invalidEnumerationLimit
        }
        do {
            let children = try fileManager.contentsOfDirectory(
                at: retentionRootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let filtered = children.filter { child in
                guard let afterMemoID else { return true }
                return child.lastPathComponent > afterMemoID.rawValue
            }
            let selected = filtered.prefix(maximumEntries)
            let records = try selected.map { child in
                var values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                } catch {
                    throw IntakeStoreError.corruptRecord
                }
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let memoID = try? MemoID(child.lastPathComponent),
                      let retained = try retainedRecord(for: memoID)
                else { throw IntakeStoreError.corruptRecord }
                return retained
            }
            return RetainedIntakePage(records: records, hasMore: filtered.count > maximumEntries)
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.fileSystemFailure
        }
    }

    public func removeRetained(memoID: MemoID, deliveredBeforeOrAt cutoff: Date) throws {
        try withLockedIntakeRoot { rootDescriptor in
            try withLockedRetentionRoot {
                guard cutoff.timeIntervalSinceReferenceDate.isFinite,
                      let retentionRootURL,
                      let record = try retainedRecord(for: memoID),
                      record.deliveredAt <= cutoff
                else { throw IntakeStoreError.invalidRequest }
                try rejectLiveWriter(for: memoID, rootDescriptor: rootDescriptor)
                let directory = retentionDirectory(for: memoID, root: retentionRootURL)
                do {
                    try fileManager.removeItem(at: directory)
                    try Self.synchronizeDirectory(retentionRootURL)
                } catch {
                    throw IntakeStoreError.fileSystemFailure
                }
            }
        }
    }

    private func rejectLiveWriter(for memoID: MemoID, rootDescriptor: Int32) throws {
        let matchingPrefix = ".incoming-\(memoID.rawValue)"
        for name in try Self.directoryEntryNames(descriptor: rootDescriptor)
        where name.lowercased().hasPrefix(matchingPrefix) {
            guard StreamingIntakeWriter.inFlightMemoID(forTemporaryName: name) == memoID else {
                throw IntakeStoreError.corruptRecord
            }

            var named = stat()
            guard name.withCString({
                fstatat(rootDescriptor, $0, &named, AT_SYMLINK_NOFOLLOW)
            }) == 0,
            IntakeFileSecurity.isPrivateDirectory(named)
            else { throw IntakeStoreError.corruptRecord }

            let descriptor = name.withCString {
                openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else { throw IntakeStoreError.corruptRecord }
            defer { Darwin.close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  IntakeFileSecurity.isPrivateDirectory(opened),
                  IntakeFileIdentity(opened) == IntakeFileIdentity(named)
            else { throw IntakeStoreError.corruptRecord }

            errno = 0
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                _ = flock(descriptor, LOCK_UN)
                continue
            }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw IntakeStoreError.inFlightWriter
            }
            throw IntakeStoreError.fileSystemFailure
        }
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let independent = ".".withCString {
            openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard independent >= 0 else { throw IntakeStoreError.fileSystemFailure }
        guard let directory = fdopendir(independent) else {
            Darwin.close(independent)
            throw IntakeStoreError.fileSystemFailure
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw IntakeStoreError.fileSystemFailure }
        return names
    }

    public func committedRecords(maximumEntries: Int) throws -> [CommittedIntakeRecord] {
        let page = try committedRecordPage(maximumEntries: maximumEntries)
        guard !page.hasMore else { throw IntakeStoreError.tooManyRecords }
        return page.records
    }

    /// Reads a bounded, deterministic page without making a large durable
    /// intake set an in-memory queue. `afterMemoID` is exclusive.
    public func committedRecordPage(
        maximumEntries: Int,
        afterMemoID: MemoID? = nil
    ) throws -> CommittedIntakePage {
        guard maximumEntries > 0 else { throw IntakeStoreError.invalidEnumerationLimit }
        do {
            let children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let filtered = children.filter { child in
                guard let afterMemoID else { return true }
                return child.lastPathComponent > afterMemoID.rawValue
            }
            let selected = filtered.prefix(maximumEntries)

            let records = try selected.map { child in
                var values: URLResourceValues
                do {
                    values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                } catch {
                    throw IntakeStoreError.corruptRecord
                }
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      let memoID = try? MemoID(child.lastPathComponent)
                else { throw IntakeStoreError.corruptRecord }

                guard let record = try committedRecord(for: memoID) else {
                    throw IntakeStoreError.corruptRecord
                }
                return record
            }
            return CommittedIntakePage(records: records, hasMore: filtered.count > maximumEntries)
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.fileSystemFailure
        }
    }

    private func directory(for memoID: MemoID) -> URL {
        rootURL.appendingPathComponent(memoID.rawValue, isDirectory: true)
    }

    private func retentionDirectory(for memoID: MemoID, root: URL) -> URL {
        root.appendingPathComponent(memoID.rawValue, isDirectory: true)
    }

    private func loadRetentionManifest(
        at directory: URL,
        expectedMemoID: MemoID
    ) throws -> RetentionManifest {
        let url = directory.appendingPathComponent(Self.retentionManifestName)
        do {
            try Self.requireRegularPrivateFile(url)
            let manifest = try JSONDecoder().decode(
                RetentionManifest.self,
                from: Data(contentsOf: url)
            )
            guard manifest.memoID == expectedMemoID,
                  AudioDigest.isValidHex(manifest.audioSHA256),
                  manifest.deliveredAt.timeIntervalSinceReferenceDate.isFinite
            else { throw IntakeStoreError.corruptRecord }
            return manifest
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.corruptRecord
        }
    }

    private func loadReceipt(at directory: URL, expectedMemoID: MemoID) throws -> BridgeReceipt {
        try Self.requirePrivateDirectory(directory)
        let receiptURL = directory.appendingPathComponent(Self.receiptName)
        do {
            try Self.requireRegularPrivateFile(receiptURL)
            let receipt = try JSONDecoder().decode(BridgeReceipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.memoID == expectedMemoID else { throw IntakeStoreError.corruptRecord }
            return receipt
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.corruptRecord
        }
    }

    private func loadAudio(at directory: URL) throws -> Data {
        let audioURL = directory.appendingPathComponent(Self.audioName)
        do {
            try Self.requireRegularPrivateFile(audioURL)
            return try Data(contentsOf: audioURL, options: .mappedIfSafe)
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.corruptRecord
        }
    }

    private static func prepareRoot(
        _ rootURL: URL,
        fileManager: FileManager
    ) throws -> IntakeFileIdentity {
        guard rootURL.isFileURL else { throw IntakeStoreError.invalidRoot }
        do {
            if fileManager.fileExists(atPath: rootURL.path) {
                try requirePrivateDirectory(rootURL, repairPermissions: true)
            } else {
                try fileManager.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try setPermissions(0o700, at: rootURL)
            }
            let descriptor = Darwin.open(
                rootURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else { throw IntakeStoreError.invalidRoot }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            var named = stat()
            guard fstat(descriptor, &opened) == 0,
                  lstat(rootURL.path, &named) == 0,
                  IntakeFileSecurity.isPrivateDirectory(opened),
                  IntakeFileSecurity.isPrivateDirectory(named),
                  IntakeFileIdentity(opened) == IntakeFileIdentity(named),
                  fsync(descriptor) == 0
            else { throw IntakeStoreError.invalidRoot }
            return IntakeFileIdentity(opened)
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.invalidRoot
        }
    }

    private static func verifyRoot(
        _ descriptor: Int32,
        rootURL: URL,
        rootIdentity: IntakeFileIdentity
    ) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(rootURL.path, &named) == 0,
              IntakeFileSecurity.isPrivateDirectory(opened),
              IntakeFileSecurity.isPrivateDirectory(named),
              IntakeFileIdentity(opened) == rootIdentity,
              IntakeFileIdentity(named) == rootIdentity
        else { throw IntakeStoreError.invalidRoot }
    }

    private static func requireSameVolume(_ first: URL, _ second: URL) throws {
        var firstInfo = stat()
        var secondInfo = stat()
        guard lstat(first.path, &firstInfo) == 0,
              lstat(second.path, &secondInfo) == 0,
              firstInfo.st_dev == secondInfo.st_dev
        else { throw IntakeStoreError.invalidRoot }
    }

    private static func requirePrivateDirectory(
        _ url: URL,
        repairPermissions: Bool = false
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid()
        else {
            throw IntakeStoreError.invalidRoot
        }
        if repairPermissions {
            try setPermissions(0o700, at: url)
        } else if info.st_mode & 0o077 != 0 {
            throw IntakeStoreError.corruptRecord
        }
    }

    private static func requireRegularPrivateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0
        else {
            throw IntakeStoreError.corruptRecord
        }
    }

    private static func setPermissions(_ mode: mode_t, at url: URL) throws {
        guard chmod(url.path, mode) == 0 else { throw IntakeStoreError.fileSystemFailure }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw IntakeStoreError.fileSystemFailure }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw IntakeStoreError.fileSystemFailure }
    }
}

struct IntakeFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}

enum IntakeFileSecurity {
    static func isPrivateDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == getuid()
            && metadata.st_mode & 0o7777 == 0o700
    }

    static func isPrivateRegularFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600
    }
}
