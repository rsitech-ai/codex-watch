import CryptoKit
import Foundation

public enum RequestAuthenticationError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidDigest
    case invalidSignature
    case invalidConfiguration
    case timestampOutsideWindow
    case replay
    case replayStoreUnavailable
}

public struct CanonicalBridgeRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let timestamp: Int64
    public let nonce: String
    public let memoID: MemoID
    public let bodySHA256: String
    public let revision: UInt64
    public let capturedAtBits: UInt64
    public let localeHint: String?

    public init(
        method: String,
        path: String,
        timestamp: Int64,
        nonce: String,
        memoID: MemoID,
        bodySHA256: String,
        revision: UInt64,
        capturedAtBits: UInt64 = 0,
        localeHint: String? = nil
    ) throws {
        let methodBytes = Array(method.utf8)
        guard !methodBytes.isEmpty,
              methodBytes.count <= 16,
              methodBytes.allSatisfy({ byte in
                  (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
              }),
              path.first == "/",
              path.utf8.count <= 1_024,
              Self.isSingleLine(path),
              timestamp >= 0,
              !nonce.isEmpty,
              nonce.utf8.count <= 128,
              Self.isSingleLine(nonce),
              revision > 0,
              Double(bitPattern: capturedAtBits).isFinite
        else {
            throw RequestAuthenticationError.invalidRequest
        }
        guard SHA256Hex.isValid(bodySHA256) else {
            throw RequestAuthenticationError.invalidDigest
        }

        self.method = method.uppercased()
        self.path = path
        self.timestamp = timestamp
        self.nonce = nonce
        self.memoID = memoID
        self.bodySHA256 = bodySHA256.lowercased()
        self.revision = revision
        self.capturedAtBits = capturedAtBits
        if let localeHint {
            guard !localeHint.isEmpty,
                  localeHint.utf8.count <= 64,
                  Self.isSingleLine(localeHint)
            else { throw RequestAuthenticationError.invalidRequest }
        }
        self.localeHint = localeHint
    }

    public func canonicalBytes() throws -> Data {
        guard Self.isSingleLine(method), Self.isSingleLine(path), Self.isSingleLine(nonce) else {
            throw RequestAuthenticationError.invalidRequest
        }
        return Data([
            "codex-watch-request-v2",
            method,
            path,
            String(timestamp),
            nonce,
            memoID.rawValue,
            bodySHA256,
            String(revision),
            String(capturedAtBits, radix: 16),
            localeHint ?? "",
        ].joined(separator: "\n").utf8)
    }

    private static func isSingleLine(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }
}

public enum RequestAuthenticator {
    public static func signatureHex(
        for request: CanonicalBridgeRequest,
        key: SymmetricKey
    ) throws -> String {
        let code = HMAC<SHA256>.authenticationCode(for: try request.canonicalBytes(), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(
        signatureHex: String,
        for request: CanonicalBridgeRequest,
        key: SymmetricKey
    ) throws -> Bool {
        guard let supplied = decodeHex(signatureHex), supplied.count == SHA256.byteCount else {
            throw RequestAuthenticationError.invalidSignature
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: try request.canonicalBytes(),
            using: key
        ))
        return constantTimeEqual(supplied, expected)
    }

    private static func decodeHex(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        guard bytes.count == 64 else { return nil }
        var result = Data(capacity: 32)
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

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

public protocol ReplayNonceStore: Sendable {
    func consume(_ nonce: String, acceptedAt: Date, expiresAt: Date) async throws -> Bool
}

public actor InMemoryReplayNonceStore: ReplayNonceStore {
    private var consumed: Set<String> = []

    public init() {}

    public func consume(_ nonce: String, acceptedAt _: Date, expiresAt _: Date) -> Bool {
        consumed.insert(nonce).inserted
    }
}

public actor AuthenticatedRequestVerifier {
    private let allowedClockSkew: TimeInterval
    private let replayRetention: TimeInterval
    private let clock: @Sendable () -> Date
    private let replayStore: any ReplayNonceStore

    public init(
        allowedClockSkew: TimeInterval,
        replayRetention: TimeInterval,
        clock: @escaping @Sendable () -> Date = Date.init,
        replayStore: any ReplayNonceStore
    ) throws {
        guard allowedClockSkew.isFinite,
              allowedClockSkew > 0,
              replayRetention.isFinite,
              replayRetention > 0
        else {
            throw RequestAuthenticationError.invalidConfiguration
        }
        self.allowedClockSkew = allowedClockSkew
        self.replayRetention = replayRetention
        self.clock = clock
        self.replayStore = replayStore
    }

    public func verify(
        signatureHex: String,
        request: CanonicalBridgeRequest,
        key: SymmetricKey
    ) async throws {
        let now = clock()
        let requestDate = Date(timeIntervalSince1970: TimeInterval(request.timestamp))
        guard abs(now.timeIntervalSince(requestDate)) <= allowedClockSkew else {
            throw RequestAuthenticationError.timestampOutsideWindow
        }
        guard try RequestAuthenticator.verify(signatureHex: signatureHex, for: request, key: key) else {
            throw RequestAuthenticationError.invalidSignature
        }

        let consumed: Bool
        do {
            consumed = try await replayStore.consume(
                request.nonce,
                acceptedAt: now,
                expiresAt: now.addingTimeInterval(replayRetention)
            )
        } catch {
            throw RequestAuthenticationError.replayStoreUnavailable
        }
        guard consumed else {
            throw RequestAuthenticationError.replay
        }
    }
}
