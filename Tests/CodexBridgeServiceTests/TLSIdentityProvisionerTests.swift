@testable import CodexBridgeService
import Foundation
import Security
import Testing

@Suite(.serialized) struct TLSIdentityProvisionerTests {
    @Test func provisionerCreatesOncePreservesOnUpdateAndRotatesExplicitly() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let mutationLock = RecordingTLSIdentityMutationLock()
        let provisioner = TLSIdentityProvisioner(keychain: keychain, mutationLock: mutationLock)

        let first = try await provisioner.loadOrCreate()
        let update = try await provisioner.loadOrCreate()
        let rotated = try await provisioner.rotate()
        let stored = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))

        #expect(update.publicKeySHA256 == first.publicKeySHA256)
        #expect(rotated.publicKeySHA256 != first.publicKeySHA256)
        #expect(try certificateData(rotated.secIdentity) == certificateData(stored))
        #expect(keychain.identityCount == 1)
        #expect(mutationLock.maximumConcurrentTransactions == 1)
        let staged = try #require(keychain.operations.firstIndex { $0.hasPrefix("insert:staged") })
        let removed = try #require(keychain.operations.lastIndex(of: "remove:active"))
        let promoted = try #require(keychain.operations.lastIndex(of: "insert:active"))
        #expect(staged < removed)
        #expect(removed < promoted)
    }

    @Test func loadExistingNeverCreatesAndRotationReceiptRestoresExactPriorIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        #expect(try await provisioner.loadExisting() == nil)
        #expect(keychain.identityCount == 0)
        let prior = try await provisioner.loadOrCreate()
        let priorCertificate = try certificateData(prior.secIdentity)
        let priorPublicKey = try publicKeyData(prior.secIdentity)

        let receipt = try await provisioner.beginRotation()
        #expect(receipt.rotated.publicKeySHA256 != prior.publicKeySHA256)
        try await provisioner.rollbackRotation(receipt)

        let restored = try #require(try await provisioner.loadExisting())
        #expect(try certificateData(restored.secIdentity) == priorCertificate)
        #expect(try publicKeyData(restored.secIdentity) == priorPublicKey)
    }

    @Test func invalidStagedIdentityIsRemovedWithoutDisturbingPriorIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        let first = try await provisioner.loadOrCreate()
        keychain.returnsInvalidIdentityForNextStage = true

        await #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try await provisioner.rotate()
        }

        let active = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try TLSIdentityValidator().validate(active).publicKeySHA256 == first.publicKeySHA256)
        #expect(keychain.identityCount == 1)
    }

    @Test func invalidStageWithCleanupFailureReturnsDistinctRecoveryFailure() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        _ = try await provisioner.loadOrCreate()
        keychain.returnsInvalidIdentityForNextStage = true
        keychain.failStagedRemoval = true

        await #expect(throws: TLSIdentityProvisionerError.recoveryFailed) {
            _ = try await provisioner.rotate()
        }

        #expect(try keychain.load(label: TLSIdentityProvisioner.defaultLabel) != nil)
    }

    @Test func oldRemovalFailureLeavesPriorActiveAndCleansStage() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        let first = try await provisioner.loadOrCreate()
        keychain.failActiveRemoval = true

        await #expect(throws: TLSIdentityProvisionerError.rotationFailed) {
            _ = try await provisioner.rotate()
        }

        let active = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try TLSIdentityValidator().validate(active).publicKeySHA256 == first.publicKeySHA256)
        #expect(keychain.identityCount == 1)
    }

    @Test func partialOldRemovalRestoresExactPriorIdentityBeforeReportingRotationFailure() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        let first = try await provisioner.loadOrCreate()
        let priorCertificate = try certificateData(first.secIdentity)
        let priorPublicKey = try publicKeyData(first.secIdentity)
        keychain.partiallyRemoveActiveThenFailOnce = true

        await #expect(throws: TLSIdentityProvisionerError.rotationFailed) {
            _ = try await provisioner.rotate()
        }

        let restored = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try certificateData(restored) == priorCertificate)
        #expect(try publicKeyData(restored) == priorPublicKey)
        #expect(keychain.identityCount == 1)
    }

    @Test func partialOldRemovalWithFailedRestorationReportsRecoveryFailure() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        _ = try await provisioner.loadOrCreate()
        keychain.partiallyRemoveActiveThenFailOnce = true
        keychain.failRestoreInsertion = true

        await #expect(throws: TLSIdentityProvisionerError.recoveryFailed) {
            _ = try await provisioner.rotate()
        }
    }

    @Test func explicitRotationReplacesExpiredActiveIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let expired = try X509CertificateBuilder(
            now: { utcProvisionerTestDate("20000101000000Z") }
        ).build()
        let expiredIdentity = try MemoryOnlyPKCS12Identity.make(
            privateKey: expired.privateKey,
            certificate: expired.certificate
        )
        try keychain.seedActive(expiredIdentity)
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )

        let rotated = try await provisioner.rotate()

        #expect(try certificateData(rotated.secIdentity) != SecCertificateCopyData(expired.certificate) as Data)
        #expect(try TLSIdentityValidator().validate(rotated.secIdentity).publicKeySHA256 == rotated.publicKeySHA256)
        #expect(keychain.identityCount == 1)
    }

    @Test func failedRotationRestoresExactExpiredPriorIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let expired = try X509CertificateBuilder(
            now: { utcProvisionerTestDate("20000101000000Z") }
        ).build()
        let expiredIdentity = try MemoryOnlyPKCS12Identity.make(
            privateKey: expired.privateKey,
            certificate: expired.certificate
        )
        let priorCertificate = try certificateData(expiredIdentity)
        let priorPublicKey = try publicKeyData(expiredIdentity)
        try keychain.seedActive(expiredIdentity)
        keychain.failNextActiveInsertion = true
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )

        await #expect(throws: TLSIdentityProvisionerError.rotationFailed) {
            _ = try await provisioner.rotate()
        }

        let restored = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try certificateData(restored) == priorCertificate)
        #expect(try publicKeyData(restored) == priorPublicKey)
        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator().validate(restored)
        }
        #expect(keychain.identityCount == 1)
    }

    @Test func loadOrCreateFailsClosedWithoutReplacingExpiredActiveIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let expired = try X509CertificateBuilder(
            now: { utcProvisionerTestDate("20000101000000Z") }
        ).build()
        let expiredIdentity = try MemoryOnlyPKCS12Identity.make(
            privateKey: expired.privateKey,
            certificate: expired.certificate
        )
        let priorCertificate = try certificateData(expiredIdentity)
        try keychain.seedActive(expiredIdentity)
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )

        await #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try await provisioner.loadOrCreate()
        }

        let preserved = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try certificateData(preserved) == priorCertificate)
        #expect(keychain.identityCount == 1)
    }

    @Test func readOnlyProviderFailsClosedForExpiredActiveIdentity() throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let expired = try X509CertificateBuilder(
            now: { utcProvisionerTestDate("20000101000000Z") }
        ).build()
        let expiredIdentity = try MemoryOnlyPKCS12Identity.make(
            privateKey: expired.privateKey,
            certificate: expired.certificate
        )
        try keychain.seedActive(expiredIdentity)
        let provider = KeychainTLSIdentityProvider(keychain: keychain)

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try provider.loadIdentity()
        }
    }

    @Test func finalInsertionFailureRestoresPriorIdentityAndReportsRotationFailure() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        let first = try await provisioner.loadOrCreate()
        keychain.failNextFinalInsertion = true

        await #expect(throws: TLSIdentityProvisionerError.rotationFailed) {
            _ = try await provisioner.rotate()
        }

        let active = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try TLSIdentityValidator().validate(active).publicKeySHA256 == first.publicKeySHA256)
        #expect(keychain.identityCount == 1)
    }

    @Test func priorRestoreFailureReturnsDistinctRecoveryFailure() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        _ = try await provisioner.loadOrCreate()
        keychain.failNextFinalInsertion = true
        keychain.failRestoreInsertion = true

        await #expect(throws: TLSIdentityProvisionerError.recoveryFailed) {
            _ = try await provisioner.rotate()
        }
    }

    @Test func firstRotationPromotionFailureReturnsRecoveryFailureWhenNoPriorIdentityExists() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        keychain.failNextActiveInsertion = true
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )

        await #expect(throws: TLSIdentityProvisionerError.recoveryFailed) {
            _ = try await provisioner.rotate()
        }

        #expect(keychain.identityCount == 0)
    }

    @Test func successfulFinalInsertionWithStageCleanupFailureKeepsNewActiveAndReportsCleanup() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        let provisioner = TLSIdentityProvisioner(
            keychain: keychain,
            mutationLock: RecordingTLSIdentityMutationLock()
        )
        let first = try await provisioner.loadOrCreate()
        keychain.failStagedRemoval = true

        await #expect(throws: TLSIdentityProvisionerError.stagedCleanupFailed) {
            _ = try await provisioner.rotate()
        }

        let active = try #require(try keychain.load(label: TLSIdentityProvisioner.defaultLabel))
        #expect(try TLSIdentityValidator().validate(active).publicKeySHA256 != first.publicKeySHA256)
    }

    @Test func twoProvisionersShareOneWholeTransactionLockAndPreserveOneIdentity() async throws {
        let keychain = InMemoryTLSIdentityKeychain(insertDelayMicroseconds: 20_000)
        let mutationLock = RecordingTLSIdentityMutationLock()
        let first = TLSIdentityProvisioner(keychain: keychain, mutationLock: mutationLock)
        let second = TLSIdentityProvisioner(keychain: keychain, mutationLock: mutationLock)

        async let firstIdentity = first.loadOrCreate()
        async let secondIdentity = second.loadOrCreate()
        let (one, two) = try await (firstIdentity, secondIdentity)

        #expect(one.publicKeySHA256 == two.publicKeySHA256)
        #expect(keychain.identityCount == 1)
        #expect(mutationLock.maximumConcurrentTransactions == 1)
    }

    @Test func provisioningErrorsNeverDescribePrivateKeyMaterial() async throws {
        let keychain = InMemoryTLSIdentityKeychain()
        keychain.failEveryInsertion = true
        do {
            _ = try await TLSIdentityProvisioner(
                keychain: keychain,
                mutationLock: RecordingTLSIdentityMutationLock()
            ).loadOrCreate()
            Issue.record("expected provisioning to fail")
        } catch {
            let privateBytes = try #require(keychain.lastRejectedPrivateKeyBytes)
            let description = String(describing: error)
            #expect(!description.contains(privateBytes.base64EncodedString()))
            #expect(!description.contains(privateBytes.map { String(format: "%02x", $0) }.joined()))
        }
    }
}

private final class RecordingTLSIdentityMutationLock: TLSIdentityMutationLock, @unchecked Sendable {
    private let lock = NSLock()
    private let stateLock = NSLock()
    private var active = 0
    private var maximum = 0
    var maximumConcurrentTransactions: Int { stateLock.withLock { maximum } }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        stateLock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
        defer {
            stateLock.withLock { active -= 1 }
            lock.unlock()
        }
        return try operation()
    }
}

private final class InMemoryTLSIdentityKeychain: TLSIdentityKeychain, @unchecked Sendable {
    enum Failure: Error { case injected }
    private enum InsertAction { case normal, invalidIdentity, fail }

    private let lock = NSLock()
    private let insertDelayMicroseconds: useconds_t
    private var identities: [String: SecIdentity] = [:]
    private var identityByCertificate: [Data: SecIdentity] = [:]
    private var recordedOperations: [String] = []
    private var activeInsertCount = 0
    private var awaitingRestore = false
    var returnsInvalidIdentityForNextStage = false
    var failStagedRemoval = false
    var failActiveRemoval = false
    var partiallyRemoveActiveThenFailOnce = false
    var failNextFinalInsertion = false
    var failNextActiveInsertion = false
    var failRestoreInsertion = false
    var failEveryInsertion = false
    private(set) var lastRejectedPrivateKeyBytes: Data?

    init(insertDelayMicroseconds: useconds_t = 0) {
        self.insertDelayMicroseconds = insertDelayMicroseconds
    }

    var identityCount: Int { lock.withLock { identities.count } }
    var operations: [String] { lock.withLock { recordedOperations } }

    func seedActive(_ identity: SecIdentity) throws {
        let data = try certificateData(identity)
        lock.withLock {
            identities[TLSIdentityProvisioner.defaultLabel] = identity
            identityByCertificate[data] = identity
            activeInsertCount = 1
        }
    }

    func load(label: String) throws -> SecIdentity? {
        lock.withLock {
            recordedOperations.append("load:\(label == TLSIdentityProvisioner.defaultLabel ? "active" : "staged")")
            return identities[label]
        }
    }

    func insert(privateKey: SecKey, certificate: SecCertificate, label: String) throws -> SecIdentity {
        if insertDelayMicroseconds > 0 { usleep(insertDelayMicroseconds) }
        let isActive = label == TLSIdentityProvisioner.defaultLabel
        let action = lock.withLock { () -> InsertAction in
            recordedOperations.append("insert:\(isActive ? "active" : "staged")")
            if isActive { activeInsertCount += 1 }
            if failEveryInsertion {
                lastRejectedPrivateKeyBytes = SecKeyCopyExternalRepresentation(privateKey, nil) as Data?
                return .fail
            }
            if !isActive, returnsInvalidIdentityForNextStage {
                returnsInvalidIdentityForNextStage = false
                return .invalidIdentity
            }
            if isActive, awaitingRestore {
                if failRestoreInsertion { return .fail }
                awaitingRestore = false
                return .normal
            }
            if isActive, failNextActiveInsertion {
                failNextActiveInsertion = false
                return .fail
            }
            if isActive, activeInsertCount > 1, failNextFinalInsertion {
                failNextFinalInsertion = false
                awaitingRestore = true
                return .fail
            }
            return .normal
        }
        if action == .fail { throw Failure.injected }
        if action == .invalidIdentity {
            let invalid = try MemoryOnlyPKCS12Identity.makeRSAFixture()
            lock.withLock { identities[label] = invalid }
            return invalid
        }

        let certificateData = SecCertificateCopyData(certificate) as Data
        if let cached = lock.withLock({ identityByCertificate[certificateData] }) {
            lock.withLock { identities[label] = cached }
            return cached
        }
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: privateKey,
            certificate: certificate
        )
        lock.withLock {
            identityByCertificate[certificateData] = identity
            identities[label] = identity
        }
        return identity
    }

    func remove(label: String) throws {
        let isActive = label == TLSIdentityProvisioner.defaultLabel
        try lock.withLock {
            recordedOperations.append("remove:\(isActive ? "active" : "staged")")
            if isActive, partiallyRemoveActiveThenFailOnce {
                partiallyRemoveActiveThenFailOnce = false
                awaitingRestore = true
                identities.removeValue(forKey: label)
                throw Failure.injected
            }
            if isActive, failActiveRemoval { throw Failure.injected }
            if !isActive, failStagedRemoval { throw Failure.injected }
            identities.removeValue(forKey: label)
        }
    }
}

private func certificateData(_ identity: SecIdentity) throws -> Data {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
          let certificate
    else { throw TLSIdentityProvisionerError.invalidIdentity }
    return SecCertificateCopyData(certificate) as Data
}

private func publicKeyData(_ identity: SecIdentity) throws -> Data {
    var privateKey: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
          let privateKey,
          let publicKey = SecKeyCopyPublicKey(privateKey),
          let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    else { throw TLSIdentityProvisionerError.invalidIdentity }
    return bytes
}

private func utcProvisionerTestDate(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    return formatter.date(from: value)!
}
