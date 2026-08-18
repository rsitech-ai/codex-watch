import CryptoKit
import Darwin
import Foundation
import Security

public struct ProvisionedTLSIdentity: @unchecked Sendable {
    public let secIdentity: SecIdentity
    public let publicKeySHA256: String

    public init(secIdentity: SecIdentity, publicKeySHA256: String) {
        self.secIdentity = secIdentity
        self.publicKeySHA256 = publicKeySHA256
    }
}

public protocol TLSIdentityKeychain: Sendable {
    func load(label: String) throws -> SecIdentity?
    func insert(privateKey: SecKey, certificate: SecCertificate, label: String) throws -> SecIdentity
    func remove(label: String) throws
}

public protocol TLSIdentityMutationLock: Sendable {
    func withLock<T>(_ operation: () throws -> T) throws -> T
}

public final class ProcessTLSIdentityMutationLock: TLSIdentityMutationLock, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public final class SystemTLSIdentityMutationLock: TLSIdentityMutationLock, @unchecked Sendable {
    private static let processLock = NSLock()
    private let lockURL: URL
    private let timeout: TimeInterval
    private let beforeFinalPathValidation: () throws -> Void

    public init(timeout: TimeInterval = 5) {
        lockURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "ai.rsitech.codexwatch.bridge", directoryHint: .isDirectory)
            .appending(path: "tls-identity.lock")
        self.timeout = timeout
        beforeFinalPathValidation = {}
    }

    init(
        lockURL: URL,
        timeout: TimeInterval = 5,
        beforeFinalPathValidation: @escaping () throws -> Void = {}
    ) {
        self.lockURL = lockURL.standardizedFileURL
        self.timeout = timeout
        self.beforeFinalPathValidation = beforeFinalPathValidation
    }

    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard timeout.isFinite, timeout > 0 else {
            throw TLSIdentityProvisionerError.transactionUnavailable
        }
        let directory = lockURL.deletingLastPathComponent()
        try Self.preparePrivateDirectory(directory)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TLSIdentityProvisionerError.transactionUnavailable }
        defer { close(descriptor) }
        guard let identity = SecureAdvisoryLockFile.descriptorIdentity(
            descriptor,
            normalizeMode: true
        ) else { throw TLSIdentityProvisionerError.transactionUnavailable }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                throw TLSIdentityProvisionerError.transactionUnavailable
            }
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard SecureAdvisoryLockFile.path(lockURL, matches: identity) else {
            throw TLSIdentityProvisionerError.transactionUnavailable
        }
        do { try beforeFinalPathValidation() }
        catch { throw TLSIdentityProvisionerError.transactionUnavailable }
        guard SecureAdvisoryLockFile.path(lockURL, matches: identity) else {
            throw TLSIdentityProvisionerError.transactionUnavailable
        }
        return try operation()
    }

    private static func preparePrivateDirectory(_ directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        var parentMetadata = stat()
        guard lstat(parent.path, &parentMetadata) == 0,
              (parentMetadata.st_mode & S_IFMT) == S_IFDIR,
              parentMetadata.st_uid == getuid()
        else { throw TLSIdentityProvisionerError.transactionUnavailable }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch CocoaError.fileWriteFileExists {
            // Validate the existing exact path below.
        } catch {
            throw TLSIdentityProvisionerError.transactionUnavailable
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0
        else { throw TLSIdentityProvisionerError.transactionUnavailable }
    }
}

private protocol TLSIdentityStagingKeychain: TLSIdentityKeychain {
    func promote(stagingLabel: String, to label: String) throws -> SecIdentity
}

public enum TLSIdentityProvisionerError: Error, Equatable, Sendable {
    case invalidIdentity
    case keychainUnavailable
    case rotationFailed
    case stagedCleanupFailed
    case recoveryFailed
    case transactionUnavailable
    case keychainRemovalFailed(certificateStatus: OSStatus, keyStatus: OSStatus)
}

struct ValidatedTLSIdentity: @unchecked Sendable {
    let privateKey: SecKey
    let certificate: SecCertificate
    let publicKeySHA256: String
}

struct TLSIdentitySnapshot: @unchecked Sendable {
    let privateKey: SecKey
    let certificate: SecCertificate
    let certificateData: Data
    let publicKeyData: Data

    init(identity: SecIdentity) throws {
        let components = try TLSIdentityProvisioner.components(identity)
        guard let privatePublicKey = SecKeyCopyPublicKey(components.privateKey),
              let privatePublicBytes = SecKeyCopyExternalRepresentation(privatePublicKey, nil) as Data?,
              let certificatePublicKey = SecCertificateCopyKey(components.certificate),
              let certificatePublicBytes = SecKeyCopyExternalRepresentation(certificatePublicKey, nil) as Data?,
              privatePublicBytes == certificatePublicBytes
        else { throw TLSIdentityProvisionerError.invalidIdentity }
        privateKey = components.privateKey
        certificate = components.certificate
        certificateData = SecCertificateCopyData(components.certificate) as Data
        publicKeyData = privatePublicBytes
    }

    func matches(_ identity: SecIdentity) throws -> Bool {
        let candidate = try TLSIdentitySnapshot(identity: identity)
        return candidate.certificateData == certificateData
            && candidate.publicKeyData == publicKeyData
    }
}

public struct TLSIdentityRotationReceipt: @unchecked Sendable {
    public let rotated: ProvisionedTLSIdentity
    fileprivate let previous: TLSIdentitySnapshot?

    fileprivate init(rotated: ProvisionedTLSIdentity, previous: TLSIdentitySnapshot?) {
        self.rotated = rotated
        self.previous = previous
    }
}

struct TLSIdentityValidator: Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func validate(_ identity: SecIdentity) throws -> ValidatedTLSIdentity {
        var privateKey: SecKey?
        var certificate: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey,
              SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let certificateKey = SecCertificateCopyKey(certificate),
              let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              let privatePublicBytes = SecKeyCopyExternalRepresentation(privatePublicKey, nil) as Data?,
              certificateBytes == privatePublicBytes,
              Self.isP256(certificateKey),
              Self.isP256(privateKey)
        else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }

        let parsed: X509IdentityProfile
        do { parsed = try X509IdentityProfile(certificate: certificate) }
        catch {
            throw error
        }
        let instant = now()
        guard parsed.notBefore <= instant,
              instant <= parsed.notAfter,
              parsed.issuer == parsed.subject,
              parsed.signatureAlgorithmOID == "1.2.840.10045.4.3.2",
              parsed.tbsSignatureAlgorithmOID == parsed.signatureAlgorithmOID,
              parsed.subjectPublicKeyAlgorithmOID == "1.2.840.10045.2.1",
              parsed.subjectPublicKeyCurveOID == "1.2.840.10045.3.1.7",
              parsed.subjectPublicKeyBytes == certificateBytes,
              parsed.keyUsageCritical,
              parsed.digitalSignatureKeyUsage,
              parsed.extendedKeyUsageOIDs.contains("1.3.6.1.5.5.7.3.1"),
              SecKeyVerifySignature(
                  certificateKey,
                  .ecdsaSignatureMessageX962SHA256,
                  parsed.tbsCertificate as CFData,
                  parsed.signature as CFData,
                  nil
              )
        else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }

        let challenge = Data("codex-watch-bridge-identity-validation".utf8)
        guard let challengeSignature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            nil
        ) as Data?,
        SecKeyVerifySignature(
            certificateKey,
            .ecdsaSignatureMessageX962SHA256,
            challenge as CFData,
            challengeSignature as CFData,
            nil
        ) else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }

        return ValidatedTLSIdentity(
            privateKey: privateKey,
            certificate: certificate,
            publicKeySHA256: SHA256.hash(data: certificateBytes)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private static func isP256(_ key: SecKey) -> Bool {
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any] else { return false }
        return attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String
            && attributes[kSecAttrKeySizeInBits] as? Int == 256
    }
}

struct X509IdentityProfile {
    struct ParsedExtensions {
        let foundKeyUsage: Bool
        let keyUsageCritical: Bool
        let digitalSignatureKeyUsage: Bool
        let extendedKeyUsageOIDs: Set<String>
    }

    let tbsCertificate: Data
    let signature: Data
    let signatureAlgorithmOID: String
    let tbsSignatureAlgorithmOID: String
    let issuer: Data
    let subject: Data
    let notBefore: Date
    let notAfter: Date
    let subjectPublicKeyAlgorithmOID: String
    let subjectPublicKeyCurveOID: String
    let subjectPublicKeyBytes: Data
    let keyUsageCritical: Bool
    let digitalSignatureKeyUsage: Bool
    let extendedKeyUsageOIDs: Set<String>

    init(certificate: SecCertificate) throws {
        var certificateReader = X509DERReader(SecCertificateCopyData(certificate) as Data)
        let certificateSequence = try certificateReader.read(expectedTag: 0x30)
        guard certificateReader.isAtEnd else { throw TLSIdentityProvisionerError.invalidIdentity }
        var outer = X509DERReader(certificateSequence.value)
        let tbs = try outer.read(expectedTag: 0x30)
        let outerAlgorithm = try Self.algorithmOID(outer.read(expectedTag: 0x30).value)
        let signatureBits = try outer.read(expectedTag: 0x03).value
        guard outer.isAtEnd, signatureBits.first == 0 else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }

        var fields = X509DERReader(tbs.value)
        try Self.validateVersion(fields.read(expectedTag: 0xa0).value)
        let serial = try fields.read(expectedTag: 0x02).value
        try Self.validateSerial(serial)
        let tbsAlgorithm = try Self.algorithmOID(fields.read(expectedTag: 0x30).value)
        let issuerValue = try fields.read(expectedTag: 0x30)
        var validity = X509DERReader(try fields.read(expectedTag: 0x30).value)
        let before = try Self.date(validity.read())
        let after = try Self.date(validity.read())
        guard validity.isAtEnd, before < after else { throw TLSIdentityProvisionerError.invalidIdentity }
        let subjectValue = try fields.read(expectedTag: 0x30)
        var subjectPublicKeyInfo = X509DERReader(try fields.read(expectedTag: 0x30).value)
        var publicKeyAlgorithm = X509DERReader(
            try subjectPublicKeyInfo.read(expectedTag: 0x30).value
        )
        let publicKeyAlgorithmOID = try Self.decodeOID(publicKeyAlgorithm.read(expectedTag: 0x06).value)
        let curveOID = try Self.decodeOID(publicKeyAlgorithm.read(expectedTag: 0x06).value)
        let publicKeyBits = try subjectPublicKeyInfo.read(expectedTag: 0x03).value
        guard publicKeyAlgorithm.isAtEnd,
              subjectPublicKeyInfo.isAtEnd,
              publicKeyBits.first == 0,
              fields.peekTag == 0xa3
        else { throw TLSIdentityProvisionerError.invalidIdentity }

        var extensionWrapper = X509DERReader(try fields.read(expectedTag: 0xa3).value)
        let extensionEntries = try extensionWrapper.read(expectedTag: 0x30).value
        guard extensionWrapper.isAtEnd, fields.isAtEnd else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let parsedExtensions = try Self.parseExtensions(extensionEntries)

        guard parsedExtensions.foundKeyUsage,
              !parsedExtensions.extendedKeyUsageOIDs.isEmpty
        else { throw TLSIdentityProvisionerError.invalidIdentity }
        tbsCertificate = tbs.encoded
        signature = Data(signatureBits.dropFirst())
        signatureAlgorithmOID = outerAlgorithm
        tbsSignatureAlgorithmOID = tbsAlgorithm
        issuer = issuerValue.encoded
        subject = subjectValue.encoded
        notBefore = before
        notAfter = after
        subjectPublicKeyAlgorithmOID = publicKeyAlgorithmOID
        subjectPublicKeyCurveOID = curveOID
        subjectPublicKeyBytes = Data(publicKeyBits.dropFirst())
        keyUsageCritical = parsedExtensions.keyUsageCritical
        digitalSignatureKeyUsage = parsedExtensions.digitalSignatureKeyUsage
        extendedKeyUsageOIDs = parsedExtensions.extendedKeyUsageOIDs
    }

    static func validateVersion(_ data: Data) throws {
        var version = X509DERReader(data)
        guard try version.read(expectedTag: 0x02).value == Data([0x02]),
              version.isAtEnd
        else { throw TLSIdentityProvisionerError.invalidIdentity }
    }

    static func validateSerial(_ serial: Data) throws {
        guard (1 ... 20).contains(serial.count),
              serial[serial.startIndex] & 0x80 == 0,
              serial.contains(where: { $0 != 0 })
        else { throw TLSIdentityProvisionerError.invalidIdentity }
        if serial.count > 1,
           serial[serial.startIndex] == 0,
           serial[serial.index(after: serial.startIndex)] & 0x80 == 0
        {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
    }

    static func parseExtensions(_ data: Data) throws -> ParsedExtensions {
        var extensions = X509DERReader(data)
        var foundKeyUsage = false
        var keyUsageIsCritical = false
        var hasDigitalSignature = false
        var ekuOIDs: Set<String> = []
        var encounteredOIDs: Set<String> = []
        while !extensions.isAtEnd {
            var item = X509DERReader(try extensions.read(expectedTag: 0x30).value)
            let extensionOID = try Self.decodeOID(item.read(expectedTag: 0x06).value)
            guard encounteredOIDs.insert(extensionOID).inserted else {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
            var critical = false
            if item.peekTag == 0x01 {
                guard try item.read(expectedTag: 0x01).value == Data([0xff]) else {
                    throw TLSIdentityProvisionerError.invalidIdentity
                }
                critical = true
            }
            let extensionValue = try item.read(expectedTag: 0x04).value
            guard item.isAtEnd else { throw TLSIdentityProvisionerError.invalidIdentity }
            if extensionOID == "2.5.29.15" {
                var bitsReader = X509DERReader(extensionValue)
                let bits = try bitsReader.read(expectedTag: 0x03).value
                guard bitsReader.isAtEnd, bits.count >= 2, bits[0] <= 7 else {
                    throw TLSIdentityProvisionerError.invalidIdentity
                }
                foundKeyUsage = true
                keyUsageIsCritical = critical
                hasDigitalSignature = bits[1] & 0x80 != 0
            } else if extensionOID == "2.5.29.37" {
                var sequenceWrapper = X509DERReader(extensionValue)
                var sequence = X509DERReader(try sequenceWrapper.read(expectedTag: 0x30).value)
                guard sequenceWrapper.isAtEnd else { throw TLSIdentityProvisionerError.invalidIdentity }
                while !sequence.isAtEnd {
                    let oid = try Self.decodeOID(sequence.read(expectedTag: 0x06).value)
                    guard ekuOIDs.insert(oid).inserted else {
                        throw TLSIdentityProvisionerError.invalidIdentity
                    }
                }
            } else if critical {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
        }
        return ParsedExtensions(
            foundKeyUsage: foundKeyUsage,
            keyUsageCritical: keyUsageIsCritical,
            digitalSignatureKeyUsage: hasDigitalSignature,
            extendedKeyUsageOIDs: ekuOIDs
        )
    }

    private static func algorithmOID(_ data: Data) throws -> String {
        var algorithm = X509DERReader(data)
        let value = try decodeOID(algorithm.read(expectedTag: 0x06).value)
        guard algorithm.isAtEnd else { throw TLSIdentityProvisionerError.invalidIdentity }
        return value
    }

    static func decodeOID(_ data: Data) throws -> String {
        var subidentifiers: [UInt64] = []
        var value: UInt64 = 0
        var componentBytes = 0
        for byte in data {
            if componentBytes == 0, byte == 0x80 {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
            let chunk = UInt64(byte & 0x7f)
            guard value <= (UInt64.max - chunk) / 128 else {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
            value = value * 128 + chunk
            componentBytes += 1
            if byte & 0x80 == 0 {
                subidentifiers.append(value)
                value = 0
                componentBytes = 0
            }
        }
        guard componentBytes == 0, let first = subidentifiers.first else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let firstPart: UInt64
        let secondPart: UInt64
        if first < 40 {
            firstPart = 0
            secondPart = first
        } else if first < 80 {
            firstPart = 1
            secondPart = first - 40
        } else {
            firstPart = 2
            secondPart = first - 80
        }
        let parts = [firstPart, secondPart] + subidentifiers.dropFirst()
        return parts.map(String.init).joined(separator: ".")
    }

    private static func date(_ value: X509DERValue) throws -> Date {
        guard let raw = String(data: value.value, encoding: .ascii) else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        return try decodeTime(tag: value.tag, raw: raw)
    }

    static func decodeTime(tag: UInt8, raw: String) throws -> Date {
        let normalized: String
        switch tag {
        case 0x17:
            guard raw.count == 13,
                  raw.last == "Z",
                  raw.dropLast().allSatisfy(\.isNumber),
                  let year = Int(raw.prefix(2))
            else {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
            normalized = "\(year <= 49 ? "20" : "19")\(raw)"
        case 0x18:
            guard raw.count == 15,
                  raw.last == "Z",
                  raw.dropLast().allSatisfy(\.isNumber),
                  let year = Int(raw.prefix(4)),
                  year >= 2050
            else { throw TLSIdentityProvisionerError.invalidIdentity }
            normalized = raw
        default:
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: normalized) else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        guard formatter.string(from: parsed) == normalized else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        return parsed
    }
}

private struct X509DERValue {
    let tag: UInt8
    let value: Data
    let encoded: Data
}

private struct X509DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }
    var peekTag: UInt8? { offset < data.count ? data[offset] : nil }

    mutating func read(expectedTag: UInt8? = nil) throws -> X509DERValue {
        let start = offset
        guard offset < data.count else { throw TLSIdentityProvisionerError.invalidIdentity }
        let tag = data[offset]
        offset += 1
        guard expectedTag == nil || tag == expectedTag, offset < data.count else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let firstLength = data[offset]
        offset += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let count = Int(firstLength & 0x7f)
            guard count > 0, count <= 4, offset + count <= data.count,
                  data[offset] != 0
            else { throw TLSIdentityProvisionerError.invalidIdentity }
            var accumulated = 0
            for _ in 0 ..< count {
                accumulated = accumulated << 8 | Int(data[offset])
                offset += 1
            }
            guard accumulated >= 128 else { throw TLSIdentityProvisionerError.invalidIdentity }
            length = accumulated
        }
        guard length >= 0, offset + length <= data.count else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let value = data.subdata(in: offset ..< offset + length)
        offset += length
        return X509DERValue(tag: tag, value: value, encoded: data.subdata(in: start ..< offset))
    }
}

public actor TLSIdentityProvisioner {
    public static let defaultLabel = "ai.rsitech.codexwatch.bridge.tls"

    private let keychain: any TLSIdentityKeychain
    private let label: String
    private let mutationLock: any TLSIdentityMutationLock
    private let buildCertificate: @Sendable () throws -> GeneratedX509Certificate

    public init(
        keychain: any TLSIdentityKeychain,
        label: String = TLSIdentityProvisioner.defaultLabel,
        mutationLock: any TLSIdentityMutationLock = SystemTLSIdentityMutationLock()
    ) {
        self.keychain = keychain
        self.label = label
        self.mutationLock = mutationLock
        buildCertificate = { try X509CertificateBuilder().build() }
    }

    init(
        keychain: any TLSIdentityKeychain,
        label: String = TLSIdentityProvisioner.defaultLabel,
        mutationLock: any TLSIdentityMutationLock,
        buildCertificate: @escaping @Sendable () throws -> GeneratedX509Certificate
    ) {
        self.keychain = keychain
        self.label = label
        self.mutationLock = mutationLock
        self.buildCertificate = buildCertificate
    }

    public func loadOrCreate() throws -> ProvisionedTLSIdentity {
        do {
            return try mutationLock.withLock { try loadOrCreateLocked() }
        } catch {
            throw error
        }
    }

    public func loadExisting() throws -> ProvisionedTLSIdentity? {
        try mutationLock.withLock {
            guard let existing = try sanitized({ try keychain.load(label: label) }) else {
                return nil
            }
            return try Self.provisioned(existing)
        }
    }

    public func beginRotation() throws -> TLSIdentityRotationReceipt {
        try mutationLock.withLock {
            let previous = try sanitized { try keychain.load(label: label) }
            let snapshot = try previous.map(TLSIdentitySnapshot.init)
            let rotated: ProvisionedTLSIdentity
            do {
                rotated = try rotateLocked()
            } catch TLSIdentityProvisionerError.stagedCleanupFailed {
                guard let active = try sanitized({ try keychain.load(label: label) }) else {
                    throw TLSIdentityProvisionerError.recoveryFailed
                }
                rotated = try Self.provisioned(active)
            }
            return TLSIdentityRotationReceipt(rotated: rotated, previous: snapshot)
        }
    }

    public func rollbackRotation(_ receipt: TLSIdentityRotationReceipt) throws {
        try mutationLock.withLock {
            do {
                guard let active = try keychain.load(label: label),
                      try Self.provisioned(active).publicKeySHA256
                        == receipt.rotated.publicKeySHA256
                else { throw TLSIdentityProvisionerError.recoveryFailed }
                try keychain.remove(label: label)
                if let previous = receipt.previous {
                    _ = try keychain.insert(
                        privateKey: previous.privateKey,
                        certificate: previous.certificate,
                        label: label
                    )
                    guard let restored = try keychain.load(label: label),
                          try previous.matches(restored)
                    else { throw TLSIdentityProvisionerError.recoveryFailed }
                } else if try keychain.load(label: label) != nil {
                    throw TLSIdentityProvisionerError.recoveryFailed
                }
            } catch {
                throw TLSIdentityProvisionerError.recoveryFailed
            }
        }
    }

    public func rotate() throws -> ProvisionedTLSIdentity {
        try mutationLock.withLock { try rotateLocked() }
    }

    private func loadOrCreateLocked() throws -> ProvisionedTLSIdentity {
        if let existing = try sanitized({ try keychain.load(label: label) }) {
                return try Self.provisioned(existing)
        }
        let generated = try buildCertificate()
        let inserted = try sanitized {
            try keychain.insert(
                privateKey: generated.privateKey,
                certificate: generated.certificate,
                label: label
            )
        }
        do {
            let provisioned = try Self.provisioned(inserted)
            let expectedFingerprint = try Self.publicKeyFingerprint(generated.privateKey)
            guard provisioned.publicKeySHA256 == expectedFingerprint else {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
            return provisioned
        } catch {
            do { try keychain.remove(label: label) }
            catch { throw TLSIdentityProvisionerError.recoveryFailed }
            throw TLSIdentityProvisionerError.invalidIdentity
        }
    }

    private func rotateLocked() throws -> ProvisionedTLSIdentity {
        let previous = try sanitized { try keychain.load(label: label) }
        let previousSnapshot = try previous.map(TLSIdentitySnapshot.init)
        let generated = try buildCertificate()
        let expectedFingerprint = try Self.publicKeyFingerprint(generated.privateKey)
        let stagingLabel = "\(label).staged.\(UUID().uuidString)"
        let staged = try sanitized {
            try keychain.insert(
                privateKey: generated.privateKey,
                certificate: generated.certificate,
                label: stagingLabel
            )
        }
        do {
            let validatedStage = try Self.provisioned(staged)
            guard validatedStage.publicKeySHA256 == expectedFingerprint else {
                throw TLSIdentityProvisionerError.invalidIdentity
            }
        } catch {
            do { try keychain.remove(label: stagingLabel) }
            catch { throw TLSIdentityProvisionerError.recoveryFailed }
            throw TLSIdentityProvisionerError.invalidIdentity
        }

        do {
            try keychain.remove(label: label)
        } catch {
            try restore(previous: previousSnapshot, stagingLabel: stagingLabel)
            throw TLSIdentityProvisionerError.rotationFailed
        }

        let promoted: SecIdentity
        let promotionConsumedStage: Bool
        do {
            if let stagingKeychain = keychain as? any TLSIdentityStagingKeychain {
                promoted = try stagingKeychain.promote(stagingLabel: stagingLabel, to: label)
                promotionConsumedStage = true
            } else {
                promoted = try keychain.insert(
                    privateKey: generated.privateKey,
                    certificate: generated.certificate,
                    label: label
                )
                promotionConsumedStage = false
            }
        } catch {
            try restore(previous: previousSnapshot, stagingLabel: stagingLabel)
            throw TLSIdentityProvisionerError.rotationFailed
        }

        do {
            let provisioned = try Self.provisioned(promoted)
            guard provisioned.publicKeySHA256 == expectedFingerprint,
                  let stored = try keychain.load(label: label),
                  try Self.provisioned(stored).publicKeySHA256 == expectedFingerprint
            else { throw TLSIdentityProvisionerError.invalidIdentity }
            if !promotionConsumedStage {
                do { try keychain.remove(label: stagingLabel) }
                catch { throw TLSIdentityProvisionerError.stagedCleanupFailed }
            }
            return provisioned
        } catch TLSIdentityProvisionerError.stagedCleanupFailed {
            throw TLSIdentityProvisionerError.stagedCleanupFailed
        } catch {
            try restore(previous: previousSnapshot, stagingLabel: stagingLabel)
            throw TLSIdentityProvisionerError.rotationFailed
        }
    }

    private func restore(
        previous: TLSIdentitySnapshot?,
        stagingLabel: String
    ) throws {
        do {
            if let previous,
               let active = try keychain.load(label: label),
               try previous.matches(active)
            {
                try keychain.remove(label: stagingLabel)
                return
            }
            try keychain.remove(label: label)
            guard let previous else {
                try keychain.remove(label: stagingLabel)
                throw TLSIdentityProvisionerError.recoveryFailed
            }
            _ = try keychain.insert(
                privateKey: previous.privateKey,
                certificate: previous.certificate,
                label: label
            )
            guard let restored = try keychain.load(label: label),
                  try previous.matches(restored)
            else { throw TLSIdentityProvisionerError.recoveryFailed }
            try keychain.remove(label: stagingLabel)
        } catch {
            throw TLSIdentityProvisionerError.recoveryFailed
        }
    }

    private static func publicKeyFingerprint(_ privateKey: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw TLSIdentityProvisionerError.invalidIdentity }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func sanitized<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw TLSIdentityProvisionerError.keychainUnavailable }
    }

    fileprivate static func provisioned(_ identity: SecIdentity) throws -> ProvisionedTLSIdentity {
        let validated = try TLSIdentityValidator().validate(identity)
        return ProvisionedTLSIdentity(
            secIdentity: identity,
            publicKeySHA256: validated.publicKeySHA256
        )
    }

    fileprivate static func components(
        _ identity: SecIdentity
    ) throws -> (privateKey: SecKey, certificate: SecCertificate) {
        var privateKey: SecKey?
        var certificate: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey,
              SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else { throw TLSIdentityProvisionerError.invalidIdentity }
        return (privateKey, certificate)
    }
}

public struct KeychainTLSIdentityProvider: BridgeTLSIdentityProvider, Sendable {
    private let keychain: any TLSIdentityKeychain
    private let label: String

    public init(
        keychain: any TLSIdentityKeychain,
        label: String = TLSIdentityProvisioner.defaultLabel
    ) {
        self.keychain = keychain
        self.label = label
    }

    public func loadIdentity() throws -> BridgeTLSIdentity {
        guard let identity = try keychain.load(label: label) else {
            throw TLSIdentityProvisionerError.invalidIdentity
        }
        let provisioned = try TLSIdentityProvisioner.provisioned(identity)
        return try BridgeTLSIdentity(secIdentity: provisioned.secIdentity)
    }

    public func persistToStateDirectory(_ directory: URL) throws {
        guard let identity = try keychain.load(label: label) else { return }
        try PersistedTLSIdentity.persist(identity: identity, stateDirectory: directory)
    }
}

public final class SystemTLSIdentityKeychain: TLSIdentityKeychain, TLSIdentityStagingKeychain,
    @unchecked Sendable
{
    struct PromotionQueries {
        let keyMatch: [CFString: Any]
        let keyAttributes: [CFString: Any]
        let certificateMatch: [CFString: Any]
        let certificateAttributes: [CFString: Any]
    }

    /// Pure query construction stays independently testable.
    /// ponytail: file-based login Keychain until a Developer ID provisioning
    /// profile can carry application-identifier / keychain-access-groups for
    /// Data Protection Keychain (errSecMissingEntitlement -34018 otherwise).
    enum Query {
        static func keyAdd(privateKey: SecKey, label: String) -> [CFString: Any] {
            var item: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecValueRef: privateKey,
                kSecAttrLabel: label,
                kSecAttrApplicationTag: Data(label.utf8),
                kSecAttrIsPermanent: true,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrCanSign: true,
                kSecAttrCanVerify: true,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ]
            // File-based Keychain pairs cert↔key via application label (public key hash).
            if let publicKey = SecKeyCopyPublicKey(privateKey),
               let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
            {
                item[kSecAttrApplicationLabel] = Data(Insecure.SHA1.hash(data: publicBytes))
            }
            return item
        }

        static func certificateAdd(
            certificate: SecCertificate,
            label: String
        ) -> [CFString: Any] {
            [
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
                kSecAttrLabel: label,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ]
        }

        static func identityLoad(label: String) -> [CFString: Any] {
            [
                kSecClass: kSecClassIdentity,
                kSecAttrLabel: label,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnRef: true,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ]
        }

        static func keyMatch(label: String) -> [CFString: Any] {
            [
                kSecClass: kSecClassKey,
                kSecAttrApplicationTag: Data(label.utf8),
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ]
        }

        static func certificateMatch(label: String) -> [CFString: Any] {
            [
                kSecClass: kSecClassCertificate,
                kSecAttrLabel: label,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
            ]
        }

        static func promotion(stagingLabel: String, activeLabel: String) -> PromotionQueries {
            PromotionQueries(
                keyMatch: keyMatch(label: stagingLabel),
                keyAttributes: [
                    kSecAttrLabel: activeLabel,
                    kSecAttrApplicationTag: Data(activeLabel.utf8),
                ],
                certificateMatch: certificateMatch(label: stagingLabel),
                certificateAttributes: [kSecAttrLabel: activeLabel]
            )
        }
    }

    private let lock = NSLock()

    public init() {}

    public func load(label: String) throws -> SecIdentity? {
        try lock.withLock { try loadWithoutLock(label: label) }
    }

    public func insert(
        privateKey: SecKey,
        certificate: SecCertificate,
        label: String
    ) throws -> SecIdentity {
        try lock.withLock {
            let keyItem = Query.keyAdd(privateKey: privateKey, label: label)
            let keyAddStatus = SecItemAdd(keyItem as CFDictionary, nil)
            guard keyAddStatus == errSecSuccess else {
                throw TLSIdentityProvisionerError.keychainUnavailable
            }
            let certificateItem = Query.certificateAdd(certificate: certificate, label: label)
            let certAddStatus = SecItemAdd(certificateItem as CFDictionary, nil)
            guard certAddStatus == errSecSuccess else {
                let cleanupStatus = SecItemDelete(keyQuery(label: label) as CFDictionary)
                guard Self.acceptedDeletionStatuses.contains(cleanupStatus) else {
                    throw TLSIdentityProvisionerError.recoveryFailed
                }
                throw TLSIdentityProvisionerError.keychainUnavailable
            }
            // File-based Keychain may rewrite label from the certificate CN; force
            // the stable provisioning label used by load/remove queries.
            let relabelStatus = SecItemUpdate(
                [
                    kSecClass: kSecClassCertificate,
                    kSecValueRef: certificate,
                    kSecAttrSynchronizable: kCFBooleanFalse as Any,
                ] as CFDictionary,
                [kSecAttrLabel: label] as CFDictionary
            )
            guard relabelStatus == errSecSuccess else {
                do { try removeWithoutLock(label: label) }
                catch { throw TLSIdentityProvisionerError.recoveryFailed }
                // Also delete by CN fallback if relabel failed before label stuck.
                _ = SecItemDelete([
                    kSecClass: kSecClassCertificate,
                    kSecValueRef: certificate,
                ] as CFDictionary)
                throw TLSIdentityProvisionerError.keychainUnavailable
            }
            do {
                // Prefer a live Keychain pairing; fall back to SecIdentityCreateWithCertificate
                // when the file-based Keychain has not yet surfaced a kSecClassIdentity item.
                if let matched = try identityMatchingCertificate(certificate) {
                    return matched
                }
                var created: SecIdentity?
                let createStatus = SecIdentityCreateWithCertificate(nil, certificate, &created)
                guard createStatus == errSecSuccess, let identity = created else {
                    throw TLSIdentityProvisionerError.invalidIdentity
                }
                return identity
            } catch {
                do { try removeWithoutLock(label: label) }
                catch { throw TLSIdentityProvisionerError.recoveryFailed }
                throw error
            }
        }
    }

    public func remove(label: String) throws {
        try lock.withLock {
            let certificateStatus = SecItemDelete(certificateQuery(label: label) as CFDictionary)
            let keyStatus = SecItemDelete(keyQuery(label: label) as CFDictionary)
            if let error = Self.removalError(
                certificateStatus: certificateStatus,
                keyStatus: keyStatus
            ) { throw error }
        }
    }

    fileprivate func promote(stagingLabel: String, to label: String) throws -> SecIdentity {
        try lock.withLock {
            let queries = Query.promotion(stagingLabel: stagingLabel, activeLabel: label)
            guard SecItemUpdate(
                queries.keyMatch as CFDictionary,
                queries.keyAttributes as CFDictionary
            ) == errSecSuccess else { throw TLSIdentityProvisionerError.keychainUnavailable }
            guard SecItemUpdate(
                queries.certificateMatch as CFDictionary,
                queries.certificateAttributes as CFDictionary
            ) == errSecSuccess else {
                let reverse = Query.promotion(stagingLabel: label, activeLabel: stagingLabel)
                guard SecItemUpdate(
                    reverse.keyMatch as CFDictionary,
                    reverse.keyAttributes as CFDictionary
                ) == errSecSuccess else { throw TLSIdentityProvisionerError.recoveryFailed }
                throw TLSIdentityProvisionerError.keychainUnavailable
            }
            do {
                guard let identity = try loadWithoutLock(label: label) else {
                    throw TLSIdentityProvisionerError.invalidIdentity
                }
                return identity
            } catch {
                do { try rollbackPromotionWithoutLock(from: label, to: stagingLabel) }
                catch { throw TLSIdentityProvisionerError.recoveryFailed }
                throw error
            }
        }
    }

    private func loadWithoutLock(label: String) throws -> SecIdentity? {
        // ponytail: identity queries by label alone are unreliable on the macOS
        // file-based Keychain when many fixture identities share the store.
        // Resolve the exact certificate by label, then match identity by cert bytes.
        var certificateQuery = Query.certificateMatch(label: label)
        certificateQuery[kSecMatchLimit] = kSecMatchLimitOne
        certificateQuery[kSecReturnRef] = true
        var certificateResult: CFTypeRef?
        let certificateStatus = SecItemCopyMatching(
            certificateQuery as CFDictionary,
            &certificateResult
        )
        if certificateStatus == errSecItemNotFound { return nil }
        guard certificateStatus == errSecSuccess,
              let certificate = certificateResult as! SecCertificate?
        else { throw TLSIdentityProvisionerError.keychainUnavailable }
        if let matched = try identityMatchingCertificate(certificate) {
            return matched
        }
        var created: SecIdentity?
        let createStatus = SecIdentityCreateWithCertificate(nil, certificate, &created)
        guard createStatus == errSecSuccess else { return nil }
        return created
    }

    private func identityMatchingCertificate(_ certificate: SecCertificate) throws -> SecIdentity? {
        let expectedCertificateData = SecCertificateCopyData(certificate) as Data
        guard let expectedKey = SecCertificateCopyKey(certificate),
              let expectedBytes = SecKeyCopyExternalRepresentation(expectedKey, nil) as Data?
        else { throw TLSIdentityProvisionerError.keychainUnavailable }

        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw TLSIdentityProvisionerError.keychainUnavailable
        }
        let identities: [SecIdentity]
        if let many = result as? [SecIdentity] {
            identities = many
        } else if let one = result as! SecIdentity? {
            identities = [one]
        } else {
            throw TLSIdentityProvisionerError.keychainUnavailable
        }
        for identity in identities {
            var identityCertificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &identityCertificate) == errSecSuccess,
                  let identityCertificate
            else { continue }
            let identityCertificateData = SecCertificateCopyData(identityCertificate) as Data
            if identityCertificateData == expectedCertificateData {
                return identity
            }
            guard let identityKey = SecCertificateCopyKey(identityCertificate),
                  let identityBytes = SecKeyCopyExternalRepresentation(identityKey, nil) as Data?,
                  identityBytes == expectedBytes
            else { continue }
            return identity
        }
        return nil
    }

    private func removeWithoutLock(label: String) throws {
        let certificateStatus = SecItemDelete(certificateQuery(label: label) as CFDictionary)
        let keyStatus = SecItemDelete(keyQuery(label: label) as CFDictionary)
        if let error = Self.removalError(
            certificateStatus: certificateStatus,
            keyStatus: keyStatus
        ) { throw error }
    }

    private func rollbackPromotionWithoutLock(from label: String, to stagingLabel: String) throws {
        let reverse = Query.promotion(stagingLabel: label, activeLabel: stagingLabel)
        let certificateStatus = SecItemUpdate(
            reverse.certificateMatch as CFDictionary,
            reverse.certificateAttributes as CFDictionary
        )
        let keyStatus = SecItemUpdate(
            reverse.keyMatch as CFDictionary,
            reverse.keyAttributes as CFDictionary
        )
        guard certificateStatus == errSecSuccess, keyStatus == errSecSuccess else {
            throw TLSIdentityProvisionerError.recoveryFailed
        }
    }

    private static let acceptedDeletionStatuses: Set<OSStatus> = [errSecSuccess, errSecItemNotFound]

    static func removalError(
        certificateStatus: OSStatus,
        keyStatus: OSStatus
    ) -> TLSIdentityProvisionerError? {
        guard acceptedDeletionStatuses.contains(certificateStatus),
              acceptedDeletionStatuses.contains(keyStatus)
        else {
            return .keychainRemovalFailed(
                certificateStatus: certificateStatus,
                keyStatus: keyStatus
            )
        }
        return nil
    }

    private func keyQuery(label: String) -> [CFString: Any] {
        Query.keyMatch(label: label)
    }

    private func certificateQuery(label: String) -> [CFString: Any] {
        Query.certificateMatch(label: label)
    }
}
