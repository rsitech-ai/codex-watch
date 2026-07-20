import CodexBridgeShared
import CryptoKit
import Foundation

public enum BridgeUploadRequestError: Error, Equatable, Sendable {
    case invalidMemoState
    case audioIdentityMismatch
    case invalidToken
    case invalidCredential
}

public struct SignedBridgeUploadRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let contentLength: Int

    public init(method: String, path: String, headers: [String: String], contentLength: Int) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
    }
}

public struct SignedBridgeControlRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public typealias SignedBridgeStatusRequest = SignedBridgeControlRequest
public typealias SignedBridgeFinalAcknowledgementRequest = SignedBridgeControlRequest

public enum BridgeFinalAcknowledgementRequestBuilder {
    public static func make(
        acknowledgement: FinalDeliveryAcknowledgement,
        token: Data,
        timestamp: Int64,
        nonce: String
    ) throws -> SignedBridgeFinalAcknowledgementRequest {
        guard SHA256Hex.isValid(acknowledgement.audioSHA256),
              acknowledgement.stateRevision > 0
        else { throw BridgeUploadRequestError.audioIdentityMismatch }
        guard token.count == 32 else { throw BridgeUploadRequestError.invalidToken }
        let path = "/v1/memos/\(acknowledgement.memoID.rawValue)/final-ack"
        let canonical = try CanonicalBridgeRequest(
            method: "POST",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: acknowledgement.memoID,
            bodySHA256: acknowledgement.audioSHA256,
            revision: acknowledgement.stateRevision
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: token)
        )
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        return SignedBridgeFinalAcknowledgementRequest(
            method: "POST",
            path: path,
            headers: [
                "authorization": "Bearer \(tokenHex)",
                "content-length": "0",
                "x-codex-body-sha256": acknowledgement.audioSHA256,
                "x-codex-memo-id": acknowledgement.memoID.rawValue,
                "x-codex-nonce": nonce,
                "x-codex-revision": String(acknowledgement.stateRevision),
                "x-codex-signature": signature,
                "x-codex-timestamp": String(timestamp),
                "x-codex-version": String(BridgeProtocolVersion.current.major),
            ],
            body: Data()
        )
    }
}

public enum BridgeStatusRequestBuilder {
    public static func make(
        memo: VoiceMemoMetadata,
        token: Data,
        timestamp: Int64,
        nonce: String
    ) throws -> SignedBridgeStatusRequest {
        guard memo.state != .saved,
              memo.state != .uploading,
              memo.state != .delivered,
              memo.state != .needsAttention
        else { throw BridgeUploadRequestError.invalidMemoState }
        guard token.count == 32 else { throw BridgeUploadRequestError.invalidToken }
        let path = "/v1/memos/\(memo.memoID.rawValue)/status"
        let emptyDigest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let canonical = try CanonicalBridgeRequest(
            method: "GET",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: memo.memoID,
            bodySHA256: emptyDigest,
            revision: memo.stateRevision
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: token)
        )
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        return SignedBridgeStatusRequest(
            method: "GET",
            path: path,
            headers: [
                "authorization": "Bearer \(tokenHex)",
                "content-length": "0",
                "x-codex-body-sha256": emptyDigest,
                "x-codex-memo-id": memo.memoID.rawValue,
                "x-codex-nonce": nonce,
                "x-codex-revision": String(memo.stateRevision),
                "x-codex-signature": signature,
                "x-codex-timestamp": String(timestamp),
                "x-codex-version": String(BridgeProtocolVersion.current.major),
            ],
            body: Data()
        )
    }
}

public enum BridgeUploadRequestBuilder {
    public static func make(
        memo: VoiceMemoMetadata,
        contentLength: Int,
        token: Data,
        timestamp: Int64,
        nonce: String
    ) throws -> SignedBridgeUploadRequest {
        guard memo.state == .uploading, memo.stateRevision < UInt64.max else {
            throw BridgeUploadRequestError.invalidMemoState
        }
        guard contentLength > 0,
              Int64(contentLength) == memo.byteCount,
              SHA256Hex.isValid(memo.audioSHA256)
        else {
            throw BridgeUploadRequestError.audioIdentityMismatch
        }
        guard token.count == 32 else { throw BridgeUploadRequestError.invalidToken }

        let path = "/v1/memos/\(memo.memoID.rawValue)"
        let canonical = try CanonicalBridgeRequest(
            method: "POST",
            path: path,
            timestamp: timestamp,
            nonce: nonce,
            memoID: memo.memoID,
            bodySHA256: memo.audioSHA256,
            revision: memo.stateRevision,
            capturedAtBits: memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
            localeHint: memo.localeHint
        )
        let signature = try RequestAuthenticator.signatureHex(
            for: canonical,
            key: SymmetricKey(data: token)
        )
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        return SignedBridgeUploadRequest(
            method: "POST",
            path: path,
            headers: [
                "authorization": "Bearer \(tokenHex)",
                "content-length": String(contentLength),
                "content-type": "audio/mp4",
                "x-codex-body-sha256": memo.audioSHA256.lowercased(),
                "x-codex-captured-at": String(
                    memo.capturedAt.timeIntervalSinceReferenceDate.bitPattern,
                    radix: 16
                ),
                "x-codex-memo-id": memo.memoID.rawValue,
                "x-codex-nonce": nonce,
                "x-codex-revision": String(memo.stateRevision),
                "x-codex-signature": signature,
                "x-codex-timestamp": String(timestamp),
                "x-codex-version": String(BridgeProtocolVersion.current.major),
            ].merging(memo.localeHint.map { ["x-codex-locale": $0] } ?? [:]) { _, new in new },
            contentLength: contentLength
        )
    }
}

public enum BridgeRecoveryUploadRequestBuilder {
    public static func make(
        memo: VoiceMemoMetadata,
        contentLength: Int,
        token: Data,
        timestamp: Int64,
        nonce: String
    ) throws -> SignedBridgeUploadRequest {
        guard memo.state == .received,
              memo.stateRevision > 0,
              memo.stateRevision.isMultiple(of: 2)
        else { throw BridgeUploadRequestError.invalidMemoState }
        let originalUpload = try VoiceMemoMetadata(
            memoID: memo.memoID,
            capturedAt: memo.capturedAt,
            audioSHA256: memo.audioSHA256,
            byteCount: memo.byteCount,
            durationMilliseconds: memo.durationMilliseconds,
            formatVersion: memo.formatVersion,
            localeHint: memo.localeHint,
            state: .uploading,
            stateRevision: memo.stateRevision - 1
        )
        return try BridgeUploadRequestBuilder.make(
            memo: originalUpload,
            contentLength: contentLength,
            token: token,
            timestamp: timestamp,
            nonce: nonce
        )
    }
}

public enum BridgeUploadResponseDecoder {
    public static func receipt(statusCode: Int, body: Data) throws -> BridgeReceipt {
        switch statusCode {
        case 200, 201:
            do {
                return try JSONDecoder().decode(BridgeEnvelope<BridgeReceipt>.self, from: body).payload
            } catch {
                throw WatchBridgeTransportFailure.transient
            }
        default:
            throw BridgeResponseFailureClassifier.failure(statusCode: statusCode, body: body)
        }
    }
}

public enum BridgeStatusResponseDecoder {
    public static func status(statusCode: Int, body: Data) throws -> BridgeMemoStatus {
        switch statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(BridgeEnvelope<BridgeMemoStatus>.self, from: body).payload
            } catch {
                throw WatchBridgeTransportFailure.transient
            }
        case 404:
            if (try? JSONDecoder().decode(BridgeErrorResponse.self, from: body).error)
                == "status_absent"
            {
                throw WatchBridgeTransportFailure.statusAbsent
            }
            fallthrough
        default:
            throw BridgeResponseFailureClassifier.failure(statusCode: statusCode, body: body)
        }
    }
}

private struct BridgeErrorResponse: Decodable {
    let error: String
}

private enum BridgeResponseFailureClassifier {
    static func failure(statusCode: Int, body: Data) -> WatchBridgeTransportFailure {
        if statusCode == 401 || statusCode == 403 {
            return .authentication
        }
        let code = try? JSONDecoder().decode(BridgeErrorResponse.self, from: body).error
        switch code {
        case "identity_conflict":
            return .conflict
        case "corrupt_content",
             "digest_mismatch",
             "unsupported_format",
             "inconsistent_authoritative_history":
            return .permanent
        default:
            return .transient
        }
    }
}

public enum BridgeFinalAcknowledgementResponseDecoder {
    public static func acknowledged(statusCode: Int, body: Data) throws -> Bool {
        switch statusCode {
        case 204 where body.isEmpty:
            true
        default:
            throw BridgeResponseFailureClassifier.failure(statusCode: statusCode, body: body)
        }
    }
}

public struct WatchBridgeCredential: Codable, Equatable, Sendable {
    public let bridgeName: String
    public let baseURL: URL
    public let certificatePin: CertificatePin
    public let tokenHex: String
    public let token: Data

    public init(
        bridgeName: String,
        baseURL: URL,
        certificatePin: CertificatePin,
        tokenHex: String
    ) throws {
        guard !bridgeName.isEmpty,
              bridgeName.utf8.count <= 128,
              bridgeName.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
              baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              let token = Self.decodeToken(tokenHex)
        else {
            throw BridgeUploadRequestError.invalidCredential
        }
        self.bridgeName = bridgeName
        self.baseURL = baseURL
        self.certificatePin = certificatePin
        self.tokenHex = tokenHex.lowercased()
        self.token = token
    }

    public func retained(after failure: WatchBridgeTransportFailure) -> Self? {
        failure == .authentication ? nil : self
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                bridgeName: values.decode(String.self, forKey: .bridgeName),
                baseURL: values.decode(URL.self, forKey: .baseURL),
                certificatePin: values.decode(CertificatePin.self, forKey: .certificatePin),
                tokenHex: values.decode(String.self, forKey: .tokenHex)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid bridge credential")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bridgeName, forKey: .bridgeName)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(certificatePin, forKey: .certificatePin)
        try values.encode(tokenHex, forKey: .tokenHex)
    }

    private enum CodingKeys: String, CodingKey {
        case bridgeName
        case baseURL
        case certificatePin
        case tokenHex
    }

    private static func decodeToken(_ value: String) -> Data? {
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
}
