import CodexBridgeShared
import Darwin
import Foundation

public struct FinalDeliveryReceipt: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let stateRevision: UInt64
    public let deliveredAt: Date

    public init(
        memoID: MemoID,
        audioSHA256: String,
        stateRevision: UInt64,
        deliveredAt: Date
    ) throws {
        guard SHA256Hex.isValid(audioSHA256),
              stateRevision > 0,
              deliveredAt.timeIntervalSinceReferenceDate.isFinite
        else { throw FinalDeliveryStatusStoreError.invalidReceipt }
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.stateRevision = stateRevision
        self.deliveredAt = deliveredAt
        _ = try bridgeMemoStatus
    }

    public var bridgeMemoStatus: BridgeMemoStatus {
        get throws {
            try BridgeMemoStatus(
                memoID: memoID,
                audioSHA256: audioSHA256,
                state: .delivered,
                stateRevision: stateRevision,
                updatedAt: deliveredAt
            )
        }
    }

    public init(from decoder: any Decoder) throws {
        let rawValues = try decoder.container(keyedBy: FinalDeliveryReceiptCodingKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(rawValues.allKeys.map(\.stringValue)) == expectedKeys,
              rawValues.allKeys.count == expectedKeys.count
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unexpected final delivery receipt keys")
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                memoID: values.decode(MemoID.self, forKey: .memoID),
                audioSHA256: values.decode(String.self, forKey: .audioSHA256),
                stateRevision: values.decode(UInt64.self, forKey: .stateRevision),
                deliveredAt: values.decode(Date.self, forKey: .deliveredAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid final delivery receipt")
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case memoID
        case audioSHA256
        case stateRevision
        case deliveredAt
    }
}

private struct FinalDeliveryReceiptCodingKey: CodingKey {
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

public enum FinalDeliveryStatusStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case invalidReceipt
    case identityConflict
    case capacityExceeded
    case fileSystemFailure
}

public struct FinalDeliveryCapacityReservationLease: Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    fileprivate let token: UUID?

    fileprivate init(memoID: MemoID, audioSHA256: String, token: UUID?) {
        self.memoID = memoID
        self.audioSHA256 = audioSHA256
        self.token = token
    }
}

private struct FinalDeliveryCapacityReservation: Codable, Equatable, Sendable {
    let memoID: MemoID
    let audioSHA256: String
    let committed: Bool
    let leaseTokens: [UUID]

    init(memoID: MemoID, audioSHA256: String, committed: Bool, leaseTokens: [UUID]) throws {
        guard SHA256Hex.isValid(audioSHA256) else {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.committed = committed
        self.leaseTokens = leaseTokens.sorted { $0.uuidString < $1.uuidString }
    }

    init(from decoder: any Decoder) throws {
        let rawValues = try decoder.container(keyedBy: FinalDeliveryReceiptCodingKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.stringValue))
        guard Set(rawValues.allKeys.map(\.stringValue)) == expectedKeys,
              rawValues.allKeys.count == expectedKeys.count
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unexpected capacity reservation keys")
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                memoID: values.decode(MemoID.self, forKey: .memoID),
                audioSHA256: values.decode(String.self, forKey: .audioSHA256),
                committed: values.decode(Bool.self, forKey: .committed),
                leaseTokens: values.decode([UUID].self, forKey: .leaseTokens)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid capacity reservation")
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case memoID
        case audioSHA256
        case committed
        case leaseTokens
    }
}

enum FinalDeliveryStatusStoreMutationBoundary: Equatable, Sendable {
    case beforeTemporaryCreation
    case beforeRename
}

public actor FinalDeliveryStatusStore {
    private static let maximumReceiptBytes = 4 * 1_024

    private let rootURL: URL
    private let rootIdentity: FinalDeliveryReceiptFileIdentity
    private let capacity: Int
    private let clock: @Sendable () -> Date
    private let faultInjector: @Sendable (FinalDeliveryStatusStoreMutationBoundary) throws -> Void

    public init(
        rootURL: URL,
        capacity: Int = 4_096,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        try self.init(
            rootURL: rootURL,
            capacity: capacity,
            clock: clock,
            faultInjector: { _ in }
        )
    }

    init(
        rootURL: URL,
        capacity: Int = 4_096,
        clock: @escaping @Sendable () -> Date = Date.init,
        faultInjector: @escaping @Sendable (FinalDeliveryStatusStoreMutationBoundary) throws -> Void
    ) throws {
        guard capacity > 0 else { throw FinalDeliveryStatusStoreError.capacityExceeded }
        let rootURL = rootURL.standardizedFileURL
        rootIdentity = try Self.prepareRoot(rootURL)
        self.rootURL = rootURL
        self.capacity = capacity
        self.clock = clock
        self.faultInjector = faultInjector
    }

    public func publish(_ receipt: FinalDeliveryReceipt) throws {
        guard (try? receipt.bridgeMemoStatus) != nil else {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
        _ = clock
        try withLockedDirectory { descriptor in
            if let existing = try Self.readSlot(memoID: receipt.memoID, descriptor: descriptor) {
                switch existing.value {
                case let .receipt(existingReceipt):
                    guard Self.isSameIdentity(existingReceipt, receipt) else {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                    return
                case let .reservation(reservation):
                    guard reservation.memoID == receipt.memoID,
                          reservation.audioSHA256 == receipt.audioSHA256
                    else {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                    try Self.writeDocument(
                        receipt,
                        memoID: receipt.memoID,
                        descriptor: descriptor,
                        replacing: existing.identity,
                        faultInjector: faultInjector
                    )
                    return
                }
            }
            guard try Self.occupiedSlotCount(descriptor: descriptor) < capacity else {
                throw FinalDeliveryStatusStoreError.capacityExceeded
            }
            try Self.writeDocument(
                receipt,
                memoID: receipt.memoID,
                descriptor: descriptor,
                replacing: nil,
                faultInjector: faultInjector
            )
        }
    }

    public func reserveCapacity(
        memoID: MemoID,
        audioSHA256: String
    ) throws -> FinalDeliveryCapacityReservationLease {
        guard SHA256Hex.isValid(audioSHA256) else {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
        let digest = audioSHA256.lowercased()
        return try withLockedDirectory { descriptor in
            if let existing = try Self.readSlot(memoID: memoID, descriptor: descriptor) {
                switch existing.value {
                case let .receipt(receipt):
                    guard receipt.audioSHA256 == digest else {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                    return FinalDeliveryCapacityReservationLease(
                        memoID: memoID,
                        audioSHA256: digest,
                        token: nil
                    )
                case let .reservation(reservation):
                    guard reservation.audioSHA256 == digest else {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                    let token = UUID()
                    let updated = try FinalDeliveryCapacityReservation(
                        memoID: memoID,
                        audioSHA256: digest,
                        committed: reservation.committed,
                        leaseTokens: reservation.leaseTokens + [token]
                    )
                    try Self.writeDocument(
                        updated,
                        memoID: memoID,
                        descriptor: descriptor,
                        replacing: existing.identity,
                        faultInjector: faultInjector
                    )
                    return FinalDeliveryCapacityReservationLease(
                        memoID: memoID,
                        audioSHA256: digest,
                        token: token
                    )
                }
            }
            guard try Self.occupiedSlotCount(descriptor: descriptor) < capacity else {
                throw FinalDeliveryStatusStoreError.capacityExceeded
            }
            let token = UUID()
            let reservation = try FinalDeliveryCapacityReservation(
                memoID: memoID,
                audioSHA256: digest,
                committed: false,
                leaseTokens: [token]
            )
            try Self.writeDocument(
                reservation,
                memoID: memoID,
                descriptor: descriptor,
                replacing: nil,
                faultInjector: faultInjector
            )
            return FinalDeliveryCapacityReservationLease(
                memoID: memoID,
                audioSHA256: digest,
                token: token
            )
        }
    }

    public func commitCapacityReservation(_ lease: FinalDeliveryCapacityReservationLease) throws {
        guard let token = lease.token else { return }
        try withLockedDirectory { descriptor in
            guard let existing = try Self.readSlot(memoID: lease.memoID, descriptor: descriptor) else {
                throw FinalDeliveryStatusStoreError.fileSystemFailure
            }
            switch existing.value {
            case let .receipt(receipt):
                guard receipt.audioSHA256 == lease.audioSHA256 else {
                    throw FinalDeliveryStatusStoreError.identityConflict
                }
                return
            case let .reservation(reservation):
                guard reservation.audioSHA256 == lease.audioSHA256,
                      reservation.leaseTokens.contains(token)
                else { throw FinalDeliveryStatusStoreError.identityConflict }
                let updated = try FinalDeliveryCapacityReservation(
                    memoID: lease.memoID,
                    audioSHA256: lease.audioSHA256,
                    committed: true,
                    leaseTokens: reservation.leaseTokens.filter { $0 != token }
                )
                try Self.writeDocument(
                    updated,
                    memoID: lease.memoID,
                    descriptor: descriptor,
                    replacing: existing.identity,
                    faultInjector: faultInjector
                )
            }
        }
    }

    public func cancelCapacityReservation(_ lease: FinalDeliveryCapacityReservationLease) throws {
        guard let token = lease.token else { return }
        try withLockedDirectory { descriptor in
            guard let existing = try Self.readSlot(memoID: lease.memoID, descriptor: descriptor) else {
                return
            }
            switch existing.value {
            case let .receipt(receipt):
                guard receipt.audioSHA256 == lease.audioSHA256 else {
                    throw FinalDeliveryStatusStoreError.identityConflict
                }
                return
            case let .reservation(reservation):
                guard reservation.audioSHA256 == lease.audioSHA256 else {
                    throw FinalDeliveryStatusStoreError.identityConflict
                }
                guard reservation.leaseTokens.contains(token) else { return }
                let remaining = reservation.leaseTokens.filter { $0 != token }
                if !reservation.committed, remaining.isEmpty {
                    try Self.unlinkSlot(existing, descriptor: descriptor)
                } else {
                    let updated = try FinalDeliveryCapacityReservation(
                        memoID: lease.memoID,
                        audioSHA256: lease.audioSHA256,
                        committed: reservation.committed,
                        leaseTokens: remaining
                    )
                    try Self.writeDocument(
                        updated,
                        memoID: lease.memoID,
                        descriptor: descriptor,
                        replacing: existing.identity,
                        faultInjector: faultInjector
                    )
                }
            }
        }
    }

    /// Startup-only reconciliation. Call before accepting uploads. Durable
    /// intake is authoritative: legacy accepted records receive committed slots
    /// even when that temporarily takes occupancy above the configured cap.
    public func reconcileCapacityReservations(with committedIntake: [MemoID: String]) throws {
        guard committedIntake.values.allSatisfy(SHA256Hex.isValid) else {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
        try withLockedDirectory { descriptor in
            try Self.recoverInterruptedWrites(descriptor: descriptor)
            var remaining = committedIntake.mapValues { $0.lowercased() }
            for slot in try Self.allSlots(descriptor: descriptor) {
                switch slot.value {
                case let .receipt(receipt):
                    if let digest = remaining.removeValue(forKey: receipt.memoID),
                       digest != receipt.audioSHA256
                    {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                case let .reservation(reservation):
                    guard let digest = remaining.removeValue(forKey: reservation.memoID) else {
                        try Self.unlinkSlot(slot, descriptor: descriptor)
                        continue
                    }
                    guard digest == reservation.audioSHA256 else {
                        throw FinalDeliveryStatusStoreError.identityConflict
                    }
                    let reconciled = try FinalDeliveryCapacityReservation(
                        memoID: reservation.memoID,
                        audioSHA256: reservation.audioSHA256,
                        committed: true,
                        leaseTokens: []
                    )
                    if reconciled != reservation {
                        try Self.writeDocument(
                            reconciled,
                            memoID: reservation.memoID,
                            descriptor: descriptor,
                            replacing: slot.identity,
                            faultInjector: faultInjector
                        )
                    }
                }
            }
            for (memoID, digest) in remaining.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let reservation = try FinalDeliveryCapacityReservation(
                    memoID: memoID,
                    audioSHA256: digest,
                    committed: true,
                    leaseTokens: []
                )
                try Self.writeDocument(
                    reservation,
                    memoID: memoID,
                    descriptor: descriptor,
                    replacing: nil,
                    faultInjector: faultInjector
                )
            }
        }
    }

    public func receipt(for memoID: MemoID) throws -> FinalDeliveryReceipt? {
        try withLockedDirectory { descriptor in
            guard let slot = try Self.readSlot(memoID: memoID, descriptor: descriptor) else { return nil }
            guard case let .receipt(receipt) = slot.value else { return nil }
            return receipt
        }
    }

    public func acknowledge(
        memoID: MemoID,
        audioSHA256: String,
        stateRevision: UInt64
    ) throws -> Bool {
        guard SHA256Hex.isValid(audioSHA256), stateRevision > 0 else { return false }
        return try withLockedDirectory { descriptor in
            guard let stored = try Self.readSlot(memoID: memoID, descriptor: descriptor) else {
                return true
            }
            guard case let .receipt(receipt) = stored.value else { return false }
            guard receipt.audioSHA256 == audioSHA256.lowercased(),
                  receipt.stateRevision == stateRevision
            else { return false }
            try Self.unlinkSlot(stored, descriptor: descriptor)
            return true
        }
    }

    public func count() throws -> Int {
        try withLockedDirectory { descriptor in
            try Self.receiptCount(descriptor: descriptor)
        }
    }

    public func occupiedCount() throws -> Int {
        try withLockedDirectory { descriptor in
            try Self.occupiedSlotCount(descriptor: descriptor)
        }
    }

    private func withLockedDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let descriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FinalDeliveryStatusStoreError.invalidRoot }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o7777 == 0o700,
              FinalDeliveryReceiptFileIdentity(metadata) == rootIdentity,
              flock(descriptor, LOCK_EX) == 0
        else { throw FinalDeliveryStatusStoreError.invalidRoot }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(descriptor)
    }

    private static func prepareRoot(_ rootURL: URL) throws -> FinalDeliveryReceiptFileIdentity {
        guard rootURL.isFileURL else { throw FinalDeliveryStatusStoreError.invalidRoot }
        do {
            if mkdir(rootURL.path, 0o700) != 0, errno != EEXIST {
                throw FinalDeliveryStatusStoreError.invalidRoot
            }
            let descriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw FinalDeliveryStatusStoreError.invalidRoot }
            defer { Darwin.close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(),
                  fchmod(descriptor, 0o700) == 0,
                  fsync(descriptor) == 0
            else { throw FinalDeliveryStatusStoreError.invalidRoot }
            return FinalDeliveryReceiptFileIdentity(metadata)
        } catch let error as FinalDeliveryStatusStoreError {
            throw error
        } catch {
            throw FinalDeliveryStatusStoreError.invalidRoot
        }
    }

    private static func isSameIdentity(_ left: FinalDeliveryReceipt, _ right: FinalDeliveryReceipt) -> Bool {
        left.memoID == right.memoID
            && left.audioSHA256 == right.audioSHA256
            && left.stateRevision == right.stateRevision
    }

    private static func receiptCount(descriptor: Int32) throws -> Int {
        try allSlots(descriptor: descriptor).reduce(into: 0) { count, slot in
            if case .receipt = slot.value { count += 1 }
        }
    }

    private static func occupiedSlotCount(descriptor: Int32) throws -> Int {
        try allSlots(descriptor: descriptor).count
    }

    private static func allSlots(descriptor: Int32) throws -> [StoredSlot] {
        try directoryEntryNames(descriptor: descriptor).map { name in
            guard receiptMemoID(forName: name) != nil else {
                throw FinalDeliveryStatusStoreError.invalidReceipt
            }
            guard let slot = try readSlot(named: name, descriptor: descriptor), slot.name == name else {
                throw FinalDeliveryStatusStoreError.fileSystemFailure
            }
            return slot
        }
    }

    private static func readSlot(
        memoID: MemoID,
        descriptor: Int32
    ) throws -> StoredSlot? {
        try readSlot(named: receiptName(memoID), descriptor: descriptor)
    }

    private static func readSlot(named name: String, descriptor: Int32) throws -> StoredSlot? {
        guard let expectedMemoID = receiptMemoID(forName: name) else {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
        let file = name.withCString { openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw FinalDeliveryStatusStoreError.fileSystemFailure
        }
        defer { Darwin.close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              isPrivateReceiptFile(metadata),
              metadata.st_size > 0,
              metadata.st_size <= maximumReceiptBytes,
              let identity = entryIdentity(name, directoryDescriptor: descriptor),
              identity == FinalDeliveryReceiptFileIdentity(metadata)
        else { throw FinalDeliveryStatusStoreError.invalidReceipt }
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
        guard bytesRead == data.count else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
        do {
            let decoder = JSONDecoder()
            if let receipt = try? decoder.decode(FinalDeliveryReceipt.self, from: data) {
                guard receipt.memoID == expectedMemoID else {
                    throw FinalDeliveryStatusStoreError.invalidReceipt
                }
                _ = try receipt.bridgeMemoStatus
                return StoredSlot(name: name, value: .receipt(receipt), identity: identity)
            }
            let reservation = try decoder.decode(FinalDeliveryCapacityReservation.self, from: data)
            guard reservation.memoID == expectedMemoID else {
                throw FinalDeliveryStatusStoreError.invalidReceipt
            }
            return StoredSlot(name: name, value: .reservation(reservation), identity: identity)
        } catch let error as FinalDeliveryStatusStoreError {
            throw error
        } catch {
            throw FinalDeliveryStatusStoreError.invalidReceipt
        }
    }

    private static func writeDocument<Value: Encodable>(
        _ value: Value,
        memoID: MemoID,
        descriptor: Int32,
        replacing expectedDestinationIdentity: FinalDeliveryReceiptFileIdentity?,
        faultInjector: @escaping @Sendable (FinalDeliveryStatusStoreMutationBoundary) throws -> Void
    ) throws {
        let temporaryName = ".final-receipt-\(UUID().uuidString.lowercased())"
        let destinationName = receiptName(memoID)
        var createdTemporary = false
        var temporaryIdentity: FinalDeliveryReceiptFileIdentity?
        do {
            try faultInjector(.beforeTemporaryCreation)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(value)
            guard !encoded.isEmpty, encoded.count <= maximumReceiptBytes else {
                throw FinalDeliveryStatusStoreError.invalidReceipt
            }
            let file = temporaryName.withCString {
                openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            }
            guard file >= 0 else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
            createdTemporary = true
            do {
                var metadata = stat()
                guard fstat(file, &metadata) == 0,
                      isPrivateReceiptFile(metadata),
                      fchmod(file, 0o600) == 0,
                      fstat(file, &metadata) == 0,
                      isPrivateReceiptFile(metadata)
                else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
                temporaryIdentity = FinalDeliveryReceiptFileIdentity(metadata)
                try writeAll(encoded, descriptor: file)
                guard fsync(file) == 0 else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
            } catch {
                Darwin.close(file)
                throw error
            }
            Darwin.close(file)
            guard let temporaryIdentity,
                  entryIdentity(temporaryName, directoryDescriptor: descriptor) == temporaryIdentity
            else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
            try faultInjector(.beforeRename)
            let result: Int32
            if let expectedDestinationIdentity {
                guard entryIdentity(destinationName, directoryDescriptor: descriptor)
                    == expectedDestinationIdentity
                else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
                result = temporaryName.withCString { source in
                    destinationName.withCString { destination in
                        renameat(descriptor, source, descriptor, destination)
                    }
                }
            } else {
                result = temporaryName.withCString { source in
                    destinationName.withCString { destination in
                        renameatx_np(descriptor, source, descriptor, destination, UInt32(RENAME_EXCL))
                    }
                }
            }
            guard result == 0 else {
                if errno == EEXIST { throw FinalDeliveryStatusStoreError.identityConflict }
                throw FinalDeliveryStatusStoreError.fileSystemFailure
            }
            createdTemporary = false
            guard entryIdentity(destinationName, directoryDescriptor: descriptor) == temporaryIdentity,
                  fsync(descriptor) == 0
            else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
        } catch let error as FinalDeliveryStatusStoreError {
            if createdTemporary {
                unlinkIfIdentityMatches(temporaryName, identity: temporaryIdentity, directoryDescriptor: descriptor)
            }
            throw error
        } catch {
            if createdTemporary {
                unlinkIfIdentityMatches(temporaryName, identity: temporaryIdentity, directoryDescriptor: descriptor)
            }
            throw FinalDeliveryStatusStoreError.fileSystemFailure
        }
    }

    private static func unlinkSlot(_ slot: StoredSlot, descriptor: Int32) throws {
        guard entryIdentity(slot.name, directoryDescriptor: descriptor) == slot.identity,
              slot.name.withCString({ unlinkat(descriptor, $0, 0) }) == 0,
              fsync(descriptor) == 0
        else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
    }

    private static func receiptName(_ memoID: MemoID) -> String {
        "\(memoID.rawValue).json"
    }

    private static func receiptMemoID(forName name: String) -> MemoID? {
        guard name.hasSuffix(".json") else { return nil }
        return try? MemoID(String(name.dropLast(5)))
    }

    private static func recoverInterruptedWrites(descriptor: Int32) throws {
        for name in try directoryEntryNames(descriptor: descriptor)
        where isTemporaryReceiptName(name) {
            let file = name.withCString {
                openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard file >= 0 else { throw FinalDeliveryStatusStoreError.invalidReceipt }
            defer { Darwin.close(file) }

            var metadata = stat()
            guard fstat(file, &metadata) == 0,
                  isPrivateReceiptFile(metadata)
            else { throw FinalDeliveryStatusStoreError.invalidReceipt }
            let identity = FinalDeliveryReceiptFileIdentity(metadata)
            guard entryIdentity(name, directoryDescriptor: descriptor) == identity,
                  fstat(file, &metadata) == 0,
                  isPrivateReceiptFile(metadata),
                  FinalDeliveryReceiptFileIdentity(metadata) == identity,
                  entryIdentity(name, directoryDescriptor: descriptor) == identity,
                  name.withCString({ unlinkat(descriptor, $0, 0) }) == 0,
                  fsync(descriptor) == 0
            else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
        }
    }

    private static func isTemporaryReceiptName(_ name: String) -> Bool {
        let prefix = ".final-receipt-"
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard suffix.count == 36,
              let identifier = UUID(uuidString: suffix)
        else { return false }
        return identifier.uuidString.lowercased() == suffix
    }

    private static func isPrivateReceiptFile(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600
    }

    private static func entryIdentity(
        _ name: String,
        directoryDescriptor: Int32
    ) -> FinalDeliveryReceiptFileIdentity? {
        var metadata = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0, isPrivateReceiptFile(metadata) else { return nil }
        return FinalDeliveryReceiptFileIdentity(metadata)
    }

    private static func unlinkIfIdentityMatches(
        _ name: String,
        identity: FinalDeliveryReceiptFileIdentity?,
        directoryDescriptor: Int32
    ) {
        guard let identity,
              entryIdentity(name, directoryDescriptor: directoryDescriptor) == identity
        else { return }
        _ = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let scanDescriptor = ".".withCString {
            openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard scanDescriptor >= 0 else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
        guard let directory = fdopendir(scanDescriptor) else {
            Darwin.close(scanDescriptor)
            throw FinalDeliveryStatusStoreError.fileSystemFailure
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
        guard errno == 0 else { throw FinalDeliveryStatusStoreError.fileSystemFailure }
        return names
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
                    throw FinalDeliveryStatusStoreError.fileSystemFailure
                }
            }
        }
    }

    private enum SlotValue {
        case receipt(FinalDeliveryReceipt)
        case reservation(FinalDeliveryCapacityReservation)
    }

    private struct StoredSlot {
        let name: String
        let value: SlotValue
        let identity: FinalDeliveryReceiptFileIdentity
    }
}

private struct FinalDeliveryReceiptFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }
}
