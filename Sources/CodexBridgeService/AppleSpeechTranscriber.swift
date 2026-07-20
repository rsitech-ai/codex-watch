import Foundation
import Speech

enum SpeechAuthorizationState: Sendable {
    case authorized
    case denied
}

public struct AppleSpeechTranscriber: TranscriptionEngine, Sendable {
    typealias Recognition = @Sendable (URL, Locale) async throws -> String

    private let authorizationStatus: @Sendable () -> SpeechAuthorizationState
    private let supportsLocale: @Sendable (Locale) -> Bool
    private let recognize: Recognition

    public init() {
        authorizationStatus = {
            SFSpeechRecognizer.authorizationStatus() == .authorized ? .authorized : .denied
        }
        supportsLocale = { locale in
            SFSpeechRecognizer.supportedLocales().contains { $0.identifier == locale.identifier }
        }
        recognize = Self.recognizeOnDevice
    }

    init(
        authorizationStatus: @escaping @Sendable () -> SpeechAuthorizationState,
        supportsLocale: @escaping @Sendable (Locale) -> Bool,
        recognize: @escaping Recognition
    ) {
        self.authorizationStatus = authorizationStatus
        self.supportsLocale = supportsLocale
        self.recognize = recognize
    }

    public func transcribe(
        committedAudio: CommittedAudioAsset,
        localeHint: String?
    ) async throws -> String {
        do {
            try committedAudio.validate()
        } catch {
            throw TranscriptionError.invalidAudioAsset
        }
        guard authorizationStatus() == .authorized else {
            throw TranscriptionError.permissionDenied
        }

        let locale = Locale(identifier: localeHint ?? Locale.current.identifier)
        guard supportsLocale(locale) else { throw TranscriptionError.unsupportedLocale }

        let raw: String
        do {
            raw = try await recognize(committedAudio.url, locale)
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.engineFailure
        }
        do {
            try committedAudio.validate()
        } catch {
            throw TranscriptionError.invalidAudioAsset
        }
        let transcript = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw TranscriptionError.emptyTranscript }
        return transcript
    }

    private static func recognizeOnDevice(_ url: URL, locale: Locale) async throws -> String {
        let boundary = SpeechRecognitionBoundary()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                boundary.install(continuation)
                guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                    boundary.resolve(.failure(.unsupportedLocale))
                    return
                }
                guard recognizer.supportsOnDeviceRecognition else {
                    boundary.resolve(.failure(.onDeviceRecognitionUnavailable))
                    return
                }

                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = false
                request.requiresOnDeviceRecognition = true
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        _ = error
                        boundary.resolve(.failure(.engineFailure))
                    } else if let result, result.isFinal {
                        boundary.resolve(.success(result.bestTranscription.formattedString))
                    }
                }
                boundary.install(task)
            }
        } onCancel: {
            boundary.cancel()
        }
    }
}

private final class SpeechRecognitionBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancellationRequested = false
    private var resolved = false

    func install(_ continuation: CheckedContinuation<String, any Error>) {
        let cancelImmediately = lock.withLock {
            guard !resolved else { return true }
            if cancellationRequested {
                resolved = true
                return true
            }
            self.continuation = continuation
            return false
        }
        if cancelImmediately {
            continuation.resume(throwing: TranscriptionError.cancelled)
        }
    }

    func install(_ task: SFSpeechRecognitionTask) {
        let cancelImmediately = lock.withLock {
            self.task = task
            return cancellationRequested || resolved
        }
        if cancelImmediately { task.cancel() }
    }

    func resolve(_ result: Result<String, TranscriptionError>) {
        let continuation = lock.withLock {
            guard !resolved else { return nil as CheckedContinuation<String, any Error>? }
            resolved = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    func cancel() {
        let state = lock.withLock { () -> (
            CheckedContinuation<String, any Error>?,
            SFSpeechRecognitionTask?
        ) in
            cancellationRequested = true
            guard !resolved else { return (nil, task) }
            guard continuation != nil else { return (nil, task) }
            resolved = true
            defer { continuation = nil }
            return (continuation, task)
        }
        state.1?.cancel()
        state.0?.resume(throwing: TranscriptionError.cancelled)
    }
}
