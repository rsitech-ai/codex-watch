import CryptoKit
import Foundation

public protocol SecretStore: Sendable {
    func readSecret(named name: String) async throws -> Data?
    func writeSecret(_ data: Data, named name: String) async throws
    func removeSecret(named name: String) async throws
}

public actor InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func readSecret(named name: String) -> Data? {
        values[name]
    }

    public func writeSecret(_ data: Data, named name: String) {
        values[name] = data
    }

    public func removeSecret(named name: String) {
        values[name] = nil
    }
}

public enum PairingError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidGeneratedCode
    case invalidGeneratedSecret
    case noActiveCode
    case invalidCode
    case expired
}

public struct PairingChallenge: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct PairingCredential: Equatable, Sendable {
    public let tokenHex: String
    let secret: Data

    init(secret: Data) throws {
        guard secret.count == 32 else { throw PairingError.invalidGeneratedSecret }
        self.secret = secret
        tokenHex = secret.map { String(format: "%02x", $0) }.joined()
    }
}

public actor PairingStore {
    private struct StoredChallenge: Codable {
        let digest: Data
        let expiresAt: Date
    }

    private static let challengeKey = "pairing.challenge.v1"
    private static let credentialKey = "pairing.credential.v1"

    private let secretStore: any SecretStore
    private let clock: @Sendable () -> Date
    private let codeGenerator: @Sendable () throws -> String
    private let tokenGenerator: @Sendable () throws -> Data

    public init(
        secretStore: any SecretStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        codeGenerator: (@Sendable () throws -> String)? = nil,
        tokenGenerator: (@Sendable () throws -> Data)? = nil
    ) throws {
        self.secretStore = secretStore
        self.clock = clock
        self.codeGenerator = codeGenerator ?? Self.randomCode
        self.tokenGenerator = tokenGenerator ?? Self.randomToken
    }

    public func beginPairing(validFor lifetime: TimeInterval) async throws -> PairingChallenge {
        guard lifetime.isFinite, lifetime > 0 else { throw PairingError.invalidConfiguration }
        let code = try codeGenerator()
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            throw PairingError.invalidGeneratedCode
        }
        let expiresAt = clock().addingTimeInterval(lifetime)
        let record = StoredChallenge(digest: Self.digest(code), expiresAt: expiresAt)
        try await secretStore.writeSecret(try JSONEncoder().encode(record), named: Self.challengeKey)
        return PairingChallenge(code: code, expiresAt: expiresAt)
    }

    public func redeem(code: String) async throws -> PairingCredential {
        guard let encoded = try await secretStore.readSecret(named: Self.challengeKey) else {
            throw PairingError.noActiveCode
        }
        let record = try JSONDecoder().decode(StoredChallenge.self, from: encoded)
        guard clock() < record.expiresAt else {
            try await secretStore.removeSecret(named: Self.challengeKey)
            throw PairingError.expired
        }
        guard Self.constantTimeEqual(record.digest, Self.digest(code)) else {
            throw PairingError.invalidCode
        }

        let credential = try PairingCredential(secret: tokenGenerator())
        try await secretStore.writeSecret(credential.secret, named: Self.credentialKey)
        try await secretStore.removeSecret(named: Self.challengeKey)
        return credential
    }

    public func rotateCredential() async throws -> PairingCredential {
        let credential = try PairingCredential(secret: tokenGenerator())
        try await secretStore.writeSecret(credential.secret, named: Self.credentialKey)
        return credential
    }

    public func revokeCredential() async throws {
        try await secretStore.removeSecret(named: Self.credentialKey)
        try await secretStore.removeSecret(named: Self.challengeKey)
    }

    /// Clears the Mac-displayed pairing challenge without touching the Watch Keychain credential.
    public func clearDisplayedChallenge() async throws {
        try await secretStore.removeSecret(named: Self.challengeKey)
    }

    public func currentCredential() async throws -> PairingCredential? {
        guard let secret = try await secretStore.readSecret(named: Self.credentialKey) else {
            return nil
        }
        return try PairingCredential(secret: secret)
    }

    public func matchesBearerToken(_ suppliedToken: String) async throws -> Bool {
        guard let credential = try await currentCredential(),
              let supplied = Self.decodeHex(suppliedToken),
              supplied.count == credential.secret.count
        else {
            return false
        }
        return Self.constantTimeEqual(supplied, credential.secret)
    }

    func secret(matchingBearerToken suppliedToken: String) async throws -> Data? {
        guard let credential = try await currentCredential(),
              let supplied = Self.decodeHex(suppliedToken),
              Self.constantTimeEqual(supplied, credential.secret)
        else {
            return nil
        }
        return credential.secret
    }

    private static func digest(_ value: String) -> Data {
        Data(SHA256.hash(data: Data(value.utf8)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func decodeHex(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }

    private static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0 ... 999_999))
    }

    private static func randomToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
