import Foundation
import Speech
import os

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
            let wanted = SpeechLocaleSelection.normalized(locale.identifier)
            return SFSpeechRecognizer.supportedLocales().contains {
                SpeechLocaleSelection.normalized($0.identifier) == wanted
            }
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

        let locale: Locale
        do {
            locale = try SpeechLocaleSelection.resolved(
                hint: localeHint,
                current: .current,
                supported: supportsLocale
            )
        } catch {
            throw TranscriptionError.unsupportedLocale
        }

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

    private static let logger = Logger(
        subsystem: "ai.rsitech.codexwatch.bridge",
        category: "speech"
    )

    private static func recognizeOnDevice(_ url: URL, locale: Locale) async throws -> String {
        let prepared = try SpeechRecognitionFile.prepared(from: url)
        defer { prepared.release() }
        let boundary = SpeechRecognitionBoundary()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                boundary.install(continuation)
                guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                    logger.error("speech recognizer missing for locale \(locale.identifier, privacy: .public)")
                    boundary.resolve(.failure(.unsupportedLocale))
                    return
                }
                guard recognizer.supportsOnDeviceRecognition else {
                    logger.error("on-device speech unavailable for locale \(locale.identifier, privacy: .public)")
                    boundary.resolve(.failure(.onDeviceRecognitionUnavailable))
                    return
                }

                let request = SFSpeechURLRecognitionRequest(url: prepared.url)
                request.shouldReportPartialResults = false
                request.requiresOnDeviceRecognition = true
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        let ns = error as NSError
                        logger.error("speech recognition failed domain=\(ns.domain, privacy: .public) code=\(ns.code) locale=\(locale.identifier, privacy: .public)")
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

/// Watch locale hints are `en_PL`-style (language + region). Apple Speech lists
/// `en-US`, `pl-PL`, never `en_PL`. Match by normalized identifier, then language.
enum SpeechLocaleSelection {
    static func resolved(
        hint: String?,
        current: Locale,
        supported: (Locale) -> Bool
    ) throws -> Locale {
        for locale in candidates(hint: hint, current: current) where supported(locale) {
            return locale
        }
        throw TranscriptionError.unsupportedLocale
    }

    static func candidates(hint: String?, current: Locale) -> [Locale] {
        var seen = Set<String>()
        var result: [Locale] = []
        func add(_ identifier: String) {
            let locale = Locale(identifier: identifier)
            let key = normalized(locale.identifier)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            result.append(locale)
        }
        if let hint, !hint.isEmpty {
            add(hint)
            add(hint.replacingOccurrences(of: "_", with: "-"))
            add(hint.replacingOccurrences(of: "-", with: "_"))
            let language = languageCode(hint)
            if language == "en" {
                add("en-US")
                add("en-GB")
            }
            if !language.isEmpty {
                add(language)
                add("\(language)-\(language.uppercased())")
            }
        }
        add(current.identifier)
        add("en-US")
        return result
    }

    static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageCode(_ identifier: String) -> String {
        String(normalized(identifier).split(separator: "-").first ?? "")
    }
}

/// Watch AVAudioRecorder writes CAF bytes; intake stores them as `audio.m4a`.
/// Speech keys off the path extension, so CAF-in-.m4a fails closed.
enum SpeechRecognitionFile {
    struct Prepared: Sendable {
        let url: URL
        let cleanup: Bool

        func release() {
            guard cleanup else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func prepared(from url: URL) throws -> Prepared {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic == Data("caff".utf8), url.pathExtension.lowercased() != "caf" else {
            return Prepared(url: url, cleanup: false)
        }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).caf"
        )
        try FileManager.default.copyItem(at: url, to: staged)
        return Prepared(url: staged, cleanup: true)
    }
}
