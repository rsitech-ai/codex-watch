import Foundation

public enum TranscriptionError: Error, Equatable, Sendable {
    case permissionDenied
    case invalidAudioAsset
    case unsupportedLocale
    case onDeviceRecognitionUnavailable
    case emptyTranscript
    case cancelled
    case engineFailure
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(committedAudio: CommittedAudioAsset, localeHint: String?) async throws -> String
}
