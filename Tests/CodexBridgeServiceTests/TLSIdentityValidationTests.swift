@testable import CodexBridgeService
import CryptoKit
import Foundation
import Security
import Testing

@Suite(.serialized) struct TLSIdentitySecurityTests {}

extension TLSIdentitySecurityTests {
    private var now: Date { utcValidationDate("20400101000000Z") }

    @Test func fixtureImportRetriesTransientFailuresWithinItsBound() throws {
        var attempts = 0
        var delayedAttempts: [Int] = []

        let value: Int = try MemoryOnlyPKCS12Identity.retryImport(
            maxAttempts: 3,
            delay: { delayedAttempts.append($0) }
        ) {
            attempts += 1
            if attempts < 3 { throw MemoryOnlyPKCS12Identity.FixtureError.importFailed }
            return 42
        }

        #expect(value == 42)
        #expect(attempts == 3)
        #expect(delayedAttempts == [1, 2])
    }

    @Test func fixtureImportStopsAtItsRetryBound() {
        var attempts = 0

        #expect(throws: MemoryOnlyPKCS12Identity.FixtureError.importFailed) {
            _ = try MemoryOnlyPKCS12Identity.retryImport(
                maxAttempts: 3,
                delay: { _ in }
            ) {
                attempts += 1
                throw MemoryOnlyPKCS12Identity.FixtureError.importFailed
            } as Int
        }
        #expect(attempts == 3)
    }

    @Test func validatorAcceptsCurrentSelfSignedP256ServerIdentityAndMatchesItsPublicKey() throws {
        let generated = try X509CertificateBuilder(now: { now }).build()
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: generated.privateKey,
            certificate: generated.certificate
        )
        let validated = try TLSIdentityValidator(now: { now }).validate(identity)
        let publicKey = try #require(SecKeyCopyPublicKey(generated.privateKey))
        let publicBytes = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let expected = SHA256.hash(data: publicBytes).map { String(format: "%02x", $0) }.joined()

        #expect(validated.publicKeySHA256 == expected)
        #expect(SecCertificateCopyData(validated.certificate) == SecCertificateCopyData(generated.certificate))
    }

    @Test func validatorRejectsExpiredIdentity() throws {
        let expiredAt = utcValidationDate("20200101000000Z")
        let generated = try X509CertificateBuilder(now: { expiredAt }).build()
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: generated.privateKey,
            certificate: generated.certificate
        )

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator(now: { now }).validate(identity)
        }
    }

    @Test func validatorRejectsWrongKeyUsage() throws {
        let generated = try X509CertificateBuilder(
            now: { now },
            includesDigitalSignature: false
        ).build()
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: generated.privateKey,
            certificate: generated.certificate
        )

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator(now: { now }).validate(identity)
        }
    }

    @Test func validatorRejectsWrongExtendedKeyUsage() throws {
        let generated = try X509CertificateBuilder(
            now: { now },
            includesServerAuthentication: false
        ).build()
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: generated.privateKey,
            certificate: generated.certificate
        )

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator(now: { now }).validate(identity)
        }
    }

    @Test func validatorRejectsCertificateNotSignedByItsOwnKey() throws {
        let issuer = try X509CertificateBuilder(now: { now }).build().privateKey
        let generated = try X509CertificateBuilder(
            now: { now },
            certificateSigningKey: issuer
        ).build()
        let identity = try MemoryOnlyPKCS12Identity.make(
            privateKey: generated.privateKey,
            certificate: generated.certificate
        )

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator(now: { now }).validate(identity)
        }
    }

    @Test func validatorRejectsRSAIdentityEvenWithServerProfile() throws {
        let identity = try MemoryOnlyPKCS12Identity.makeRSAFixture()

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try TLSIdentityValidator(now: Date.init).validate(identity)
        }
    }

    @Test func pkcs12IdentityExtractionDoesNotBridgeUnrelatedDictionaryEntries() throws {
        let identity = try MemoryOnlyPKCS12Identity.makeRSAFixture()
        let item = NSMutableDictionary()
        item[kSecImportItemIdentity as String] = identity
        item[NSNumber(value: 7)] = "unrelated-non-string-key"
        let imported = [item] as CFArray

        #expect((imported as? [[String: Any]]) == nil)
        let extracted = try PKCS12TLSIdentityProvider.extractIdentity(from: imported)
        #expect(CFEqual(extracted, identity))
    }

    @Test func parserRequiresCanonicalV3VersionInteger() throws {
        try X509IdentityProfile.validateVersion(Data([0x02, 0x01, 0x02]))

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            try X509IdentityProfile.validateVersion(Data([0x02, 0x01, 0x01]))
        }
        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            try X509IdentityProfile.validateVersion(Data([0x02, 0x02, 0x00, 0x02]))
        }
    }

    @Test func parserRequiresCanonicalPositiveNonzeroSerialAtMostTwentyOctets() throws {
        try X509IdentityProfile.validateSerial(Data([0x01]))
        try X509IdentityProfile.validateSerial(Data([0x00, 0x80]))

        for invalid in [
            Data(),
            Data([0x00]),
            Data([0x80]),
            Data([0x00, 0x7f]),
            Data(repeating: 0x01, count: 21),
        ] {
            #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
                try X509IdentityProfile.validateSerial(invalid)
            }
        }
    }

    @Test func parserRejectsNonminimalUnterminatedAndOverflowingBase128OIDs() throws {
        #expect(try X509IdentityProfile.decodeOID(Data([0x2a, 0x86, 0x48])) == "1.2.840")

        for invalid in [
            Data([0x80, 0x2a]),
            Data([0x2a, 0x80, 0x01]),
            Data([0x2a, 0x80]),
            Data([0x2a] + Array(repeating: 0xff, count: 10) + [0x7f]),
        ] {
            #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
                _ = try X509IdentityProfile.decodeOID(invalid)
            }
        }
    }

    @Test func parserEnforcesRFC5280YearToTimeTagSelection() throws {
        #expect(try X509IdentityProfile.decodeTime(tag: 0x17, raw: "491231235959Z")
            == utcValidationDate("20491231235959Z"))
        #expect(try X509IdentityProfile.decodeTime(tag: 0x18, raw: "20500101000000Z")
            == utcValidationDate("20500101000000Z"))

        for value in [
            (UInt8(0x18), "20491231235959Z"),
            (UInt8(0x18), "19491231235959Z"),
            (UInt8(0x17), "490230000000Z"),
            (UInt8(0x17), "491231235959+0000"),
        ] {
            #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
                _ = try X509IdentityProfile.decodeTime(tag: value.0, raw: value.1)
            }
        }
    }

    @Test func parserRejectsDuplicateAndUnknownCriticalExtensions() throws {
        let keyUsage = testExtension(
            oid: [2, 5, 29, 15],
            critical: true,
            value: testDERTagged(0x03, Data([7, 0x80]))
        )
        let unknownCritical = testExtension(
            oid: [1, 2, 3, 4],
            critical: true,
            value: Data([0x05, 0x00])
        )
        let unknownNoncritical = testExtension(
            oid: [1, 2, 3, 5],
            critical: false,
            value: Data([0x05, 0x00])
        )

        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try X509IdentityProfile.parseExtensions(keyUsage + keyUsage)
        }
        #expect(throws: TLSIdentityProvisionerError.invalidIdentity) {
            _ = try X509IdentityProfile.parseExtensions(keyUsage + unknownCritical)
        }
        _ = try X509IdentityProfile.parseExtensions(keyUsage + unknownNoncritical)
    }
}

enum MemoryOnlyPKCS12Identity {
    enum FixtureError: Error, Equatable { case invalidKey, commandFailed(String), importFailed }

    static func retryImport<T>(
        maxAttempts: Int = 5,
        delay: (Int) -> Void = { attempt in
            Thread.sleep(forTimeInterval: 0.25 * Double(attempt))
        },
        _ operation: () throws -> T
    ) throws -> T {
        guard maxAttempts > 0 else { throw FixtureError.importFailed }
        var attempt = 1
        while true {
            do { return try operation() }
            catch {
                guard attempt < maxAttempts else { throw error }
                delay(attempt)
                attempt += 1
            }
        }
    }

    static func make(privateKey: SecKey, certificate: SecCertificate) throws -> SecIdentity {
        let privateBytes = try #require(SecKeyCopyExternalRepresentation(privateKey, nil) as Data?)
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let publicBytes = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let scalar: Data
        if privateBytes.count == 32 {
            scalar = privateBytes
        } else if privateBytes.count >= 32 {
            scalar = Data(privateBytes.suffix(32))
        } else {
            throw FixtureError.invalidKey
        }
        let sec1 = testDERSequence([
            testDERInteger(Data([1])),
            testDERTagged(0x04, scalar),
            testDERTagged(0xa0, testDEROID([1, 2, 840, 10045, 3, 1, 7])),
            testDERTagged(0xa1, testDERTagged(0x03, Data([0]) + publicBytes)),
        ])
        return try importFixture(
            privateKeyPEM: pem("EC PRIVATE KEY", sec1),
            certificatePEM: pem("CERTIFICATE", SecCertificateCopyData(certificate) as Data)
        )
    }

    static func makeRSAFixture() throws -> SecIdentity {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appending(path: "fixture-key.pem")
        let certificate = root.appending(path: "fixture-certificate.pem")
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", key.path, "-out", certificate.path, "-days", "1",
            "-subj", "/CN=invalid-rsa-fixture",
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=serverAuth",
        ])
        return try importFixture(
            privateKeyPEM: try Data(contentsOf: key),
            certificatePEM: try Data(contentsOf: certificate)
        )
    }

    private static func importFixture(
        privateKeyPEM: Data,
        certificatePEM: Data
    ) throws -> SecIdentity {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appending(path: "fixture-key.pem")
        let certificate = root.appending(path: "fixture-certificate.pem")
        let archive = root.appending(path: "fixture.p12")
        let password = UUID().uuidString
        try privateKeyPEM.write(to: key, options: .atomic)
        try certificatePEM.write(to: certificate, options: .atomic)
        try runOpenSSL([
            "pkcs12", "-export", "-out", archive.path, "-inkey", key.path,
            "-in", certificate.path, "-passout", "pass:\(password)",
        ])
        let data = try Data(contentsOf: archive)
        do {
            return try retryImport {
                try PKCS12TLSIdentityProvider.importMemoryOnlyIdentity(
                    data: data,
                    password: password
                )
            }
        } catch {
            throw FixtureError.importFailed
        }
    }

    static func extractIdentity(from imported: CFArray?) throws -> SecIdentity {
        try PKCS12TLSIdentityProvider.extractIdentity(from: imported)
    }

    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "memory-only-p256-identity-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        return root
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.commandFailed(String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ))
        }
    }

    private static func pem(_ label: String, _ data: Data) -> Data {
        let encoded = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(encoded)\n-----END \(label)-----\n".utf8)
    }
}

private func testDERSequence(_ values: [Data]) -> Data {
    testDERTagged(0x30, values.reduce(into: Data(), +=))
}

private func testDERInteger(_ value: Data) -> Data { testDERTagged(0x02, value) }

private func testExtension(oid: [UInt64], critical: Bool, value: Data) -> Data {
    var fields = [testDEROID(oid)]
    if critical { fields.append(testDERTagged(0x01, Data([0xff]))) }
    fields.append(testDERTagged(0x04, value))
    return testDERSequence(fields)
}

private func testDEROID(_ parts: [UInt64]) -> Data {
    var body = Data([UInt8(parts[0] * 40 + parts[1])])
    for part in parts.dropFirst(2) {
        var encoded = [UInt8(part & 0x7f)]
        var remaining = part >> 7
        while remaining > 0 {
            encoded.insert(UInt8(remaining & 0x7f) | 0x80, at: 0)
            remaining >>= 7
        }
        body.append(contentsOf: encoded)
    }
    return testDERTagged(0x06, body)
}

private func testDERTagged(_ tag: UInt8, _ body: Data) -> Data {
    let length: Data
    if body.count < 128 {
        length = Data([UInt8(body.count)])
    } else {
        var count = body.count
        var bytes: [UInt8] = []
        while count > 0 {
            bytes.insert(UInt8(count & 0xff), at: 0)
            count >>= 8
        }
        length = Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    return Data([tag]) + length + body
}

private func utcValidationDate(_ value: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss'Z'"
    return formatter.date(from: value)!
}
