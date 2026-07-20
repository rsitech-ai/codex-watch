import CodexBridgeShared
import Foundation

public enum DeliveryRecordError: Error, Equatable, Sendable {
    case invalidRecord
}

public enum DeliverySafeRetryBoundary: Sendable {
    case definitelyNotAccepted
    case authoritativelyAbsent
}

public struct DeliveryRecord: Codable, Equatable, Sendable {
    public let memoID: MemoID
    public let capturedAt: Date
    public let localeHint: String?
    public let audioSHA256: String
    public let state: MemoState
    public let revision: UInt64
    public let updatedAt: Date
    public let transcript: String?

    public static func received(
        memoID: MemoID,
        capturedAt: Date,
        localeHint: String?,
        audioSHA256: String,
        updatedAt: Date = Date()
    ) -> Self {
        Self(
            memoID: memoID,
            capturedAt: capturedAt,
            localeHint: localeHint,
            audioSHA256: audioSHA256.lowercased(),
            state: .received,
            revision: 0,
            updatedAt: updatedAt,
            transcript: nil
        )
    }

    public init(
        memoID: MemoID,
        capturedAt: Date,
        localeHint: String?,
        audioSHA256: String,
        state: MemoState,
        revision: UInt64,
        updatedAt: Date,
        transcript: String?
    ) {
        self.memoID = memoID
        self.capturedAt = capturedAt
        self.localeHint = localeHint
        self.audioSHA256 = audioSHA256.lowercased()
        self.state = state
        self.revision = revision
        self.updatedAt = updatedAt
        self.transcript = transcript
    }

    public func validated() throws -> Self {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              revision <= 1_000_000,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              SHA256Hex.isValid(audioSHA256),
              Self.validState(state),
              Self.validLocale(localeHint),
              Self.validTranscript(transcript, for: state)
        else { throw DeliveryRecordError.invalidRecord }
        return self
    }

    static func transitionAllowed(from: MemoState, to: MemoState) -> Bool {
        switch (from, to) {
        case (.received, .transcribing),
             (.transcribing, .readyForCodex),
             (.readyForCodex, .inserting),
             (.inserting, .reconciling),
             (.reconciling, .delivered),
             (.received, .needsAttention),
             (.transcribing, .needsAttention),
             (.readyForCodex, .needsAttention),
             (.inserting, .needsAttention),
             (.reconciling, .needsAttention):
            true
        default:
            false
        }
    }

    private static func validLocale(_ locale: String?) -> Bool {
        guard let locale else { return true }
        return !locale.isEmpty && locale.utf8.count <= 64 && locale.utf8.allSatisfy {
            $0 >= 0x20 && $0 != 0x7F
        }
    }

    private static func validTranscript(_ transcript: String?, for state: MemoState) -> Bool {
        switch state {
        case .received, .transcribing:
            return transcript == nil
        case .needsAttention:
            guard let transcript else { return true }
            return validTranscriptContent(transcript)
        case .readyForCodex, .inserting, .reconciling, .delivered:
            guard let transcript else { return false }
            return validTranscriptContent(transcript)
        case .saved, .uploading:
            return false
        }
    }

    private static func validTranscriptContent(_ transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && transcript.utf8.count <= 128 * 1_024
            && !transcript.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validState(_ state: MemoState) -> Bool {
        switch state {
        case .received, .transcribing, .readyForCodex, .inserting,
             .reconciling, .delivered, .needsAttention:
            true
        case .saved, .uploading:
            false
        }
    }
}
