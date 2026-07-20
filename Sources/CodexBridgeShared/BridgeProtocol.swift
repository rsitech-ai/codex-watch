import Foundation

public struct BridgeProtocolVersion: Codable, Equatable, Sendable {
    public static let current = Self(uncheckedMajor: 1, minor: 3)

    public let major: Int
    public let minor: Int

    public init(major: Int = 1, minor: Int = 0) throws {
        guard major == Self.current.major, minor >= 0 else {
            throw BridgeProtocolError.unsupportedVersion
        }
        self.major = major
        self.minor = minor
    }

    private init(uncheckedMajor major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                major: values.decode(Int.self, forKey: .major),
                minor: values.decode(Int.self, forKey: .minor)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported bridge protocol version")
            )
        }
    }
}

public enum BridgeProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidDigest
    case invalidRevision
}

public struct BridgeEnvelope<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let protocolVersion: BridgeProtocolVersion
    public let payload: Payload

    public init(
        protocolVersion: BridgeProtocolVersion = .current,
        payload: Payload
    ) {
        self.protocolVersion = protocolVersion
        self.payload = payload
    }
}

public enum BridgeAcknowledgementError: Error, Equatable, Sendable {
    case memoMismatch
    case digestMismatch
    case revisionMismatch
    case invalidState
}

public struct FinalDeliveryAcknowledgement: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let stateRevision: UInt64

    public init(memoID: MemoID, audioSHA256: String, stateRevision: UInt64) {
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.stateRevision = stateRevision
    }
}

public struct BridgeReceipt: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let acknowledgedRevision: UInt64
    public let capturedAt: Date
    public let localeHint: String?
    public let receivedAt: Date

    public init(
        memoID: MemoID,
        audioSHA256: String,
        acknowledgedRevision: UInt64,
        capturedAt: Date = .distantPast,
        localeHint: String? = nil,
        receivedAt: Date
    ) throws {
        guard SHA256Hex.isValid(audioSHA256) else {
            throw BridgeProtocolError.invalidDigest
        }
        guard acknowledgedRevision > 0 else {
            throw BridgeProtocolError.invalidRevision
        }
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BridgeProtocolError.invalidRevision
        }
        if let localeHint {
            guard !localeHint.isEmpty,
                  localeHint.utf8.count <= 64,
                  localeHint.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F })
            else { throw BridgeProtocolError.invalidRevision }
        }
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.acknowledgedRevision = acknowledgedRevision
        self.capturedAt = capturedAt
        self.localeHint = localeHint
        self.receivedAt = receivedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                memoID: values.decode(MemoID.self, forKey: .memoID),
                audioSHA256: values.decode(String.self, forKey: .audioSHA256),
                acknowledgedRevision: values.decode(UInt64.self, forKey: .acknowledgedRevision),
                capturedAt: values.decode(Date.self, forKey: .capturedAt),
                localeHint: values.decodeIfPresent(String.self, forKey: .localeHint),
                receivedAt: values.decode(Date.self, forKey: .receivedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid bridge receipt")
            )
        }
    }

    public func validateAcknowledgement(
        for memo: VoiceMemoMetadata,
        expectedRevision: UInt64
    ) throws {
        guard memoID == memo.memoID else { throw BridgeAcknowledgementError.memoMismatch }
        guard audioSHA256 == memo.audioSHA256.lowercased() else {
            throw BridgeAcknowledgementError.digestMismatch
        }
        guard capturedAt == memo.capturedAt, localeHint == memo.localeHint else {
            throw BridgeAcknowledgementError.invalidState
        }
        guard acknowledgedRevision == expectedRevision,
              expectedRevision > memo.stateRevision
        else {
            throw BridgeAcknowledgementError.revisionMismatch
        }
        guard MemoStateTransition.isReachable(
            from: memo.state,
            to: .received,
            steps: expectedRevision - memo.stateRevision
        ) else {
            throw BridgeAcknowledgementError.invalidState
        }
    }

    private enum CodingKeys: String, CodingKey {
        case memoID
        case audioSHA256
        case acknowledgedRevision
        case capturedAt
        case localeHint
        case receivedAt
    }
}

public struct BridgeMemoStatus: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let audioSHA256: String
    public let state: MemoState
    public let stateRevision: UInt64
    public let updatedAt: Date

    public init(
        memoID: MemoID,
        audioSHA256: String,
        state: MemoState,
        stateRevision: UInt64,
        updatedAt: Date
    ) throws {
        guard SHA256Hex.isValid(audioSHA256) else {
            throw BridgeProtocolError.invalidDigest
        }
        guard stateRevision > 0 else {
            throw BridgeProtocolError.invalidRevision
        }
        guard updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw BridgeProtocolError.invalidRevision
        }
        guard MemoStateTransition.isReachable(from: .saved, to: state, steps: stateRevision) else {
            throw BridgeProtocolError.invalidRevision
        }
        self.memoID = memoID
        self.audioSHA256 = audioSHA256.lowercased()
        self.state = state
        self.stateRevision = stateRevision
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                memoID: values.decode(MemoID.self, forKey: .memoID),
                audioSHA256: values.decode(String.self, forKey: .audioSHA256),
                state: values.decode(MemoState.self, forKey: .state),
                stateRevision: values.decode(UInt64.self, forKey: .stateRevision),
                updatedAt: values.decode(Date.self, forKey: .updatedAt)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid bridge memo status")
            )
        }
    }

    public func validateAcknowledgement(
        for memo: VoiceMemoMetadata,
        expectedRevision: UInt64
    ) throws {
        guard memoID == memo.memoID else { throw BridgeAcknowledgementError.memoMismatch }
        guard audioSHA256 == memo.audioSHA256.lowercased() else {
            throw BridgeAcknowledgementError.digestMismatch
        }
        guard stateRevision == expectedRevision,
              expectedRevision > memo.stateRevision
        else {
            throw BridgeAcknowledgementError.revisionMismatch
        }
        guard state != .saved, state != .uploading else {
            throw BridgeAcknowledgementError.invalidState
        }
        guard MemoStateTransition.isReachable(
            from: memo.state,
            to: state,
            steps: expectedRevision - memo.stateRevision
        ) else {
            throw BridgeAcknowledgementError.invalidState
        }
    }

    private enum CodingKeys: String, CodingKey {
        case memoID
        case audioSHA256
        case state
        case stateRevision
        case updatedAt
    }
}
