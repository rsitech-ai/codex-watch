import Foundation

public enum MemoState: String, Codable, CaseIterable, Sendable {
    case saved
    case uploading
    case received
    case transcribing
    case readyForCodex
    case inserting
    case reconciling
    case delivered
    case needsAttention
}

public enum VoiceMemoValidationError: Error, Equatable, Sendable {
    case invalidCaptureDate
    case invalidAudioDigest
    case invalidByteCount
    case invalidDuration
    case unsupportedFormatVersion
    case invalidLocaleHint
    case inconsistentStateRevision
}

public struct VoiceMemoMetadata: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumAudioByteCount: Int64 = 32 * 1_024 * 1_024
    public static let maximumDurationMilliseconds: Int64 = 15 * 60 * 1_000

    public let memoID: MemoID
    public let capturedAt: Date
    public let audioSHA256: String
    public let byteCount: Int64
    public let durationMilliseconds: Int64
    public let formatVersion: Int
    public let localeHint: String?
    public let state: MemoState
    public let stateRevision: UInt64

    public init(
        memoID: MemoID,
        capturedAt: Date,
        audioSHA256: String,
        byteCount: Int64,
        durationMilliseconds: Int64,
        formatVersion: Int = Self.currentFormatVersion,
        localeHint: String? = nil,
        state: MemoState = .saved,
        stateRevision: UInt64 = 0
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw VoiceMemoValidationError.invalidCaptureDate
        }
        guard SHA256Hex.isValid(audioSHA256) else {
            throw VoiceMemoValidationError.invalidAudioDigest
        }
        guard (1 ... Self.maximumAudioByteCount).contains(byteCount) else {
            throw VoiceMemoValidationError.invalidByteCount
        }
        guard (1 ... Self.maximumDurationMilliseconds).contains(durationMilliseconds) else {
            throw VoiceMemoValidationError.invalidDuration
        }
        guard formatVersion == Self.currentFormatVersion else {
            throw VoiceMemoValidationError.unsupportedFormatVersion
        }
        if let localeHint {
            guard !localeHint.isEmpty,
                  localeHint.utf8.count <= 64,
                  localeHint.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F })
            else {
                throw VoiceMemoValidationError.invalidLocaleHint
            }
        }
        guard MemoStateTransition.isReachable(
            from: .saved,
            to: state,
            steps: stateRevision
        ) else {
            throw VoiceMemoValidationError.inconsistentStateRevision
        }

        self.memoID = memoID
        self.capturedAt = capturedAt
        self.audioSHA256 = audioSHA256.lowercased()
        self.byteCount = byteCount
        self.durationMilliseconds = durationMilliseconds
        self.formatVersion = formatVersion
        self.localeHint = localeHint
        self.state = state
        self.stateRevision = stateRevision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                memoID: values.decode(MemoID.self, forKey: .memoID),
                capturedAt: values.decode(Date.self, forKey: .capturedAt),
                audioSHA256: values.decode(String.self, forKey: .audioSHA256),
                byteCount: values.decode(Int64.self, forKey: .byteCount),
                durationMilliseconds: values.decode(Int64.self, forKey: .durationMilliseconds),
                formatVersion: values.decode(Int.self, forKey: .formatVersion),
                localeHint: values.decodeIfPresent(String.self, forKey: .localeHint),
                state: values.decode(MemoState.self, forKey: .state),
                stateRevision: values.decode(UInt64.self, forKey: .stateRevision)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid voice memo metadata")
            )
        }
    }

    func replacing(state: MemoState, revision: UInt64) throws -> Self {
        try Self(
            memoID: memoID,
            capturedAt: capturedAt,
            audioSHA256: audioSHA256,
            byteCount: byteCount,
            durationMilliseconds: durationMilliseconds,
            formatVersion: formatVersion,
            localeHint: localeHint,
            state: state,
            stateRevision: revision
        )
    }
}

public enum MemoTransitionError: Error, Equatable, Sendable {
    case staleRevision
    case invalidTransition
}

public enum MemoStateTransition {
    public static func transition(
        _ memo: VoiceMemoMetadata,
        to nextState: MemoState,
        revision: UInt64
    ) throws -> VoiceMemoMetadata {
        guard memo.stateRevision < UInt64.max,
              revision == memo.stateRevision + 1
        else {
            throw MemoTransitionError.staleRevision
        }
        guard allowed[memo.state, default: []].contains(nextState) else {
            throw MemoTransitionError.invalidTransition
        }
        return try memo.replacing(state: nextState, revision: revision)
    }

    static func isReachable(
        from start: MemoState,
        to destination: MemoState,
        steps: UInt64
    ) -> Bool {
        guard let startIndex = states.firstIndex(of: start),
              let destinationIndex = states.firstIndex(of: destination)
        else {
            return false
        }

        var remaining = steps
        var reachable = UInt16(1) << startIndex
        var matrix = adjacencyMatrix
        while remaining > 0 {
            if remaining & 1 == 1 {
                reachable = apply(reachable, matrix: matrix)
            }
            remaining >>= 1
            if remaining > 0 {
                matrix = compose(matrix, matrix)
            }
        }
        return reachable & (UInt16(1) << destinationIndex) != 0
    }

    private static let allowed: [MemoState: Set<MemoState>] = [
        .saved: [.uploading, .needsAttention],
        .uploading: [.saved, .received, .needsAttention],
        .received: [.transcribing, .needsAttention],
        .transcribing: [.readyForCodex, .needsAttention],
        .readyForCodex: [.inserting, .needsAttention],
        .inserting: [.reconciling, .delivered, .needsAttention],
        .reconciling: [.inserting, .delivered, .needsAttention],
        .delivered: [],
        .needsAttention: [],
    ]

    private static let states: [MemoState] = [
        .saved,
        .uploading,
        .received,
        .transcribing,
        .readyForCodex,
        .inserting,
        .reconciling,
        .delivered,
        .needsAttention,
    ]

    private static let adjacencyMatrix: [UInt16] = states.map { state in
        allowed[state, default: []].reduce(into: UInt16(0)) { row, destination in
            if let destinationIndex = states.firstIndex(of: destination) {
                row |= UInt16(1) << destinationIndex
            }
        }
    }

    private static func apply(_ vector: UInt16, matrix: [UInt16]) -> UInt16 {
        var result: UInt16 = 0
        for index in matrix.indices where vector & (UInt16(1) << index) != 0 {
            result |= matrix[index]
        }
        return result
    }

    private static func compose(_ left: [UInt16], _ right: [UInt16]) -> [UInt16] {
        left.map { apply($0, matrix: right) }
    }
}

public enum SHA256Hex {
    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 70).contains(byte)
                || (97 ... 102).contains(byte)
        }
    }
}
