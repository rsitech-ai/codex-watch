@testable import CodexWatchCore
import CodexBridgeShared
import Foundation
import Testing

@Test func permissionDenialNeverCreatesOrClaimsSavedRecording() async throws {
    try await withCaptureFixture(permission: .denied) { fixture in
        await fixture.coordinator.beginCapture()

        let pending = try await fixture.store.loadPending()
        #expect(await fixture.coordinator.currentState == .permissionDenied)
        #expect(await fixture.recorder.startCount == 0)
        #expect(pending.isEmpty)
    }
}

@Test func unknownPermissionIsRequestedBeforeRecordingStarts() async throws {
    try await withCaptureFixture(permission: .undetermined, requestGrantsPermission: true) { fixture in
        await fixture.coordinator.beginCapture()

        #expect(await fixture.coordinator.currentState == .recording(fixture.memoID))
        #expect(await fixture.recorder.permissionRequestCount == 1)
        #expect(await fixture.recorder.startCount == 1)
    }
}

@Test func stoppingCommitsAudioBeforeReportingSavedOnWatch() async throws {
    try await withCaptureFixture(permission: .granted) { fixture in
        await fixture.coordinator.beginCapture()
        await fixture.coordinator.finishCapture()

        let stored = try await fixture.store.load(memoID: fixture.memoID)
        #expect(await fixture.coordinator.currentState == .savedOnWatch(fixture.memoID))
        #expect(stored.metadata.state == .saved)
        #expect(stored.metadata.durationMilliseconds == 1_250)
        #expect(stored.metadata.localeHint == "en-GB")
    }
}

@Test func recorderStartAndStopFailuresRemainTruthfulAndPreserveRecoverableAudio() async throws {
    try await withCaptureFixture(permission: .granted, failure: .start) { fixture in
        await fixture.coordinator.beginCapture()
        let pending = try await fixture.store.loadPending()
        #expect(await fixture.coordinator.currentState == .failed(.recorderStart))
        #expect(pending.isEmpty)
    }

    try await withCaptureFixture(permission: .granted, failure: .stop) { fixture in
        await fixture.coordinator.beginCapture()
        await fixture.coordinator.finishCapture()
        let recoverable = try await fixture.store.recoverableRecordingURLs()
        let pending = try await fixture.store.loadPending()
        #expect(await fixture.coordinator.currentState == .failed(.recorderStop))
        #expect(recoverable.count == 1)
        #expect(pending.isEmpty)
    }
}

@Test func durationLimitUsesSameDurableFinishPath() async throws {
    try await withCaptureFixture(permission: .granted) { fixture in
        await fixture.coordinator.beginCapture()
        await fixture.recorder.setAutomaticCompletion(
            .finished(WatchRecordingResult(durationMilliseconds: 120_000))
        )
        await fixture.coordinator.finishWhenRecorderCompletes()
        let stored = try await fixture.store.load(memoID: fixture.memoID)

        #expect(await fixture.coordinator.currentState == .savedOnWatch(fixture.memoID))
        #expect(stored.metadata.state == .saved)
        #expect(stored.metadata.durationMilliseconds == 120_000)
    }
}

@Test func configuredDurationIsBoundedByTheProtocolFifteenMinuteLimit() async throws {
    try await withCaptureFixture(
        permission: .granted,
        maximumDuration: 30 * 60
    ) { fixture in
        await fixture.coordinator.beginCapture()

        #expect(await fixture.recorder.requestedMaximumDuration == 15 * 60)
    }
}

@Test func automaticRecorderFailurePreservesAudioForRecovery() async throws {
    try await withCaptureFixture(permission: .granted) { fixture in
        await fixture.coordinator.beginCapture()
        await fixture.recorder.setAutomaticCompletion(.failed)
        await fixture.coordinator.finishWhenRecorderCompletes()

        let recoverable = try await fixture.store.recoverableRecordingURLs()
        let pending = try await fixture.store.loadPending()
        #expect(await fixture.coordinator.currentState == .failed(.recorderStop))
        #expect(recoverable.count == 1)
        #expect(pending.isEmpty)
    }
}

@Test func relaunchRecoveryCommitsInterruptedRecordingIntoDurableQueue() async throws {
    try await withCaptureFixture(permission: .granted) { fixture in
        let temporaryURL = await fixture.store.temporaryRecordingURL(for: fixture.memoID)
        try Data("interrupted voice".utf8).write(to: temporaryURL)

        await fixture.coordinator.recoverInterruptedCapture()

        let recoverable = try await fixture.store.recoverableRecordingURLs()
        #expect(await fixture.coordinator.currentState == .savedOnWatch(fixture.memoID))
        let recovered = try await fixture.store.load(memoID: fixture.memoID)
        #expect(recovered.metadata.durationMilliseconds == 875)
        #expect(recoverable.isEmpty)
    }
}

private enum RecorderFailure: Sendable {
    case start
    case stop
}

private actor StubWatchRecorder: WatchAudioRecording {
    private var permission: WatchRecordingPermission
    private let requestGrantsPermission: Bool
    private let failure: RecorderFailure?
    private var automaticCompletion: WatchRecordingCompletion = .cancelled
    private(set) var permissionRequestCount = 0
    private(set) var startCount = 0
    private(set) var requestedMaximumDuration: TimeInterval?

    init(
        permission: WatchRecordingPermission,
        requestGrantsPermission: Bool,
        failure: RecorderFailure?
    ) {
        self.permission = permission
        self.requestGrantsPermission = requestGrantsPermission
        self.failure = failure
    }

    func recordingPermission() -> WatchRecordingPermission {
        permission
    }

    func requestRecordingPermission() async -> Bool {
        permissionRequestCount += 1
        if requestGrantsPermission {
            permission = .granted
        } else {
            permission = .denied
        }
        return requestGrantsPermission
    }

    func startRecording(to url: URL, maximumDuration: TimeInterval) async throws {
        startCount += 1
        requestedMaximumDuration = maximumDuration
        if failure == .start {
            throw CaptureTestError.expected
        }
        try Data("recorded voice".utf8).write(to: url)
    }

    func stopRecording() async throws -> WatchRecordingResult {
        if failure == .stop {
            throw CaptureTestError.expected
        }
        return WatchRecordingResult(durationMilliseconds: 1_250)
    }

    func cancelRecording() async {}

    func waitForAutomaticCompletion() async -> WatchRecordingCompletion {
        automaticCompletion
    }

    func inspectRecording(at _: URL) async throws -> WatchRecordingResult {
        WatchRecordingResult(durationMilliseconds: 875)
    }

    func setAutomaticCompletion(_ completion: WatchRecordingCompletion) {
        automaticCompletion = completion
    }
}

private enum CaptureTestError: Error {
    case expected
}

private struct CaptureFixture: Sendable {
    let root: URL
    let memoID: MemoID
    let store: WatchMemoStore
    let recorder: StubWatchRecorder
    let coordinator: WatchCaptureCoordinator
}

private func withCaptureFixture(
    permission: WatchRecordingPermission,
    requestGrantsPermission: Bool = false,
    failure: RecorderFailure? = nil,
    maximumDuration: TimeInterval = 120,
    _ body: (CaptureFixture) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-watch-capture-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memoID = try MemoID("623e4567-e89b-12d3-a456-426614174000")
    let store = try WatchMemoStore(root: root)
    let recorder = StubWatchRecorder(
        permission: permission,
        requestGrantsPermission: requestGrantsPermission,
        failure: failure
    )
    let coordinator = WatchCaptureCoordinator(
        store: store,
        recorder: recorder,
        maximumDuration: maximumDuration,
        localeHint: "en-GB",
        memoIDProvider: { memoID },
        clock: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    try await body(.init(
        root: root,
        memoID: memoID,
        store: store,
        recorder: recorder,
        coordinator: coordinator
    ))
}
