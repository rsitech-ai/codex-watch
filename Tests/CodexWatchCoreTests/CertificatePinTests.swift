@testable import CodexWatchCore
import Testing

@Test func certificatePinNormalizesCommonFingerprintFormatting() throws {
    let formatted = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:" +
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"

    let pin = try CertificatePin(formatted)

    #expect(pin.rawValue == "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")
}

@Test(arguments: [
    "",
    "abcd",
    String(repeating: "g", count: 64),
    String(repeating: "a", count: 63),
    String(repeating: "a", count: 65),
])
func certificatePinRejectsMalformedFingerprints(_ raw: String) {
    #expect(throws: CertificatePinError.invalidFingerprint) {
        _ = try CertificatePin(raw)
    }
}

@Test func candidateCertificatePhraseIsStableAndContentFree() throws {
    let pin = try CertificatePin("0011223344556677" + String(repeating: "a", count: 48))

    #expect(pin.comparisonPhrase == [
        "amber-amber", "birch-birch", "coral-coral", "dune-dune",
        "ember-ember", "fern-fern", "glacier-glacier", "harbor-harbor",
    ].joined(separator: " "))
    #expect(!pin.comparisonPhrase.contains(pin.rawValue))
}

@Test func certificatePhraseAuthenticatesAtLeastSixtyFourBits() throws {
    let commonPrefix = "0011223344556677"
    let first = try CertificatePin(commonPrefix + String(repeating: "a", count: 48))
    let sameSixtyFourBits = try CertificatePin(commonPrefix + String(repeating: "b", count: 48))
    let differentSixtyFourthBit = try CertificatePin("0011223344556676" + String(repeating: "a", count: 48))

    #expect(first.comparisonPhrase == sameSixtyFourBits.comparisonPhrase)
    #expect(first.comparisonPhrase != differentSixtyFourthBit.comparisonPhrase)
}

@Test func certificateTrustRejectsBeforeConfirmationAndAcceptsOnlyExactPin() throws {
    let candidate = try CertificatePin(String(repeating: "a", count: 64))
    let other = try CertificatePin(String(repeating: "b", count: 64))

    #expect(CertificatePinTrust.evaluate(candidate: candidate, confirmed: nil) == .rejectUnconfirmed)
    let confirmed = candidate.confirmedByUser()
    #expect(CertificatePinTrust.evaluate(candidate: candidate, confirmed: confirmed) == .accept)
    #expect(CertificatePinTrust.evaluate(candidate: other, confirmed: confirmed) == .rejectMismatch)
}
