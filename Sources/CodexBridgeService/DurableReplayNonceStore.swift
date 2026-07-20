import CodexBridgeShared
import Darwin
import Foundation

public enum DurableReplayNonceStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidLedger
    case invalidEntry
    case capacityExceeded
    case fileSystemFailure
}

enum ReplayLedgerMutationBoundary: Equatable, Sendable {
    case afterOpenBeforeMutation
    case beforeTemporaryCreation
    case beforeRename
}

public actor DurableReplayNonceStore: ReplayNonceStore {
    private static let ledgerName = "replay-nonces.json"
    // A valid 128-byte nonce can consist entirely of JSON-escaped bytes such as
    // backslashes: 2 delimiters + (128 * 2) escaped bytes = 258 bytes. The
    // remaining 254 bytes cover both finite Date literals, entry keys, braces,
    // and the entry separator; the fixed ledger envelope is budgeted separately.
    private static let maximumEncodedEntryAndSeparatorBytes = 512
    private static let maximumLedgerEnvelopeBytes = 64
    private static let maximumCapacity = 65_536

    private let parentURL: URL
    private let parentIdentity: ReplayLedgerFileIdentity
    private let rootName: String
    private let rootIdentity: ReplayLedgerFileIdentity
    private let capacity: Int
    private let maximumLedgerBytes: Int
    private let faultInjector: @Sendable (ReplayLedgerMutationBoundary) throws -> Void

    public init(rootURL: URL, capacity: Int = 65_536) throws {
        try self.init(rootURL: rootURL, capacity: capacity, faultInjector: { _ in })
    }

    init(
        rootURL: URL,
        capacity: Int = 65_536,
        faultInjector: @escaping @Sendable (ReplayLedgerMutationBoundary) throws -> Void
    ) throws {
        guard capacity > 0, capacity <= Self.maximumCapacity else {
            throw DurableReplayNonceStoreError.capacityExceeded
        }
        let (entryBytes, entryBytesOverflow) = capacity.multipliedReportingOverflow(
            by: Self.maximumEncodedEntryAndSeparatorBytes
        )
        let (ledgerBytes, ledgerBytesOverflow) = entryBytes.addingReportingOverflow(
            Self.maximumLedgerEnvelopeBytes
        )
        guard !entryBytesOverflow, !ledgerBytesOverflow else {
            throw DurableReplayNonceStoreError.capacityExceeded
        }
        let rootURL = rootURL.standardizedFileURL
        let parentURL = rootURL.deletingLastPathComponent()
        let rootName = rootURL.lastPathComponent
        guard !rootName.isEmpty, rootName != "/" else {
            throw DurableReplayNonceStoreError.invalidRoot
        }
        let maximumLedgerBytes = max(4 * 1_024, ledgerBytes)
        let parentIdentity = try Self.prepareParent(parentURL)
        let rootIdentity = try Self.prepareRoot(rootURL, maximumBytes: maximumLedgerBytes)
        try Self.verifyRootAttachment(
            parentURL: parentURL,
            parentIdentity: parentIdentity,
            rootName: rootName,
            rootIdentity: rootIdentity
        )
        self.parentURL = parentURL
        self.parentIdentity = parentIdentity
        self.rootName = rootName
        self.rootIdentity = rootIdentity
        self.capacity = capacity
        self.maximumLedgerBytes = maximumLedgerBytes
        self.faultInjector = faultInjector
    }

    public func consume(_ nonce: String, acceptedAt: Date, expiresAt: Date) throws -> Bool {
        try Self.validate(nonce: nonce, acceptedAt: acceptedAt, expiresAt: expiresAt)
        return try withLockedDirectory { root in
            var entries = try Self.readLedger(descriptor: root.descriptor, maximumBytes: maximumLedgerBytes)
            guard !entries.contains(where: { $0.nonce == nonce }) else { return false }
            entries.removeAll { $0.expiresAt <= acceptedAt }
            guard entries.count < capacity else { throw DurableReplayNonceStoreError.capacityExceeded }
            entries.append(ReplayLedgerEntry(nonce: nonce, acceptedAt: acceptedAt, expiresAt: expiresAt))
            try Self.writeLedger(
                entries,
                descriptor: root.descriptor,
                maximumBytes: maximumLedgerBytes,
                faultInjector: faultInjector,
                verifyRootAttachment: root.verifyAttachment
            )
            return true
        }
    }

    public func prune(now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw DurableReplayNonceStoreError.invalidEntry
        }
        try withLockedDirectory { root in
            let existing = try Self.readLedger(descriptor: root.descriptor, maximumBytes: maximumLedgerBytes)
            let retained = existing.filter { $0.expiresAt > now }
            guard retained.count != existing.count else { return }
            try Self.writeLedger(
                retained,
                descriptor: root.descriptor,
                maximumBytes: maximumLedgerBytes,
                faultInjector: faultInjector,
                verifyRootAttachment: root.verifyAttachment
            )
        }
    }

    private func withLockedDirectory<T>(_ body: (LockedReplayLedgerRoot) throws -> T) throws -> T {
        let parentDescriptor = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { Darwin.close(parentDescriptor) }
        var parentMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              Self.isOwnedDirectory(parentMetadata),
              ReplayLedgerFileIdentity(parentMetadata) == parentIdentity
        else { throw DurableReplayNonceStoreError.invalidRoot }
        let descriptor = rootName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        let root = LockedReplayLedgerRoot(
            parentDescriptor: parentDescriptor,
            descriptor: descriptor,
            parentIdentity: parentIdentity,
            rootName: rootName,
            rootIdentity: rootIdentity
        )
        try root.verifyAttachment()
        guard flock(descriptor, LOCK_EX) == 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { _ = flock(descriptor, LOCK_UN) }
        do {
            try faultInjector(.afterOpenBeforeMutation)
        } catch {
            throw DurableReplayNonceStoreError.fileSystemFailure
        }
        try root.verifyAttachment()
        return try body(root)
    }

    private static func prepareParent(_ parentURL: URL) throws -> ReplayLedgerFileIdentity {
        guard parentURL.isFileURL else { throw DurableReplayNonceStoreError.invalidRoot }
        let descriptor = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, isOwnedDirectory(metadata) else {
            throw DurableReplayNonceStoreError.invalidRoot
        }
        return ReplayLedgerFileIdentity(metadata)
    }

    private static func prepareRoot(_ rootURL: URL, maximumBytes: Int) throws -> ReplayLedgerFileIdentity {
        guard rootURL.isFileURL else { throw DurableReplayNonceStoreError.invalidRoot }
        do {
            let created = mkdir(rootURL.path, 0o700) == 0
            if !created, errno != EEXIST {
                throw DurableReplayNonceStoreError.invalidRoot
            }
            let descriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(),
                  fchmod(descriptor, 0o700) == 0,
                  fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & 0o7777 == 0o700,
                  fsync(descriptor) == 0
            else { throw DurableReplayNonceStoreError.invalidRoot }
            if created {
                try writeLedger(
                    [],
                    descriptor: descriptor,
                    maximumBytes: maximumBytes,
                    faultInjector: { _ in },
                    verifyRootAttachment: {}
                )
            } else {
                _ = try readLedger(descriptor: descriptor, maximumBytes: maximumBytes)
            }
            return ReplayLedgerFileIdentity(metadata)
        } catch let error as DurableReplayNonceStoreError {
            throw error
        } catch {
            throw DurableReplayNonceStoreError.invalidRoot
        }
    }

    private static func validate(nonce: String, acceptedAt: Date, expiresAt: Date) throws {
        guard !nonce.isEmpty,
              nonce.utf8.count <= 128,
              nonce.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
              acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt > acceptedAt
        else { throw DurableReplayNonceStoreError.invalidEntry }
    }

    private static func readLedger(descriptor: Int32, maximumBytes: Int) throws -> [ReplayLedgerEntry] {
        let file = ledgerName.withCString { openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard file >= 0 else {
            if errno == ENOENT { throw DurableReplayNonceStoreError.invalidLedger }
            throw DurableReplayNonceStoreError.fileSystemFailure
        }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              isPrivateLedgerFile(metadata),
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes,
              let identity = entryIdentity(ledgerName, directoryDescriptor: descriptor),
              identity == ReplayLedgerFileIdentity(metadata)
        else { throw DurableReplayNonceStoreError.invalidLedger }
        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(file, base.advanced(by: offset), buffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return -1
                }
            }
            return offset
        }
        guard bytesRead == data.count else { throw DurableReplayNonceStoreError.fileSystemFailure }
        do {
            let ledger = try JSONDecoder().decode(ReplayLedger.self, from: data)
            guard ledger.version == 1,
                  ledger.entries == ledger.entries.sorted(by: ReplayLedgerEntry.sort),
                  Set(ledger.entries.map(\.nonce)).count == ledger.entries.count
            else { throw DurableReplayNonceStoreError.invalidLedger }
            for entry in ledger.entries {
                try validate(nonce: entry.nonce, acceptedAt: entry.acceptedAt, expiresAt: entry.expiresAt)
            }
            return ledger.entries
        } catch let error as DurableReplayNonceStoreError {
            throw error
        } catch {
            throw DurableReplayNonceStoreError.invalidLedger
        }
    }

    private static func writeLedger(
        _ entries: [ReplayLedgerEntry],
        descriptor: Int32,
        maximumBytes: Int,
        faultInjector: @escaping @Sendable (ReplayLedgerMutationBoundary) throws -> Void,
        verifyRootAttachment: () throws -> Void
    ) throws {
        let temporaryName = ".replay-nonces-\(UUID().uuidString.lowercased())"
        var createdTemporary = false
        var temporaryIdentity: ReplayLedgerFileIdentity?
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(ReplayLedger(version: 1, entries: entries.sorted(by: ReplayLedgerEntry.sort)))
            guard !encoded.isEmpty, encoded.count <= maximumBytes else {
                throw DurableReplayNonceStoreError.capacityExceeded
            }
            try verifyRootAttachment()
            try faultInjector(.beforeTemporaryCreation)
            try verifyRootAttachment()
            let file = temporaryName.withCString {
                openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard file >= 0 else { throw DurableReplayNonceStoreError.fileSystemFailure }
            createdTemporary = true
            do {
                var metadata = stat()
                guard fstat(file, &metadata) == 0,
                      isPrivateLedgerFile(metadata),
                      fchmod(file, 0o600) == 0,
                      fstat(file, &metadata) == 0,
                      isPrivateLedgerFile(metadata)
                else { throw DurableReplayNonceStoreError.fileSystemFailure }
                temporaryIdentity = ReplayLedgerFileIdentity(metadata)
                try writeAll(encoded, descriptor: file)
                guard fsync(file) == 0 else { throw DurableReplayNonceStoreError.fileSystemFailure }
            } catch {
                Darwin.close(file)
                throw error
            }
            Darwin.close(file)
            guard let temporaryIdentity,
                  entryIdentity(temporaryName, directoryDescriptor: descriptor) == temporaryIdentity
            else { throw DurableReplayNonceStoreError.fileSystemFailure }
            try verifyRootAttachment()
            try faultInjector(.beforeRename)
            try verifyRootAttachment()
            guard temporaryName.withCString({ source in
                ledgerName.withCString { destination in
                    renameat(descriptor, source, descriptor, destination)
                }
            }) == 0 else { throw DurableReplayNonceStoreError.fileSystemFailure }
            createdTemporary = false
            guard entryIdentity(ledgerName, directoryDescriptor: descriptor) == temporaryIdentity,
                  fsync(descriptor) == 0
            else { throw DurableReplayNonceStoreError.fileSystemFailure }
            try verifyRootAttachment()
        } catch let error as DurableReplayNonceStoreError {
            if createdTemporary {
                unlinkIfIdentityMatches(temporaryName, identity: temporaryIdentity, directoryDescriptor: descriptor)
            }
            throw error
        } catch {
            if createdTemporary {
                unlinkIfIdentityMatches(temporaryName, identity: temporaryIdentity, directoryDescriptor: descriptor)
            }
            throw DurableReplayNonceStoreError.fileSystemFailure
        }
    }

    private static func isPrivateLedgerFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600
    }

    private static func isOwnedDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR && metadata.st_uid == getuid()
    }

    private static func verifyRootAttachment(
        parentURL: URL,
        parentIdentity: ReplayLedgerFileIdentity,
        rootName: String,
        rootIdentity: ReplayLedgerFileIdentity
    ) throws {
        let parentDescriptor = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { Darwin.close(parentDescriptor) }
        let descriptor = rootName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw DurableReplayNonceStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        let root = LockedReplayLedgerRoot(
            parentDescriptor: parentDescriptor,
            descriptor: descriptor,
            parentIdentity: parentIdentity,
            rootName: rootName,
            rootIdentity: rootIdentity
        )
        try root.verifyAttachment()
    }

    private static func entryIdentity(_ name: String, directoryDescriptor: Int32) -> ReplayLedgerFileIdentity? {
        var metadata = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, isPrivateLedgerFile(metadata) else { return nil }
        return ReplayLedgerFileIdentity(metadata)
    }

    private static func unlinkIfIdentityMatches(
        _ name: String,
        identity: ReplayLedgerFileIdentity?,
        directoryDescriptor: Int32
    ) {
        guard let identity,
              entryIdentity(name, directoryDescriptor: directoryDescriptor) == identity
        else { return }
        _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw DurableReplayNonceStoreError.fileSystemFailure
                }
            }
        }
    }
}

private struct LockedReplayLedgerRoot {
    let parentDescriptor: Int32
    let descriptor: Int32
    let parentIdentity: ReplayLedgerFileIdentity
    let rootName: String
    let rootIdentity: ReplayLedgerFileIdentity

    func verifyAttachment() throws {
        var parentMetadata = stat()
        var rootMetadata = stat()
        var namedRootMetadata = stat()
        guard fstat(parentDescriptor, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == getuid(),
              ReplayLedgerFileIdentity(parentMetadata) == parentIdentity,
              fstat(descriptor, &rootMetadata) == 0,
              rootMetadata.st_mode & S_IFMT == S_IFDIR,
              rootMetadata.st_uid == getuid(),
              rootMetadata.st_mode & 0o7777 == 0o700,
              ReplayLedgerFileIdentity(rootMetadata) == rootIdentity,
              rootName.withCString({
                  fstatat(parentDescriptor, $0, &namedRootMetadata, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              namedRootMetadata.st_mode & S_IFMT == S_IFDIR,
              namedRootMetadata.st_uid == getuid(),
              namedRootMetadata.st_mode & 0o7777 == 0o700,
              ReplayLedgerFileIdentity(namedRootMetadata) == rootIdentity
        else { throw DurableReplayNonceStoreError.invalidRoot }
    }
}

private struct ReplayLedger: Codable {
    let version: Int
    let entries: [ReplayLedgerEntry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case entries
    }

    init(version: Int, entries: [ReplayLedgerEntry]) {
        self.version = version
        self.entries = entries
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: ReplayLedgerCodingKey.self)
        let expected = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(raw.allKeys.map(\.stringValue)) == expected, raw.allKeys.count == expected.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unexpected replay ledger keys"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        entries = try values.decode([ReplayLedgerEntry].self, forKey: .entries)
    }
}

private struct ReplayLedgerEntry: Codable, Equatable {
    let nonce: String
    let acceptedAt: Date
    let expiresAt: Date

    static func sort(_ lhs: ReplayLedgerEntry, _ rhs: ReplayLedgerEntry) -> Bool {
        if lhs.nonce != rhs.nonce { return lhs.nonce < rhs.nonce }
        return lhs.acceptedAt < rhs.acceptedAt
    }
}

private struct ReplayLedgerCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct ReplayLedgerFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}
