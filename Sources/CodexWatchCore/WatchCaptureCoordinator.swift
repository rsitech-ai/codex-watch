import CodexBridgeShared
import Foundation

public enum WatchRecordingPermission: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

public struct WatchRecordingResult: Equatable, Sendable {
    public let durationMilliseconds: Int64

    public init(durationMilliseconds: Int64) {
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum WatchRecordingCompletion: Equatable, Sendable {
    case finished(WatchRecordingResult)
    case failed
    case cancelled
}

public protocol WatchAudioRecording: Sendable {
    func recordingPermission() async -> WatchRecordingPermission
    func requestRecordingPermission() async -> Bool
    func startRecording(to url: URL, maximumDuration: TimeInterval) async throws
    func stopRecording() async throws -> WatchRecordingResult
    func cancelRecording() async
    func waitForAutomaticCompletion() async -> WatchRecordingCompletion
    func inspectRecording(at url: URL) async throws -> WatchRecordingResult
}

public enum WatchCaptureFailure: Equatable, Sendable {
    case identifier
    case recorderStart
    case recorderStop
    case queueCommit
    case recovery
}

public enum WatchCaptureState: Equatable, Sendable {
    case idle
    case preparing
    case recording(MemoID)
    case saving(MemoID)
    case savedOnWatch(MemoID)
    case permissionDenied
    case interruptedRecordingFound(Int)
    case failed(WatchCaptureFailure)
}

public actor WatchCaptureCoordinator {
    public private(set) var currentState: WatchCaptureState = .idle

    private let store: WatchMemoStore
    private let recorder: any WatchAudioRecording
    private let maximumDuration: TimeInterval
    private let localeHint: String?
    private let memoIDProvider: @Sendable () throws -> MemoID
    private let clock: @Sendable () -> Date
    private var activeMemoID: MemoID?
    private var captureStartedAt: Date?

    public init(
        store: WatchMemoStore,
        recorder: any WatchAudioRecording,
        maximumDuration: TimeInterval = TimeInterval(
            VoiceMemoMetadata.maximumDurationMilliseconds
        ) / 1_000,
        localeHint: String? = nil,
        memoIDProvider: @escaping @Sendable () throws -> MemoID = {
            try MemoID(UUID().uuidString)
        },
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.recorder = recorder
        let protocolMaximum = TimeInterval(
            VoiceMemoMetadata.maximumDurationMilliseconds
        ) / 1_000
        self.maximumDuration = max(1, min(maximumDuration, protocolMaximum))
        self.localeHint = localeHint
        self.memoIDProvider = memoIDProvider
        self.clock = clock
    }

    public func beginCapture() async {
        guard !isOperationInProgress else { return }
        currentState = .preparing

        let permission = await recorder.recordingPermission()
        let permitted: Bool
        switch permission {
        case .granted:
            permitted = true
        case .denied:
            permitted = false
        case .undetermined:
            permitted = await recorder.requestRecordingPermission()
        }
        guard permitted else {
            currentState = .permissionDenied
            return
        }

        let memoID: MemoID
        do {
            memoID = try memoIDProvider()
        } catch {
            currentState = .failed(.identifier)
            return
        }
        let temporaryURL = await store.temporaryRecordingURL(for: memoID)
        do {
            try await recorder.startRecording(
                to: temporaryURL,
                maximumDuration: maximumDuration
            )
            activeMemoID = memoID
            captureStartedAt = clock()
            currentState = .recording(memoID)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            activeMemoID = nil
            captureStartedAt = nil
            currentState = .failed(.recorderStart)
        }
    }

    public func finishCapture() async {
        guard case let .recording(memoID) = currentState,
              activeMemoID == memoID,
              let capturedAt = captureStartedAt
        else { return }

        let result: WatchRecordingResult
        do {
            result = try await recorder.stopRecording()
        } catch {
            activeMemoID = nil
            captureStartedAt = nil
            currentState = .failed(.recorderStop)
            return
        }

        await finishCapture(
            memoID: memoID,
            capturedAt: capturedAt,
            result: result
        )
    }

    public func finishWhenRecorderCompletes() async {
        guard case let .recording(memoID) = currentState,
              activeMemoID == memoID,
              let capturedAt = captureStartedAt
        else { return }

        let completion = await recorder.waitForAutomaticCompletion()
        guard case .recording(memoID) = currentState,
              activeMemoID == memoID
        else { return }

        switch completion {
        case let .finished(result):
            await finishCapture(
                memoID: memoID,
                capturedAt: capturedAt,
                result: result
            )
        case .failed:
            activeMemoID = nil
            captureStartedAt = nil
            currentState = .failed(.recorderStop)
        case .cancelled:
            return
        }
    }

    private func finishCapture(
        memoID: MemoID,
        capturedAt: Date,
        result: WatchRecordingResult
    ) async {
        currentState = .saving(memoID)
        let temporaryURL = await store.temporaryRecordingURL(for: memoID)
        do {
            _ = try await store.commitRecording(
                temporaryURL: temporaryURL,
                memoID: memoID,
                capturedAt: capturedAt,
                durationMilliseconds: result.durationMilliseconds,
                localeHint: localeHint
            )
            activeMemoID = nil
            captureStartedAt = nil
            currentState = .savedOnWatch(memoID)
        } catch {
            activeMemoID = nil
            captureStartedAt = nil
            currentState = .failed(.queueCommit)
        }
    }

    public func recoverInterruptedCapture() async {
        guard !isOperationInProgress else { return }
        do {
            let recordings = try await store.recoverableRecordingURLs()
            var lastRecoveredMemoID: MemoID?
            for recording in recordings {
                guard let memoID = try? MemoID(
                    recording.deletingPathExtension().lastPathComponent
                ) else { continue }
                do {
                    let result = try await recorder.inspectRecording(at: recording)
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: recording.path
                    )
                    let capturedAt = attributes[.creationDate] as? Date
                        ?? attributes[.modificationDate] as? Date
                        ?? clock()
                    _ = try await store.commitRecording(
                        temporaryURL: recording,
                        memoID: memoID,
                        capturedAt: capturedAt,
                        durationMilliseconds: result.durationMilliseconds,
                        localeHint: localeHint
                    )
                    lastRecoveredMemoID = memoID
                } catch {
                    continue
                }
            }
            let remaining = try await store.recoverableRecordingURLs()
            if !remaining.isEmpty {
                currentState = .interruptedRecordingFound(remaining.count)
            } else if let lastRecoveredMemoID {
                currentState = .savedOnWatch(lastRecoveredMemoID)
            } else {
                currentState = .idle
            }
        } catch {
            currentState = .failed(.recovery)
        }
    }

    public func cancelCapture() async {
        guard case let .recording(memoID) = currentState else { return }
        await recorder.cancelRecording()
        let temporaryURL = await store.temporaryRecordingURL(for: memoID)
        try? FileManager.default.removeItem(at: temporaryURL)
        activeMemoID = nil
        captureStartedAt = nil
        currentState = .idle
    }

    private var isOperationInProgress: Bool {
        switch currentState {
        case .preparing, .recording, .saving:
            return true
        case .idle, .savedOnWatch, .permissionDenied, .interruptedRecordingFound, .failed:
            return false
        }
    }
}
