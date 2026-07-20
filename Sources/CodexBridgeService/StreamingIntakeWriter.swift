import CodexBridgeShared
import CryptoKit
import Darwin
import Foundation

enum StreamingIntakeMutationBoundary: Equatable, Sendable {
    case afterAudioCreation
    case beforeInitializationCleanup
    case beforeCancellationCleanup
    case beforeRestartCleanup
    case beforeOwnedCleanup
    case beforePublication
    case afterQuarantineRename
    case beforeFinalDirectoryRemoval
}

typealias StreamingIntakeMutationHook = @Sendable (
    StreamingIntakeMutationBoundary,
    URL
) throws -> Void

typealias StreamingIntakeWriteOperation = @Sendable (
    Int32,
    UnsafeRawPointer?,
    Int
) -> Int

typealias StreamingIntakeRootSyncOperation = @Sendable (Int32) -> Int32

public actor StreamingIntakeWriter {
    private static let audioName = "audio.m4a"
    private static let receiptName = "receipt.json"
    private static let retentionManifestName = "retention.json"
    private static let temporaryPrefix = ".incoming-"
    private static let cleanupPrefix = ".cleanup-"
    private static let maximumReceiptBytes = 16 * 1_024
    private static let maximumRetentionManifestBytes = 16 * 1_024

    private let rootURL: URL
    private let rootIdentity: IntakeFileIdentity
    private let retentionRootURL: URL?
    private let retentionRootIdentity: IntakeFileIdentity?
    private let request: IntakeRequest
    private let temporaryName: String
    private let temporaryIdentity: IntakeFileIdentity
    private let audioIdentity: IntakeFileIdentity
    private let mutationHook: StreamingIntakeMutationHook
    private let writeOperation: StreamingIntakeWriteOperation
    private let rootSyncOperation: StreamingIntakeRootSyncOperation

    private var rootDescriptor: Int32
    private var temporaryDescriptor: Int32
    private var audioDescriptor: Int32
    private var receiptIdentity: IntakeFileIdentity?
    private var receivedByteCount = 0
    private var hasher = SHA256()
    private var active = true

    init(
        rootURL: URL,
        rootIdentity: IntakeFileIdentity,
        retentionRootURL: URL?,
        retentionRootIdentity: IntakeFileIdentity?,
        request: IntakeRequest,
        mutationHook: @escaping StreamingIntakeMutationHook,
        writeOperation: @escaping StreamingIntakeWriteOperation,
        rootSyncOperation: @escaping StreamingIntakeRootSyncOperation
    ) throws {
        let opened = try Self.openTemporary(
            rootURL: rootURL,
            rootIdentity: rootIdentity,
            memoID: request.memoID,
            mutationHook: mutationHook,
            rootSyncOperation: rootSyncOperation
        )
        self.rootURL = rootURL
        self.rootIdentity = rootIdentity
        self.retentionRootURL = retentionRootURL
        self.retentionRootIdentity = retentionRootIdentity
        self.request = request
        self.temporaryName = opened.name
        self.temporaryIdentity = opened.directoryIdentity
        self.audioIdentity = opened.audioIdentity
        self.mutationHook = mutationHook
        self.writeOperation = writeOperation
        self.rootSyncOperation = rootSyncOperation
        self.rootDescriptor = opened.rootDescriptor
        self.temporaryDescriptor = opened.directoryDescriptor
        self.audioDescriptor = opened.audioDescriptor
    }

    deinit {
        guard active else { return }
        if rootDescriptor >= 0, flock(rootDescriptor, LOCK_EX) == 0 {
            let rootIsVerified = (try? Self.verifyRoot(
                rootDescriptor,
                rootURL: rootURL,
                rootIdentity: rootIdentity
            )) != nil
            if rootIsVerified {
                try? Self.cleanupTemporary(
                    rootDescriptor: rootDescriptor,
                    rootURL: rootURL,
                    temporaryName: temporaryName,
                    temporaryIdentity: temporaryIdentity,
                    fileIdentities: Self.fileIdentities(
                        audioIdentity: audioIdentity,
                        receiptIdentity: receiptIdentity
                    ),
                    mutationHook: mutationHook,
                    rootSyncOperation: rootSyncOperation
                )
            }
            _ = flock(rootDescriptor, LOCK_UN)
        }
        if audioDescriptor >= 0 { Darwin.close(audioDescriptor) }
        if temporaryDescriptor >= 0 { Darwin.close(temporaryDescriptor) }
        if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
    }

    public func append(_ bytes: Data) throws {
        guard active else { throw IntakeStoreError.fileSystemFailure }
        guard bytes.count <= request.byteCount - receivedByteCount,
              receivedByteCount + bytes.count <= BridgeConfiguration.defaultMaximumBodyBytes
        else {
            throw terminate(with: .lengthMismatch)
        }

        do {
            try verifyAttachedTemporary(expectedAudioBytes: receivedByteCount)
            try Self.writeAll(
                bytes,
                descriptor: audioDescriptor,
                operation: writeOperation
            )
            let newByteCount = receivedByteCount + bytes.count
            try verifyAttachedTemporary(expectedAudioBytes: newByteCount)
            hasher.update(data: bytes)
            receivedByteCount = newByteCount
        } catch let error as IntakeStoreError {
            throw terminate(with: error)
        } catch {
            throw terminate(with: .fileSystemFailure)
        }
    }

    public func finish(receivedAt: Date) throws -> IntakeCommitResult {
        guard active else { throw IntakeStoreError.fileSystemFailure }
        guard receivedByteCount == request.byteCount else {
            throw terminate(with: .lengthMismatch)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == request.audioSHA256 else {
            throw terminate(with: .digestMismatch)
        }
        let (acknowledgedRevision, revisionOverflowed) = request.revision.addingReportingOverflow(1)
        guard !revisionOverflowed else {
            throw terminate(with: .invalidRequest)
        }

        do {
            try verifyAttachedTemporary(expectedAudioBytes: receivedByteCount)
            guard fsync(audioDescriptor) == 0 else {
                throw IntakeStoreError.fileSystemFailure
            }
            try verifyAttachedTemporary(expectedAudioBytes: receivedByteCount)

            let receipt = try BridgeReceipt(
                memoID: request.memoID,
                audioSHA256: request.audioSHA256,
                acknowledgedRevision: acknowledgedRevision,
                capturedAt: request.capturedAt,
                localeHint: request.localeHint,
                receivedAt: receivedAt
            )
            try writeReceipt(receipt)
            guard fsync(temporaryDescriptor) == 0 else {
                throw IntakeStoreError.fileSystemFailure
            }
            try verifyReadyToPublish()

            let outcome = try withLockedRoot {
                try mutationHook(
                    .beforePublication,
                    rootURL.appendingPathComponent(temporaryName, isDirectory: true)
                )
                return try publishOrLoadDuplicate(proposedReceipt: receipt)
            }
            switch outcome {
            case .created:
                active = false
                closeDescriptors()
                return IntakeCommitResult(receipt: receipt, disposition: .created)
            case let .duplicate(existing):
                try withLockedRoot {
                    try cleanupTemporary()
                }
                active = false
                closeDescriptors()
                return IntakeCommitResult(receipt: existing, disposition: .duplicate)
            }
        } catch let error as IntakeStoreError {
            throw terminate(with: error)
        } catch {
            throw terminate(with: .fileSystemFailure)
        }
    }

    public func cancel() {
        guard active else { return }
        try? withLockedRoot {
            try mutationHook(
                .beforeCancellationCleanup,
                rootURL.appendingPathComponent(temporaryName, isDirectory: true)
            )
            try cleanupTemporary()
        }
        active = false
        closeDescriptors()
    }

    static func cleanInterruptedDirectories(
        rootURL: URL,
        rootIdentity: IntakeFileIdentity,
        mutationHook: StreamingIntakeMutationHook,
        rootSyncOperation: StreamingIntakeRootSyncOperation
    ) throws {
        let root = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard root >= 0 else { throw IntakeStoreError.invalidRoot }
        defer { Darwin.close(root) }
        try verifyRoot(root, rootURL: rootURL, rootIdentity: rootIdentity)
        guard flock(root, LOCK_EX) == 0 else { throw IntakeStoreError.fileSystemFailure }
        defer { _ = flock(root, LOCK_UN) }
        try verifyRoot(root, rootURL: rootURL, rootIdentity: rootIdentity)

        for name in try directoryEntryNames(descriptor: root) where isOwnedTemporaryName(name) {
            guard let entry = entryMetadata(name, directoryDescriptor: root) else {
                throw IntakeStoreError.fileSystemFailure
            }

            let temporaryURL = rootURL.appendingPathComponent(name, isDirectory: true)
            if isIncomingTemporaryName(name), IntakeFileSecurity.isPrivateDirectory(entry) {
                let lease = name.withCString {
                    openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard lease >= 0 else { throw IntakeStoreError.fileSystemFailure }
                let lockResult = flock(lease, LOCK_EX | LOCK_NB)
                if lockResult != 0 {
                    let lockError = errno
                    Darwin.close(lease)
                    if lockError == EWOULDBLOCK || lockError == EAGAIN {
                        continue
                    }
                    throw IntakeStoreError.fileSystemFailure
                }
                do {
                    defer {
                        _ = flock(lease, LOCK_UN)
                        Darwin.close(lease)
                    }
                    var leasedMetadata = stat()
                    guard fstat(lease, &leasedMetadata) == 0,
                          IntakeFileSecurity.isPrivateDirectory(leasedMetadata),
                          IntakeFileIdentity(leasedMetadata) == IntakeFileIdentity(entry)
                    else { throw IntakeStoreError.fileSystemFailure }
                    try mutationHook(.beforeRestartCleanup, temporaryURL)
                    try cleanupTemporary(
                        rootDescriptor: root,
                        rootURL: rootURL,
                        temporaryName: name,
                        temporaryIdentity: IntakeFileIdentity(entry),
                        fileIdentities: nil,
                        mutationHook: mutationHook,
                        rootSyncOperation: rootSyncOperation
                    )
                }
            } else {
                try mutationHook(.beforeRestartCleanup, temporaryURL)
                try cleanupTemporary(
                    rootDescriptor: root,
                    rootURL: rootURL,
                    temporaryName: name,
                    temporaryIdentity: IntakeFileIdentity(entry),
                    fileIdentities: nil,
                    mutationHook: mutationHook,
                    rootSyncOperation: rootSyncOperation
                )
            }
        }
    }

    private func writeReceipt(_ receipt: BridgeReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(receipt)
        guard !encoded.isEmpty, encoded.count <= Self.maximumReceiptBytes else {
            throw IntakeStoreError.fileSystemFailure
        }
        let descriptor = Self.receiptName.withCString {
            openat(
                temporaryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else { throw IntakeStoreError.fileSystemFailure }
        do {
            var metadata = stat()
            guard fchmod(descriptor, 0o600) == 0,
                  fstat(descriptor, &metadata) == 0,
                  IntakeFileSecurity.isPrivateRegularFile(metadata)
            else { throw IntakeStoreError.fileSystemFailure }
            receiptIdentity = IntakeFileIdentity(metadata)
            try Self.writeAll(
                encoded,
                descriptor: descriptor,
                operation: writeOperation
            )
            guard fsync(descriptor) == 0 else { throw IntakeStoreError.fileSystemFailure }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
        guard let receiptIdentity,
              Self.privateFileIdentity(
                  Self.receiptName,
                  directoryDescriptor: temporaryDescriptor
              ) == receiptIdentity
        else { throw IntakeStoreError.fileSystemFailure }
    }

    private func verifyAttachedTemporary(expectedAudioBytes: Int) throws {
        try Self.verifyRoot(rootDescriptor, rootURL: rootURL, rootIdentity: rootIdentity)
        var directoryMetadata = stat()
        var audioMetadata = stat()
        guard fstat(temporaryDescriptor, &directoryMetadata) == 0,
              IntakeFileSecurity.isPrivateDirectory(directoryMetadata),
              IntakeFileIdentity(directoryMetadata) == temporaryIdentity,
              let namedDirectory = Self.entryMetadata(
                  temporaryName,
                  directoryDescriptor: rootDescriptor
              ),
              IntakeFileSecurity.isPrivateDirectory(namedDirectory),
              IntakeFileIdentity(namedDirectory) == temporaryIdentity,
              fstat(audioDescriptor, &audioMetadata) == 0,
              IntakeFileSecurity.isPrivateRegularFile(audioMetadata),
              IntakeFileIdentity(audioMetadata) == audioIdentity,
              audioMetadata.st_size == expectedAudioBytes,
              Self.privateFileIdentity(
                  Self.audioName,
                  directoryDescriptor: temporaryDescriptor
              ) == audioIdentity
        else { throw IntakeStoreError.fileSystemFailure }
    }

    private func verifyReadyToPublish() throws {
        try verifyAttachedTemporary(expectedAudioBytes: receivedByteCount)
        guard let receiptIdentity,
              Self.privateFileIdentity(
                  Self.receiptName,
                  directoryDescriptor: temporaryDescriptor
              ) == receiptIdentity,
              Set(try Self.directoryEntryNames(descriptor: temporaryDescriptor))
                == Set([Self.audioName, Self.receiptName])
        else { throw IntakeStoreError.fileSystemFailure }
    }

    private func withLockedRoot<T>(_ operation: () throws -> T) throws -> T {
        try Self.verifyRoot(rootDescriptor, rootURL: rootURL, rootIdentity: rootIdentity)
        guard flock(rootDescriptor, LOCK_EX) == 0 else {
            throw IntakeStoreError.fileSystemFailure
        }
        defer { _ = flock(rootDescriptor, LOCK_UN) }
        try Self.verifyRoot(rootDescriptor, rootURL: rootURL, rootIdentity: rootIdentity)
        return try operation()
    }

    private func publishOrLoadDuplicate(proposedReceipt: BridgeReceipt) throws -> PublishOutcome {
        try verifyReadyToPublish()
        if let retentionRootURL, let retentionRootIdentity {
            return try withLockedRetentionRoot(
                rootURL: retentionRootURL,
                rootIdentity: retentionRootIdentity
            ) { retainedRootDescriptor in
                try publishOrLoadDuplicate(
                    proposedReceipt: proposedReceipt,
                    retainedRootDescriptor: retainedRootDescriptor
                )
            }
        }
        guard retentionRootURL == nil, retentionRootIdentity == nil else {
            throw IntakeStoreError.invalidRoot
        }
        return try publishOrLoadDuplicate(
            proposedReceipt: proposedReceipt,
            retainedRootDescriptor: nil
        )
    }

    private func publishOrLoadDuplicate(
        proposedReceipt: BridgeReceipt,
        retainedRootDescriptor: Int32?
    ) throws -> PublishOutcome {
        let destinationName = request.memoID.rawValue
        let activeExists = Self.entryMetadata(
            destinationName,
            directoryDescriptor: rootDescriptor
        ) != nil
        let retainedExists = retainedRootDescriptor.flatMap {
            Self.entryMetadata(destinationName, directoryDescriptor: $0)
        } != nil
        guard !(activeExists && retainedExists) else {
            throw IntakeStoreError.corruptRecord
        }
        if retainedExists {
            guard let retainedRootDescriptor else {
                throw IntakeStoreError.corruptRecord
            }
            return .duplicate(try loadRetainedDuplicate(
                proposedReceipt: proposedReceipt,
                retainedRootDescriptor: retainedRootDescriptor
            ))
        }
        if activeExists {
            return .duplicate(try loadDuplicate(proposedReceipt: proposedReceipt))
        }

        let renameResult = temporaryName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameResult == 0 {
            guard let destination = Self.entryMetadata(
                destinationName,
                directoryDescriptor: rootDescriptor
            ),
                IntakeFileSecurity.isPrivateDirectory(destination),
                IntakeFileIdentity(destination) == temporaryIdentity,
                rootSyncOperation(rootDescriptor) == 0
            else { throw IntakeStoreError.fileSystemFailure }
            return .created
        }
        guard errno == EEXIST else { throw IntakeStoreError.fileSystemFailure }
        if let retainedRootDescriptor,
           Self.entryMetadata(destinationName, directoryDescriptor: retainedRootDescriptor) != nil
        {
            guard Self.entryMetadata(destinationName, directoryDescriptor: rootDescriptor) == nil else {
                throw IntakeStoreError.corruptRecord
            }
            return .duplicate(try loadRetainedDuplicate(
                proposedReceipt: proposedReceipt,
                retainedRootDescriptor: retainedRootDescriptor
            ))
        }
        return .duplicate(try loadDuplicate(proposedReceipt: proposedReceipt))
    }

    private func withLockedRetentionRoot<T>(
        rootURL: URL,
        rootIdentity: IntakeFileIdentity,
        operation: (Int32) throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw IntakeStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        try Self.verifyRoot(descriptor, rootURL: rootURL, rootIdentity: rootIdentity)
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw IntakeStoreError.fileSystemFailure
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Self.verifyRoot(descriptor, rootURL: rootURL, rootIdentity: rootIdentity)
        return try operation(descriptor)
    }

    private func loadDuplicate(proposedReceipt: BridgeReceipt) throws -> BridgeReceipt {
        let destinationName = request.memoID.rawValue
        let directory = destinationName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw IntakeStoreError.corruptRecord }
        defer { Darwin.close(directory) }

        var directoryMetadata = stat()
        guard fstat(directory, &directoryMetadata) == 0,
              IntakeFileSecurity.isPrivateDirectory(directoryMetadata),
              let namedDirectory = Self.entryMetadata(
                  destinationName,
                  directoryDescriptor: rootDescriptor
              ),
              IntakeFileSecurity.isPrivateDirectory(namedDirectory),
              IntakeFileIdentity(namedDirectory) == IntakeFileIdentity(directoryMetadata),
              Set(try Self.directoryEntryNames(descriptor: directory))
                == Set([Self.audioName, Self.receiptName])
        else { throw IntakeStoreError.corruptRecord }

        let existing = try Self.readReceipt(
            directoryDescriptor: directory,
            expectedMemoID: request.memoID
        )
        guard existing.audioSHA256 == proposedReceipt.audioSHA256,
              existing.acknowledgedRevision == proposedReceipt.acknowledgedRevision,
              existing.capturedAt == proposedReceipt.capturedAt,
              existing.localeHint == proposedReceipt.localeHint
        else { throw IntakeStoreError.identityConflict }
        guard try Self.audioDigest(
            directoryDescriptor: directory,
            expectedByteCount: request.byteCount
        ) == existing.audioSHA256
        else { throw IntakeStoreError.corruptRecord }
        return existing
    }

    private func loadRetainedDuplicate(
        proposedReceipt: BridgeReceipt,
        retainedRootDescriptor: Int32
    ) throws -> BridgeReceipt {
        let destinationName = request.memoID.rawValue
        let directory = destinationName.withCString {
            openat(
                retainedRootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard directory >= 0 else { throw IntakeStoreError.corruptRecord }
        defer { Darwin.close(directory) }

        var directoryMetadata = stat()
        guard fstat(directory, &directoryMetadata) == 0,
              IntakeFileSecurity.isPrivateDirectory(directoryMetadata),
              let namedDirectory = Self.entryMetadata(
                  destinationName,
                  directoryDescriptor: retainedRootDescriptor
              ),
              IntakeFileSecurity.isPrivateDirectory(namedDirectory),
              IntakeFileIdentity(namedDirectory) == IntakeFileIdentity(directoryMetadata),
              Set(try Self.directoryEntryNames(descriptor: directory))
                == Set([Self.audioName, Self.receiptName, Self.retentionManifestName])
        else { throw IntakeStoreError.corruptRecord }

        let existing = try Self.readReceipt(
            directoryDescriptor: directory,
            expectedMemoID: request.memoID
        )
        guard existing.audioSHA256 == proposedReceipt.audioSHA256,
              existing.acknowledgedRevision == proposedReceipt.acknowledgedRevision,
              existing.capturedAt == proposedReceipt.capturedAt,
              existing.localeHint == proposedReceipt.localeHint
        else { throw IntakeStoreError.identityConflict }
        let manifest = try Self.readRetentionManifest(
            directoryDescriptor: directory,
            expectedMemoID: request.memoID
        )
        guard manifest.audioSHA256 == existing.audioSHA256,
              try Self.audioDigest(
                  directoryDescriptor: directory,
                  expectedByteCount: request.byteCount
              ) == existing.audioSHA256
        else { throw IntakeStoreError.corruptRecord }
        return existing
    }

    private func terminate(with error: IntakeStoreError) -> IntakeStoreError {
        guard active else { return error }
        try? withLockedRoot {
            try cleanupTemporary()
        }
        active = false
        closeDescriptors()
        return error
    }

    private func cleanupTemporary() throws {
        try mutationHook(
            .beforeOwnedCleanup,
            rootURL.appendingPathComponent(temporaryName, isDirectory: true)
        )
        try Self.cleanupTemporary(
            rootDescriptor: rootDescriptor,
            rootURL: rootURL,
            temporaryName: temporaryName,
            temporaryIdentity: temporaryIdentity,
            fileIdentities: Self.fileIdentities(
                audioIdentity: audioIdentity,
                receiptIdentity: receiptIdentity
            ),
            mutationHook: mutationHook,
            rootSyncOperation: rootSyncOperation
        )
    }

    private static func cleanupTemporary(
        rootDescriptor: Int32,
        rootURL: URL,
        temporaryName: String,
        temporaryIdentity: IntakeFileIdentity,
        fileIdentities: [String: IntakeFileIdentity]?,
        mutationHook: StreamingIntakeMutationHook,
        rootSyncOperation: StreamingIntakeRootSyncOperation
    ) throws {
        guard rootDescriptor >= 0 else { throw IntakeStoreError.fileSystemFailure }
        let quarantineName = cleanupPrefix + UUID().uuidString.lowercased()
        let renameResult = temporaryName.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else { throw IntakeStoreError.fileSystemFailure }
        guard rootSyncOperation(rootDescriptor) == 0 else {
            try restoreQuarantine(
                quarantineName,
                originalName: temporaryName,
                rootDescriptor: rootDescriptor,
                rootSyncOperation: rootSyncOperation
            )
            throw IntakeStoreError.fileSystemFailure
        }
        try mutationHook(
            .afterQuarantineRename,
            rootURL.appendingPathComponent(quarantineName, isDirectory: true)
        )

        guard let quarantinedMetadata = entryMetadata(
            quarantineName,
            directoryDescriptor: rootDescriptor
        ), IntakeFileIdentity(quarantinedMetadata) == temporaryIdentity
        else {
            try restoreQuarantine(
                quarantineName,
                originalName: temporaryName,
                rootDescriptor: rootDescriptor,
                rootSyncOperation: rootSyncOperation
            )
            throw IntakeStoreError.fileSystemFailure
        }
        guard IntakeFileSecurity.isPrivateDirectory(quarantinedMetadata) else {
            throw IntakeStoreError.fileSystemFailure
        }

        let directory = quarantineName.withCString {
            openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directory >= 0 else { throw IntakeStoreError.fileSystemFailure }
        defer { Darwin.close(directory) }
        var openedMetadata = stat()
        guard fstat(directory, &openedMetadata) == 0,
              IntakeFileSecurity.isPrivateDirectory(openedMetadata),
              IntakeFileIdentity(openedMetadata) == temporaryIdentity
        else { throw IntakeStoreError.fileSystemFailure }
        let entryNames = try directoryEntryNames(descriptor: directory)
        let verifiedFileIdentities: [String: IntakeFileIdentity]
        if let fileIdentities {
            guard Set(fileIdentities.keys).isSubset(of: [audioName, receiptName]),
                  Set(entryNames) == Set(fileIdentities.keys)
            else { throw IntakeStoreError.fileSystemFailure }
            verifiedFileIdentities = fileIdentities
        } else {
            guard Set(entryNames).isSubset(of: [audioName, receiptName]) else {
                throw IntakeStoreError.fileSystemFailure
            }
            var discovered: [String: IntakeFileIdentity] = [:]
            for name in entryNames {
                guard let identity = privateFileIdentity(
                    name,
                    directoryDescriptor: directory
                ) else { throw IntakeStoreError.fileSystemFailure }
                discovered[name] = identity
            }
            verifiedFileIdentities = discovered
        }
        for (name, identity) in verifiedFileIdentities {
            guard privateFileIdentity(name, directoryDescriptor: directory) == identity else {
                throw IntakeStoreError.fileSystemFailure
            }
        }
        for name in verifiedFileIdentities.keys {
            guard name.withCString({ unlinkat(directory, $0, 0) }) == 0 else {
                throw IntakeStoreError.fileSystemFailure
            }
        }
        try mutationHook(
            .beforeFinalDirectoryRemoval,
            rootURL.appendingPathComponent(quarantineName, isDirectory: true)
        )
        var finalOpenedMetadata = stat()
        guard fstat(directory, &finalOpenedMetadata) == 0,
              IntakeFileSecurity.isPrivateDirectory(finalOpenedMetadata),
              IntakeFileIdentity(finalOpenedMetadata) == temporaryIdentity,
              let finalNamedMetadata = entryMetadata(
                  quarantineName,
                  directoryDescriptor: rootDescriptor
              ),
              IntakeFileSecurity.isPrivateDirectory(finalNamedMetadata),
              IntakeFileIdentity(finalNamedMetadata) == IntakeFileIdentity(finalOpenedMetadata)
        else { throw IntakeStoreError.fileSystemFailure }
        guard quarantineName.withCString({ unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }) == 0,
              rootSyncOperation(rootDescriptor) == 0
        else { throw IntakeStoreError.fileSystemFailure }
    }

    private static func restoreQuarantine(
        _ quarantineName: String,
        originalName: String,
        rootDescriptor: Int32,
        rootSyncOperation: StreamingIntakeRootSyncOperation
    ) throws {
        let result = quarantineName.withCString { source in
            originalName.withCString { destination in
                renameatx_np(
                    rootDescriptor,
                    source,
                    rootDescriptor,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0,
              rootSyncOperation(rootDescriptor) == 0
        else { throw IntakeStoreError.fileSystemFailure }
    }

    private static func fileIdentities(
        audioIdentity: IntakeFileIdentity,
        receiptIdentity: IntakeFileIdentity?
    ) -> [String: IntakeFileIdentity] {
        var result = [audioName: audioIdentity]
        if let receiptIdentity { result[receiptName] = receiptIdentity }
        return result
    }

    private func closeDescriptors() {
        if audioDescriptor >= 0 {
            Darwin.close(audioDescriptor)
            audioDescriptor = -1
        }
        if temporaryDescriptor >= 0 {
            Darwin.close(temporaryDescriptor)
            temporaryDescriptor = -1
        }
        if rootDescriptor >= 0 {
            Darwin.close(rootDescriptor)
            rootDescriptor = -1
        }
    }

    private static func openTemporary(
        rootURL: URL,
        rootIdentity: IntakeFileIdentity,
        memoID: MemoID,
        mutationHook: StreamingIntakeMutationHook,
        rootSyncOperation: StreamingIntakeRootSyncOperation
    ) throws -> OpenedTemporary {
        let root = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard root >= 0 else { throw IntakeStoreError.invalidRoot }
        do {
            try verifyRoot(root, rootURL: rootURL, rootIdentity: rootIdentity)
            guard flock(root, LOCK_EX) == 0 else {
                throw IntakeStoreError.fileSystemFailure
            }
            try verifyRoot(root, rootURL: rootURL, rootIdentity: rootIdentity)
        } catch {
            Darwin.close(root)
            throw (error as? IntakeStoreError) ?? IntakeStoreError.fileSystemFailure
        }
        var transfersRootDescriptor = false
        defer {
            _ = flock(root, LOCK_UN)
            if !transfersRootDescriptor { Darwin.close(root) }
        }
        var directory: Int32 = -1
        var audio: Int32 = -1
        let name = temporaryPrefix
            + memoID.rawValue
            + "--"
            + UUID().uuidString.lowercased()
        let temporaryURL = rootURL.appendingPathComponent(name, isDirectory: true)
        var directoryIdentity: IntakeFileIdentity?
        var audioIdentity: IntakeFileIdentity?
        do {
            guard name.withCString({ mkdirat(root, $0, 0o700) }) == 0 else {
                throw IntakeStoreError.fileSystemFailure
            }
            directory = name.withCString {
                openat(root, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard directory >= 0 else { throw IntakeStoreError.fileSystemFailure }
            var directoryMetadata = stat()
            guard fchmod(directory, 0o700) == 0,
                  fstat(directory, &directoryMetadata) == 0,
                  IntakeFileSecurity.isPrivateDirectory(directoryMetadata),
                  let attachedDirectory = entryMetadata(name, directoryDescriptor: root),
                  IntakeFileIdentity(attachedDirectory) == IntakeFileIdentity(directoryMetadata),
                  flock(directory, LOCK_EX | LOCK_NB) == 0
            else { throw IntakeStoreError.fileSystemFailure }
            directoryIdentity = IntakeFileIdentity(directoryMetadata)

            audio = audioName.withCString {
                openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    0o600
                )
            }
            guard audio >= 0 else { throw IntakeStoreError.fileSystemFailure }
            var audioMetadata = stat()
            guard fchmod(audio, 0o600) == 0,
                  fstat(audio, &audioMetadata) == 0,
                  IntakeFileSecurity.isPrivateRegularFile(audioMetadata),
                  privateFileIdentity(audioName, directoryDescriptor: directory)
                    == IntakeFileIdentity(audioMetadata)
            else { throw IntakeStoreError.fileSystemFailure }
            audioIdentity = IntakeFileIdentity(audioMetadata)
            try mutationHook(.afterAudioCreation, temporaryURL)
            transfersRootDescriptor = true
            return OpenedTemporary(
                rootDescriptor: root,
                directoryDescriptor: directory,
                audioDescriptor: audio,
                name: name,
                directoryIdentity: IntakeFileIdentity(directoryMetadata),
                audioIdentity: IntakeFileIdentity(audioMetadata)
            )
        } catch {
            try? mutationHook(.beforeInitializationCleanup, temporaryURL)
            if let directoryIdentity {
                var identities: [String: IntakeFileIdentity] = [:]
                if let audioIdentity { identities[audioName] = audioIdentity }
                try? cleanupTemporary(
                    rootDescriptor: root,
                    rootURL: rootURL,
                    temporaryName: name,
                    temporaryIdentity: directoryIdentity,
                    fileIdentities: identities,
                    mutationHook: mutationHook,
                    rootSyncOperation: rootSyncOperation
                )
            }
            if audio >= 0 { Darwin.close(audio) }
            if directory >= 0 { Darwin.close(directory) }
            throw (error as? IntakeStoreError) ?? IntakeStoreError.fileSystemFailure
        }
    }

    private static func verifyRoot(
        _ descriptor: Int32,
        rootURL: URL,
        rootIdentity: IntakeFileIdentity
    ) throws {
        var opened = stat()
        var named = stat()
        guard descriptor >= 0,
              fstat(descriptor, &opened) == 0,
              lstat(rootURL.path, &named) == 0,
              IntakeFileSecurity.isPrivateDirectory(opened),
              IntakeFileSecurity.isPrivateDirectory(named),
              IntakeFileIdentity(opened) == rootIdentity,
              IntakeFileIdentity(named) == rootIdentity
        else { throw IntakeStoreError.invalidRoot }
    }

    private static func readReceipt(
        directoryDescriptor: Int32,
        expectedMemoID: MemoID
    ) throws -> BridgeReceipt {
        let descriptor = receiptName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw IntakeStoreError.corruptRecord }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              IntakeFileSecurity.isPrivateRegularFile(metadata),
              metadata.st_size > 0,
              metadata.st_size <= maximumReceiptBytes,
              privateFileIdentity(receiptName, directoryDescriptor: directoryDescriptor)
                == IntakeFileIdentity(metadata)
        else { throw IntakeStoreError.corruptRecord }
        let data = try readExactly(Int(metadata.st_size), descriptor: descriptor)
        do {
            let receipt = try JSONDecoder().decode(BridgeReceipt.self, from: data)
            guard receipt.memoID == expectedMemoID else { throw IntakeStoreError.corruptRecord }
            return receipt
        } catch let error as IntakeStoreError {
            throw error
        } catch {
            throw IntakeStoreError.corruptRecord
        }
    }

    private static func readRetentionManifest(
        directoryDescriptor: Int32,
        expectedMemoID: MemoID
    ) throws -> RetentionManifest {
        let descriptor = retentionManifestName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw IntakeStoreError.corruptRecord }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              IntakeFileSecurity.isPrivateRegularFile(metadata),
              metadata.st_size > 0,
              metadata.st_size <= maximumRetentionManifestBytes,
              privateFileIdentity(
                  retentionManifestName,
                  directoryDescriptor: directoryDescriptor
              ) == IntakeFileIdentity(metadata)
        else { throw IntakeStoreError.corruptRecord }
        let data = try readExactly(Int(metadata.st_size), descriptor: descriptor)
        do {
            let manifest = try JSONDecoder().decode(RetentionManifest.self, from: data)
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

    private static func audioDigest(
        directoryDescriptor: Int32,
        expectedByteCount: Int
    ) throws -> String {
        let descriptor = audioName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw IntakeStoreError.corruptRecord }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              IntakeFileSecurity.isPrivateRegularFile(metadata),
              metadata.st_size == expectedByteCount,
              privateFileIdentity(audioName, directoryDescriptor: directoryDescriptor)
                == IntakeFileIdentity(metadata)
        else { throw IntakeStoreError.corruptRecord }

        var digest = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                total += count
                digest.update(data: Data(buffer.prefix(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw IntakeStoreError.corruptRecord
            }
        }
        guard total == expectedByteCount else { throw IntakeStoreError.corruptRecord }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readExactly(_ count: Int, descriptor: Int32) throws -> Data {
        var data = Data(count: count)
        let bytesRead = data.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return -1
                }
            }
            return offset
        }
        guard bytesRead == count else { throw IntakeStoreError.corruptRecord }
        return data
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        operation: StreamingIntakeWriteOperation
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = operation(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw IntakeStoreError.fileSystemFailure
                }
            }
        }
    }

    private static func privateFileIdentity(
        _ name: String,
        directoryDescriptor: Int32
    ) -> IntakeFileIdentity? {
        guard let metadata = entryMetadata(name, directoryDescriptor: directoryDescriptor),
              IntakeFileSecurity.isPrivateRegularFile(metadata)
        else { return nil }
        return IntakeFileIdentity(metadata)
    }

    private static func entryMetadata(
        _ name: String,
        directoryDescriptor: Int32
    ) -> stat? {
        guard directoryDescriptor >= 0 else { return nil }
        var metadata = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 ? metadata : nil
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

    private static func isOwnedTemporaryName(_ name: String) -> Bool {
        if isIncomingTemporaryName(name) { return true }
        if name.hasPrefix(cleanupPrefix) {
            return UUID(uuidString: String(name.dropFirst(cleanupPrefix.count))) != nil
        }
        return false
    }

    private static func isIncomingTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix) else { return false }
        let suffix = String(name.dropFirst(temporaryPrefix.count))
        return UUID(uuidString: suffix) != nil
            || inFlightMemoID(forTemporaryName: name) != nil
    }

    static func inFlightMemoID(forTemporaryName name: String) -> MemoID? {
        guard name.hasPrefix(temporaryPrefix) else { return nil }
        let suffix = String(name.dropFirst(temporaryPrefix.count))
        guard let separator = suffix.range(of: "--") else { return nil }
        let memoText = String(suffix[..<separator.lowerBound])
        let nonceText = String(suffix[separator.upperBound...])
        guard !memoText.isEmpty,
              !nonceText.isEmpty,
              nonceText.range(of: "--") == nil,
              let memoID = try? MemoID(memoText),
              memoText == memoID.rawValue,
              let nonce = UUID(uuidString: nonceText),
              nonceText == nonce.uuidString.lowercased()
        else { return nil }
        return memoID
    }
}

private enum PublishOutcome {
    case created
    case duplicate(BridgeReceipt)
}

private struct OpenedTemporary {
    let rootDescriptor: Int32
    let directoryDescriptor: Int32
    let audioDescriptor: Int32
    let name: String
    let directoryIdentity: IntakeFileIdentity
    let audioIdentity: IntakeFileIdentity
}
