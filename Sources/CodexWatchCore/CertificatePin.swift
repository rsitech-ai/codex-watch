import Foundation

public enum CertificatePinError: Error, Equatable, Sendable {
    case invalidFingerprint
}

public struct CertificatePin: RawRepresentable, Codable, Hashable, Sendable {
    private static let phraseWords = [
        "amber", "birch", "coral", "dune",
        "ember", "fern", "glacier", "harbor",
        "iris", "juniper", "kelp", "lunar",
        "maple", "nova", "opal", "pine",
    ]

    public let rawValue: String

    public init(_ rawValue: String) throws {
        var normalized = ""
        normalized.reserveCapacity(64)
        for byte in rawValue.utf8 {
            switch byte {
            case 48 ... 57, 97 ... 102:
                normalized.append(Character(UnicodeScalar(byte)))
            case 65 ... 70:
                normalized.append(Character(UnicodeScalar(byte + 32)))
            case 32, 45, 58:
                continue
            default:
                throw CertificatePinError.invalidFingerprint
            }
        }
        guard normalized.utf8.count == 64 else {
            throw CertificatePinError.invalidFingerprint
        }
        self.rawValue = normalized
    }

    public init?(rawValue: String) {
        try? self.init(rawValue)
    }

    public var comparisonPhrase: String {
        // Authenticate 64 bits through the user-compared phrase. The full
        // 256-bit value remains the TLS pin after confirmation.
        let nibbles = rawValue.utf8.prefix(16).map(Self.nibble)
        return stride(from: 0, to: nibbles.count, by: 2).map { index in
            "\(Self.phraseWords[nibbles[index]])-\(Self.phraseWords[nibbles[index + 1]])"
        }.joined(separator: " ")
    }

    public func confirmedByUser() -> ConfirmedCertificatePin {
        ConfirmedCertificatePin(pin: self)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Certificate pin must be a SHA-256 fingerprint"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func nibble(_ byte: UInt8) -> Int {
        switch byte {
        case 48 ... 57: Int(byte - 48)
        default: Int(byte - 87)
        }
    }
}

public struct ConfirmedCertificatePin: Equatable, Sendable {
    public let pin: CertificatePin

    fileprivate init(pin: CertificatePin) {
        self.pin = pin
    }
}

public enum CertificatePinTrustDecision: Equatable, Sendable {
    case accept
    case rejectUnconfirmed
    case rejectMismatch
}

public enum CertificatePinTrust {
    public static func evaluate(
        candidate: CertificatePin,
        confirmed: ConfirmedCertificatePin?
    ) -> CertificatePinTrustDecision {
        guard let confirmed else { return .rejectUnconfirmed }
        return candidate == confirmed.pin ? .accept : .rejectMismatch
    }
}
