import Foundation
import Security

enum X509CertificateBuilderError: Error, Equatable, Sendable {
    case keyGenerationFailed
    case publicKeyUnavailable
    case randomnessUnavailable
    case signingFailed
    case invalidCertificate
}

struct GeneratedX509Certificate: @unchecked Sendable {
    let privateKey: SecKey
    let certificate: SecCertificate
    let derRepresentation: Data
    let tbsCertificate: Data
    let signature: Data
    let notBefore: Date
    let notAfter: Date
}

struct X509CertificateBuilder: @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) throws -> Data
    private let includesDigitalSignature: Bool
    private let includesServerAuthentication: Bool
    private let certificateSigningKey: SecKey?

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        randomBytes: @escaping @Sendable (Int) throws -> Data = Self.secureRandomBytes,
        includesDigitalSignature: Bool = true,
        includesServerAuthentication: Bool = true,
        certificateSigningKey: SecKey? = nil
    ) {
        self.now = now
        self.randomBytes = randomBytes
        self.includesDigitalSignature = includesDigitalSignature
        self.includesServerAuthentication = includesServerAuthentication
        self.certificateSigningKey = certificateSigningKey
    }

    func build() throws -> GeneratedX509Certificate {
        var keyError: Unmanaged<CFError>?
        let keyAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              publicKeyBytes.count == 65,
              publicKeyBytes.first == 0x04
        else {
            throw keyError == nil
                ? X509CertificateBuilderError.publicKeyUnavailable
                : X509CertificateBuilderError.keyGenerationFailed
        }

        let notBefore = Date(timeIntervalSince1970: floor(now().timeIntervalSince1970))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let notAfter = calendar.date(byAdding: .year, value: 10, to: notBefore) else {
            throw X509CertificateBuilderError.invalidCertificate
        }
        let signatureAlgorithm = DER.sequence([
            try DER.objectIdentifier("1.2.840.10045.4.3.2"),
        ])
        let commonName = DER.sequence([
            DER.set([
                DER.sequence([
                    try DER.objectIdentifier("2.5.4.3"),
                    DER.utf8String("Voice Inbox Bridge"),
                ]),
            ]),
        ])
        var serial = try randomBytes(20)
        guard serial.count == 20 else { throw X509CertificateBuilderError.randomnessUnavailable }
        serial[serial.startIndex] &= 0x7f
        if serial.allSatisfy({ $0 == 0 }) { serial[serial.startIndex] = 1 }

        let subjectPublicKeyInfo = DER.sequence([
            DER.sequence([
                try DER.objectIdentifier("1.2.840.10045.2.1"),
                try DER.objectIdentifier("1.2.840.10045.3.1.7"),
            ]),
            DER.bitString(publicKeyBytes),
        ])
        let keyUsage = DER.sequence([
            try DER.objectIdentifier("2.5.29.15"),
            DER.boolean(true),
            DER.octetString(
                includesDigitalSignature
                    ? DER.bitString(Data([0x80]), unusedBits: 7)
                    : DER.bitString(Data([0x20]), unusedBits: 5)
            ),
        ])
        let extendedKeyUsage = DER.sequence([
            try DER.objectIdentifier("2.5.29.37"),
            DER.octetString(DER.sequence([
                try DER.objectIdentifier(
                    includesServerAuthentication
                        ? "1.3.6.1.5.5.7.3.1"
                        : "1.3.6.1.5.5.7.3.2"
                ),
            ])),
        ])
        let tbsCertificate = DER.sequence([
            DER.contextSpecific(0, DER.integer(Data([2]))),
            DER.integer(serial),
            signatureAlgorithm,
            commonName,
            DER.sequence([
                DER.time(notBefore),
                DER.time(notAfter),
            ]),
            commonName,
            subjectPublicKeyInfo,
            DER.contextSpecific(3, DER.sequence([keyUsage, extendedKeyUsage])),
        ])

        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            certificateSigningKey ?? privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsCertificate as CFData,
            &signatureError
        ) as Data? else {
            throw X509CertificateBuilderError.signingFailed
        }
        let certificateDER = DER.sequence([
            tbsCertificate,
            signatureAlgorithm,
            DER.bitString(signature),
        ])
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              SecCertificateCopyKey(certificate) != nil
        else { throw X509CertificateBuilderError.invalidCertificate }

        return GeneratedX509Certificate(
            privateKey: privateKey,
            certificate: certificate,
            derRepresentation: certificateDER,
            tbsCertificate: tbsCertificate,
            signature: signature,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw X509CertificateBuilderError.randomnessUnavailable }
        var bytes = Data(repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw X509CertificateBuilderError.randomnessUnavailable
        }
        return bytes
    }
}

private enum DER {
    static func sequence(_ values: [Data]) -> Data { tagged(0x30, values.reduce(into: Data(), +=)) }
    static func set(_ values: [Data]) -> Data { tagged(0x31, values.reduce(into: Data(), +=)) }
    static func integer(_ value: Data) -> Data {
        var normalized = value.drop(while: { $0 == 0 })
        if normalized.isEmpty { normalized = Data([0])[...] }
        var body = Data(normalized)
        if body[body.startIndex] & 0x80 != 0 { body.insert(0, at: body.startIndex) }
        return tagged(0x02, body)
    }
    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xff : 0x00])) }
    static func utf8String(_ value: String) -> Data { tagged(0x0c, Data(value.utf8)) }
    static func octetString(_ value: Data) -> Data { tagged(0x04, value) }
    static func bitString(_ value: Data, unusedBits: UInt8 = 0) -> Data {
        tagged(0x03, Data([unusedBits]) + value)
    }
    static func contextSpecific(_ number: UInt8, _ value: Data) -> Data {
        tagged(0xa0 | number, value)
    }
    static func time(_ value: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let usesUTCTime = calendar.component(.year, from: value) <= 2049
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = usesUTCTime ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tagged(usesUTCTime ? 0x17 : 0x18, Data(formatter.string(from: value).utf8))
    }

    static func objectIdentifier(_ value: String) throws -> Data {
        let parts = value.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2,
              parts[0] <= 2,
              parts[1] <= (parts[0] < 2 ? 39 : UInt64.max)
        else { throw X509CertificateBuilderError.invalidCertificate }
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
        return tagged(0x06, body)
    }

    private static func tagged(_ tag: UInt8, _ body: Data) -> Data {
        Data([tag]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
