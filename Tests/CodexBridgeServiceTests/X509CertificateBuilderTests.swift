@testable import CodexBridgeService
import Foundation
import Security
import Testing

@Suite struct X509CertificateBuilderTests {
    @Test func generatedCertificateUsesTheGeneratedP256KeyAndVerifiableSHA256Signature() throws {
        let generated = try X509CertificateBuilder(
            now: { Date(timeIntervalSince1970: 2_208_988_800) },
            randomBytes: { Data(repeating: 0x2a, count: $0) }
        ).build()
        let parsed = try ParsedCertificate(generated.derRepresentation)
        let certificateKey = try #require(SecCertificateCopyKey(generated.certificate))
        let generatedPublicKey = try #require(SecKeyCopyPublicKey(generated.privateKey))

        #expect(try externalRepresentation(certificateKey) == externalRepresentation(generatedPublicKey))
        #expect(SecKeyVerifySignature(
            certificateKey,
            .ecdsaSignatureMessageX962SHA256,
            parsed.tbs.encoded as CFData,
            parsed.signature as CFData,
            nil
        ))
    }

    @Test func validityUsesRFC5280TimeTagsAndParsedDatesBracketTheClockForTenYears() throws {
        let now = utcDate("20400101000000Z", format: "yyyyMMddHHmmss'Z'")
        let parsed = try ParsedCertificate(X509CertificateBuilder(
            now: { now },
            randomBytes: { Data(repeating: 0x31, count: $0) }
        ).build().derRepresentation)

        #expect(parsed.notBefore.tag == 0x17)
        #expect(parsed.notAfter.tag == 0x18)
        let decodedNotBefore = try parsedTime(parsed.notBefore)
        let decodedNotAfter = try parsedTime(parsed.notAfter)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(decodedNotBefore <= now)
        #expect(decodedNotAfter == calendar.date(byAdding: .year, value: 10, to: decodedNotBefore))
    }

    @Test func serialIsPositiveNonzeroAndChangesWithInjectedRandomness() throws {
        let now = Date(timeIntervalSince1970: 2_208_988_800)
        let first = try ParsedCertificate(X509CertificateBuilder(
            now: { now },
            randomBytes: { Data(repeating: 0x11, count: $0) }
        ).build().derRepresentation)
        let second = try ParsedCertificate(X509CertificateBuilder(
            now: { now },
            randomBytes: { Data(repeating: 0x22, count: $0) }
        ).build().derRepresentation)

        #expect(first.serial.value != second.serial.value)
        #expect(first.serial.value.contains(where: { $0 != 0 }))
        #expect(first.serial.value.first.map { $0 & 0x80 == 0 } == true)
    }

    @Test func extensionsEncodeCriticalDigitalSignatureAndServerAuthentication() throws {
        let parsed = try ParsedCertificate(X509CertificateBuilder(
            now: { Date(timeIntervalSince1970: 2_208_988_800) },
            randomBytes: { Data(repeating: 0x42, count: $0) }
        ).build().derRepresentation)
        let keyUsage = try #require(parsed.extensions["2.5.29.15"])
        let extendedKeyUsage = try #require(parsed.extensions["2.5.29.37"])
        var keyUsageReader = DERTestReader(keyUsage.value)
        let keyUsageBits = try keyUsageReader.read(expectedTag: 0x03)
        var ekuContainer = DERTestReader(extendedKeyUsage.value)
        var ekuReader = DERTestReader(try ekuContainer.read(expectedTag: 0x30).value)
        var ekuOIDs: [String] = []
        while !ekuReader.isAtEnd { ekuOIDs.append(try decodeOID(ekuReader.read(expectedTag: 0x06).value)) }

        #expect(keyUsage.critical)
        #expect(keyUsageBits.value == Data([7, 0x80]))
        #expect(!extendedKeyUsage.critical)
        #expect(ekuOIDs == ["1.3.6.1.5.5.7.3.1"])
    }
}

private struct ParsedExtension {
    let critical: Bool
    let value: Data
}

private struct ParsedCertificate {
    let tbs: DERTestValue
    let signature: Data
    let serial: DERTestValue
    let notBefore: DERTestValue
    let notAfter: DERTestValue
    let extensions: [String: ParsedExtension]

    init(_ data: Data) throws {
        var certificateReader = DERTestReader(data)
        let certificate = try certificateReader.read(expectedTag: 0x30)
        #expect(certificateReader.isAtEnd)
        var outer = DERTestReader(certificate.value)
        tbs = try outer.read(expectedTag: 0x30)
        _ = try outer.read(expectedTag: 0x30)
        let signatureBits = try outer.read(expectedTag: 0x03).value
        guard signatureBits.first == 0 else { throw DERTestError.invalid }
        signature = Data(signatureBits.dropFirst())

        var fields = DERTestReader(tbs.value)
        _ = try fields.read(expectedTag: 0xa0)
        serial = try fields.read(expectedTag: 0x02)
        _ = try fields.read(expectedTag: 0x30)
        _ = try fields.read(expectedTag: 0x30)
        var validity = DERTestReader(try fields.read(expectedTag: 0x30).value)
        notBefore = try validity.read()
        notAfter = try validity.read()
        _ = try fields.read(expectedTag: 0x30)
        _ = try fields.read(expectedTag: 0x30)
        let extensionWrapper = try fields.read(expectedTag: 0xa3)
        var extensionSequence = DERTestReader(extensionWrapper.value)
        var entries = DERTestReader(try extensionSequence.read(expectedTag: 0x30).value)
        var parsed: [String: ParsedExtension] = [:]
        while !entries.isAtEnd {
            var entry = DERTestReader(try entries.read(expectedTag: 0x30).value)
            let oid = try decodeOID(entry.read(expectedTag: 0x06).value)
            var critical = false
            if entry.peekTag == 0x01 {
                critical = try entry.read(expectedTag: 0x01).value == Data([0xff])
            }
            parsed[oid] = ParsedExtension(
                critical: critical,
                value: try entry.read(expectedTag: 0x04).value
            )
        }
        extensions = parsed
    }
}

private struct DERTestValue {
    let tag: UInt8
    let value: Data
    let encoded: Data
}

private enum DERTestError: Error { case invalid }

private struct DERTestReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }
    var peekTag: UInt8? { offset < data.count ? data[offset] : nil }

    mutating func read(expectedTag: UInt8? = nil) throws -> DERTestValue {
        let start = offset
        guard offset < data.count else { throw DERTestError.invalid }
        let tag = data[offset]
        offset += 1
        guard expectedTag == nil || tag == expectedTag else { throw DERTestError.invalid }
        guard offset < data.count else { throw DERTestError.invalid }
        let firstLength = data[offset]
        offset += 1
        let length: Int
        if firstLength & 0x80 == 0 {
            length = Int(firstLength)
        } else {
            let byteCount = Int(firstLength & 0x7f)
            guard byteCount > 0, byteCount <= 4, offset + byteCount <= data.count else {
                throw DERTestError.invalid
            }
            var accumulated = 0
            for _ in 0 ..< byteCount {
                accumulated = accumulated << 8 | Int(data[offset])
                offset += 1
            }
            length = accumulated
        }
        guard offset + length <= data.count else { throw DERTestError.invalid }
        let value = data.subdata(in: offset ..< offset + length)
        offset += length
        return DERTestValue(tag: tag, value: value, encoded: data.subdata(in: start ..< offset))
    }
}

private func decodeOID(_ data: Data) throws -> String {
    guard let first = data.first else { throw DERTestError.invalid }
    var parts = [UInt64(first / 40), UInt64(first % 40)]
    var value: UInt64 = 0
    for byte in data.dropFirst() {
        value = value << 7 | UInt64(byte & 0x7f)
        if byte & 0x80 == 0 {
            parts.append(value)
            value = 0
        }
    }
    guard value == 0 else { throw DERTestError.invalid }
    return parts.map(String.init).joined(separator: ".")
}

private func parsedTime(_ value: DERTestValue) throws -> Date {
    let string = String(decoding: value.value, as: UTF8.self)
    switch value.tag {
    case 0x17: return utcDate(string, format: "yyMMddHHmmss'Z'")
    case 0x18: return utcDate(string, format: "yyyyMMddHHmmss'Z'")
    default: throw DERTestError.invalid
    }
}

private func utcDate(_ value: String, format: String) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter.date(from: value)!
}

private func externalRepresentation(_ key: SecKey) throws -> Data {
    var error: Unmanaged<CFError>?
    let data = SecKeyCopyExternalRepresentation(key, &error) as Data?
    if let error { throw error.takeRetainedValue() }
    return try #require(data)
}
