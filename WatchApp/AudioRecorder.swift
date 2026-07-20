import AVFAudio
import CodexBridgeShared
import CodexWatchCore
import Foundation

enum WatchAudioRecorderError: Error {
    case couldNotPrepare
    case couldNotStart
    case notRecording
    case invalidRecording
}

@MainActor
final class WatchAudioRecorder: NSObject, WatchAudioRecording, @preconcurrency AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var maximumDurationMilliseconds = VoiceMemoMetadata.maximumDurationMilliseconds
    private var completionContinuation: CheckedContinuation<WatchRecordingCompletion, Never>?
    private var bufferedCompletion: WatchRecordingCompletion?
    private var completedRecordingResult: WatchRecordingResult?
    private var completionDelivered = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionInterrupted(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func recordingPermission() async -> WatchRecordingPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .undetermined
        @unknown default:
            return .denied
        }
    }

    func requestRecordingPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startRecording(to url: URL, maximumDuration: TimeInterval) async throws {
        guard audioRecorder == nil else { throw WatchAudioRecorderError.couldNotStart }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let recorder = try AVAudioRecorder(
            url: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
        )
        recorder.delegate = self
        guard recorder.prepareToRecord() else {
            try? session.setActive(false)
            throw WatchAudioRecorderError.couldNotPrepare
        }
        maximumDurationMilliseconds = max(
            1,
            Int64((maximumDuration * 1_000).rounded())
        )
        completionContinuation = nil
        bufferedCompletion = nil
        completedRecordingResult = nil
        completionDelivered = false
        audioRecorder = recorder
        guard recorder.record(forDuration: maximumDuration) else {
            audioRecorder = nil
            try? session.setActive(false)
            throw WatchAudioRecorderError.couldNotStart
        }
    }

    func stopRecording() async throws -> WatchRecordingResult {
        guard let audioRecorder else {
            if let completedRecordingResult {
                self.completedRecordingResult = nil
                return completedRecordingResult
            }
            throw WatchAudioRecorderError.notRecording
        }
        let duration = max(1, Int64((audioRecorder.currentTime * 1_000).rounded()))
        resolveCompletion(.cancelled)
        audioRecorder.stop()
        self.audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        return WatchRecordingResult(durationMilliseconds: duration)
    }

    func cancelRecording() async {
        resolveCompletion(.cancelled)
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func waitForAutomaticCompletion() async -> WatchRecordingCompletion {
        if let bufferedCompletion {
            self.bufferedCompletion = nil
            return bufferedCompletion
        }
        if completionDelivered {
            return .cancelled
        }
        return await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
    }

    func inspectRecording(at url: URL) async throws -> WatchRecordingResult {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
            throw WatchAudioRecorderError.invalidRecording
        }
        let duration = Double(file.length) / sampleRate
        let maximumDuration = Double(VoiceMemoMetadata.maximumDurationMilliseconds) / 1_000
        guard duration.isFinite, duration > 0, duration <= maximumDuration else {
            throw WatchAudioRecorderError.invalidRecording
        }
        return WatchRecordingResult(
            durationMilliseconds: max(1, Int64((duration * 1_000).rounded()))
        )
    }

    func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard recorder === audioRecorder else { return }
        audioRecorder = nil
        let completion: WatchRecordingCompletion = flag
            ? .finished(
                WatchRecordingResult(
                    durationMilliseconds: maximumDurationMilliseconds
                )
            )
            : .failed
        if case let .finished(result) = completion {
            completedRecordingResult = result
        }
        resolveCompletion(completion)
        deactivateAudioSession()
    }

    func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error _: (any Error)?
    ) {
        guard recorder === audioRecorder else { return }
        resolveCompletion(.failed)
        audioRecorder?.stop()
        audioRecorder = nil
        deactivateAudioSession()
    }

    @objc
    private func audioSessionInterrupted(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: typeValue) == .began,
              audioRecorder != nil
        else { return }
        resolveCompletion(.failed)
        audioRecorder?.stop()
        audioRecorder = nil
        deactivateAudioSession()
    }

    private func resolveCompletion(_ completion: WatchRecordingCompletion) {
        guard !completionDelivered else { return }
        completionDelivered = true
        if let completionContinuation {
            self.completionContinuation = nil
            completionContinuation.resume(returning: completion)
        } else {
            bufferedCompletion = completion
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}
