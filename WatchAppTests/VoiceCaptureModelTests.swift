import CodexBridgeShared
import CodexWatchCore
import AVFAudio
import Combine
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CodexWatch

final class VoiceCaptureModelTests: XCTestCase {
    func testCapturePresentationNeverPromotesLocalSaveToMacOrCodex() throws {
        let memoID = try MemoID("11111111-1111-1111-1111-111111111111")

        let presentation = CaptureScenePresentation.make(
            captureState: .savedOnWatch(memoID),
            bridgeState: .waiting("Studio Mac")
        )

        XCTAssertEqual(presentation.kicker, "Saved on Watch")
        XCTAssertEqual(presentation.spine.watch, .confirmed)
        XCTAssertEqual(presentation.spine.mac, .pending)
        XCTAssertEqual(presentation.spine.codex, .pending)
        XCTAssertEqual(
            presentation.spine.accessibilityValue,
            "Saved on Watch; waiting for Mac"
        )
    }

    func testCapturePresentationCoversEveryLocalStateWithoutRemoteProgress() throws {
        let memoID = try MemoID("12121212-1212-1212-1212-121212121212")
        let cases: [(WatchCaptureState, WatchPrimaryAction, Bool, Bool)] = [
            (.idle, .record, false, false),
            (.preparing, .none, false, true),
            (.recording(memoID), .stopAndSave, true, false),
            (.saving(memoID), .none, false, true),
            (.savedOnWatch(memoID), .recordAnother, false, false),
            (.permissionDenied, .none, false, true),
            (.interruptedRecordingFound(1), .record, false, false),
            (.failed(.identifier), .none, false, true),
            (.failed(.recorderStart), .record, false, false),
            (.failed(.recorderStop), .record, false, false),
            (.failed(.queueCommit), .none, false, true),
            (.failed(.recovery), .none, false, true),
        ]

        for (state, action, showsElapsedTime, disabled) in cases {
            let presentation = CaptureScenePresentation.make(
                captureState: state,
                bridgeState: .paired("Studio Mac")
            )
            XCTAssertEqual(presentation.primaryAction, action, "state: \(state)")
            XCTAssertEqual(presentation.showsElapsedTime, showsElapsedTime, "state: \(state)")
            XCTAssertEqual(presentation.primaryActionDisabled, disabled, "state: \(state)")
            XCTAssertEqual(presentation.spine.mac, .pending, "state: \(state)")
            XCTAssertEqual(presentation.spine.codex, .pending, "state: \(state)")
        }
    }

    func testRelayPresentationMapsEveryMemoStateToLastConfirmedNode() throws {
        let memoID = try MemoID("22222222-2222-2222-2222-222222222222")
        let capturedAt = Date(timeIntervalSince1970: 100)
        let expected: [(MemoState, SignalNodeVisualState, SignalNodeVisualState)] = [
            (.saved, .pending, .pending),
            (.uploading, .active, .pending),
            (.received, .confirmed, .pending),
            (.transcribing, .confirmed, .active),
            (.readyForCodex, .confirmed, .active),
            (.inserting, .confirmed, .active),
            (.reconciling, .confirmed, .active),
            (.delivered, .confirmed, .confirmed),
            (.needsAttention, .attention, .pending),
        ]

        for (state, mac, codex) in expected {
            let item = WatchQueueItem(id: memoID, capturedAt: capturedAt, state: state)
            let presentation = RelayItemPresentation.make(item: item)
            XCTAssertEqual(presentation.spine.watch, .confirmed, "state: \(state)")
            XCTAssertEqual(presentation.spine.mac, mac, "state: \(state)")
            XCTAssertEqual(presentation.spine.codex, codex, "state: \(state)")
        }
    }

    func testRelayAttentionDoesNotInventItsPreviousRemotePhase() throws {
        let item = WatchQueueItem(
            id: try MemoID("23232323-2323-2323-2323-232323232323"),
            capturedAt: Date(timeIntervalSince1970: 100),
            state: .needsAttention
        )

        let presentation = RelayItemPresentation.make(item: item)

        XCTAssertEqual(presentation.status, "Needs attention")
        XCTAssertEqual(
            presentation.spine.accessibilityValue,
            "Needs attention; last remote phase unavailable"
        )
    }

    func testSignalMotionPolicyIsBoundedOrImmediate() {
        XCTAssertEqual(
            SignalMotionStyle.forTransition(reduceMotion: false),
            .bounded(duration: 0.24)
        )
        XCTAssertEqual(
            SignalMotionStyle.forTransition(reduceMotion: true),
            .immediate
        )
    }

    func testSignalSpineAccessibilityCombinesDecorativeNodes() {
        let spine = SignalSpinePresentation(
            watch: .confirmed,
            mac: .active,
            codex: .pending,
            accessibilityValue: "Saved on Watch; sending to Mac; Codex pending"
        )

        XCTAssertEqual(SignalSpineAccessibility.label, "Delivery path")
        XCTAssertEqual(
            SignalSpineAccessibility.value(for: spine),
            spine.accessibilityValue
        )
    }

    func testQueueStatusVocabularyMapsEveryInternalStateExactly() throws {
        let memoID = try MemoID("70707070-7070-7070-7070-707070707070")
        let capturedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .saved).statusText, "Saved on Watch")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .uploading).statusText, "Sending to Mac")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .received).statusText, "Adding to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .transcribing).statusText, "Adding to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .readyForCodex).statusText, "Adding to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .inserting).statusText, "Adding to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .reconciling).statusText, "Adding to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .delivered).statusText, "Saved to local Inbox")
        XCTAssertEqual(WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .needsAttention).statusText, "Needs attention")
    }

    func testDeletionWarningKeepsOnlyCopyRiskSpecificToUnresolvedAudio() throws {
        let memoID = try MemoID("70707070-7070-7070-7070-707070707071")
        let capturedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .saved).deletionWarning,
            "This unresolved recording may be the only copy. Deleting it cannot be undone."
        )
        XCTAssertEqual(
            WatchQueueItem(id: memoID, capturedAt: capturedAt, state: .delivered).deletionWarning,
            "This removes the retained audio from this Watch. The Inbox entry is not deleted."
        )
    }

    @MainActor
    func testPlaybackLoadsValidatedStoredAudioAndPublishesPlayingState() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-start")
        defer { fixture.cleanup() }
        let memoID = try MemoID("71717171-7171-7171-7171-717171717172")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await fixture.model.restore()

        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))

        let stored = try await fixture.store.load(memoID: memoID)
        XCTAssertEqual(fixture.player.playRequests, [.init(memoID: memoID, url: stored.audioURL)])
        XCTAssertEqual(fixture.model.playbackState, .playing(memoID))
    }

    @MainActor
    func testPlayingSecondMemoStopsFirstBeforeReplacement() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-replacement")
        defer { fixture.cleanup() }
        let firstID = try MemoID("72727272-7272-7272-7272-727272727272")
        let secondID = try MemoID("73737373-7373-7373-7373-737373737373")
        try await commitMemo(memoID: firstID, state: .saved, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: secondID, state: .saved, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 101))
        await fixture.model.restore()

        await fixture.model.togglePlayback(fixture.model.queueItems[0])
        await fixture.model.togglePlayback(fixture.model.queueItems[1])

        XCTAssertEqual(fixture.player.events, [.play(firstID), .stop, .play(secondID)])
        XCTAssertEqual(fixture.model.playbackState, .playing(secondID))
    }

    @MainActor
    func testPlaybackFailurePublishesFailedMemoWithoutLosingQueuedAudio() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-failure")
        defer { fixture.cleanup() }
        let memoID = try MemoID("74747474-7474-7474-7474-747474747474")
        try await commitMemo(memoID: memoID, state: .needsAttention, in: fixture.store)
        fixture.player.playError = PlaybackTestError.expected
        await fixture.model.restore()

        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))

        XCTAssertEqual(fixture.model.playbackState, .failed(memoID))
        _ = try await fixture.store.load(memoID: memoID)
    }

    @MainActor
    func testRecordingAttemptStopsPlaybackBeforeCaptureWork() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-recording")
        defer { fixture.cleanup() }
        let memoID = try MemoID("75757575-7575-7575-7575-757575757575")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await fixture.model.restore()
        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))

        await fixture.model.toggleRecording()

        XCTAssertEqual(fixture.player.events, [.play(memoID), .stop])
        XCTAssertEqual(fixture.model.playbackState, .stopped)
    }

    @MainActor
    func testPlaybackAttemptWhileRecordingNeverStartsAudio() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-playback-during-recording")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchMemoStore(root: root)
        let player = PlaybackSpy()
        let recorder = PlaybackTestRecorder()
        let coordinator = WatchCaptureCoordinator(store: store, recorder: recorder)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            captureCoordinator: coordinator,
            audioPlayer: player,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        let memoID = try MemoID("75757575-7575-7575-7575-757575757576")
        try await commitMemo(memoID: memoID, state: .saved, in: store)
        await model.restore()
        let item = try XCTUnwrap(model.queueItems.first)
        await model.toggleRecording()
        XCTAssertTrue(model.isRecording)

        await model.togglePlayback(item)

        XCTAssertTrue(player.events.isEmpty)
        XCTAssertEqual(model.playbackState, .stopped)
        await model.toggleRecording()
    }

    @MainActor
    func testRecordingStartInvalidatesSuspendedPlaybackLoad() async throws {
        let loader = SuspendedPlaybackLoader()
        let fixture = try PlaybackModelFixture(
            prefix: "watch-playback-load-recording",
            loader: loader,
            supportsRecording: true
        )
        defer { fixture.cleanup() }
        let memoID = try MemoID("75757575-7575-7575-7575-757575757577")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await loader.store(try await fixture.store.load(memoID: memoID))
        await fixture.model.restore()
        let item = try XCTUnwrap(fixture.model.queueItems.first)
        let playback = Task { @MainActor in await fixture.model.togglePlayback(item) }
        let startedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, memoID)

        await fixture.model.toggleRecording()
        await loader.resume(memoID: memoID)
        await playback.value

        XCTAssertTrue(fixture.model.isRecording)
        XCTAssertTrue(fixture.player.events.isEmpty)
        XCTAssertEqual(fixture.model.playbackState, .stopped)
        await fixture.model.toggleRecording()
    }

    @MainActor
    func testBackgroundInvalidatesSuspendedPlaybackLoad() async throws {
        let loader = SuspendedPlaybackLoader()
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-load-background", loader: loader)
        defer { fixture.cleanup() }
        let memoID = try MemoID("75757575-7575-7575-7575-757575757578")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await loader.store(try await fixture.store.load(memoID: memoID))
        await fixture.model.restore()
        let item = try XCTUnwrap(fixture.model.queueItems.first)
        let playback = Task { @MainActor in await fixture.model.togglePlayback(item) }
        let startedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, memoID)

        fixture.model.handleAppBecameInactive()
        await loader.resume(memoID: memoID)
        await playback.value

        XCTAssertTrue(fixture.player.events.isEmpty)
        XCTAssertEqual(fixture.model.playbackState, .stopped)
    }

    @MainActor
    func testQueueExitInvalidatesSuspendedPlaybackLoad() async throws {
        let loader = SuspendedPlaybackLoader()
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-load-navigation", loader: loader)
        defer { fixture.cleanup() }
        let memoID = try MemoID("75757575-7575-7575-7575-757575757579")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await loader.store(try await fixture.store.load(memoID: memoID))
        await fixture.model.restore()
        let item = try XCTUnwrap(fixture.model.queueItems.first)
        let playback = Task { @MainActor in await fixture.model.togglePlayback(item) }
        let startedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, memoID)

        fixture.model.handleQueueDisappeared()
        await loader.resume(memoID: memoID)
        await playback.value

        XCTAssertTrue(fixture.player.events.isEmpty)
        XCTAssertEqual(fixture.model.playbackState, .stopped)
    }

    @MainActor
    func testMatchingDeletionInvalidatesSuspendedPlaybackLoad() async throws {
        let loader = SuspendedPlaybackLoader()
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-load-deletion", loader: loader)
        defer { fixture.cleanup() }
        let memoID = try MemoID("75757575-7575-7575-7575-757575757580")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await loader.store(try await fixture.store.load(memoID: memoID))
        await fixture.model.restore()
        let item = try XCTUnwrap(fixture.model.queueItems.first)
        let playback = Task { @MainActor in await fixture.model.togglePlayback(item) }
        let startedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, memoID)

        await fixture.model.delete(item)
        await loader.resume(memoID: memoID)
        await playback.value

        XCTAssertTrue(fixture.player.events.isEmpty)
        XCTAssertEqual(fixture.model.playbackState, .stopped)
        await assertMemoIsMissing(memoID, from: fixture.store)
    }

    @MainActor
    func testRapidPlaybackRequestsCannotCompleteOutOfOrder() async throws {
        let loader = SuspendedPlaybackLoader()
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-load-order", loader: loader)
        defer { fixture.cleanup() }
        let firstID = try MemoID("75757575-7575-7575-7575-757575757581")
        let secondID = try MemoID("75757575-7575-7575-7575-757575757582")
        try await commitMemo(memoID: firstID, state: .saved, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: secondID, state: .saved, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 101))
        await loader.store(try await fixture.store.load(memoID: firstID))
        await loader.store(try await fixture.store.load(memoID: secondID))
        await fixture.model.restore()
        let first = Task { @MainActor in await fixture.model.togglePlayback(fixture.model.queueItems[0]) }
        let firstStartedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(firstStartedMemoID, firstID)
        let second = Task { @MainActor in await fixture.model.togglePlayback(fixture.model.queueItems[1]) }
        let secondStartedMemoID = await loader.nextStartedMemoID()
        XCTAssertEqual(secondStartedMemoID, secondID)

        await loader.resume(memoID: secondID)
        await second.value
        await loader.resume(memoID: firstID)
        await first.value

        XCTAssertEqual(fixture.player.events, [.play(secondID)])
        XCTAssertEqual(fixture.model.playbackState, .playing(secondID))
    }

    @MainActor
    func testBackgroundTransitionStopsPlayback() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-background")
        defer { fixture.cleanup() }
        let memoID = try MemoID("76767676-7676-7676-7676-767676767676")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await fixture.model.restore()
        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))

        fixture.model.handleAppBecameInactive()

        XCTAssertEqual(fixture.player.events, [.play(memoID), .stop])
        XCTAssertEqual(fixture.model.playbackState, .stopped)
    }

    @MainActor
    func testLeavingQueueStopsPlayback() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-navigation")
        defer { fixture.cleanup() }
        let memoID = try MemoID("77777777-7777-7777-7777-777777777777")
        try await commitMemo(memoID: memoID, state: .saved, in: fixture.store)
        await fixture.model.restore()
        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))

        fixture.model.handleQueueDisappeared()

        XCTAssertEqual(fixture.player.events, [.play(memoID), .stop])
        XCTAssertEqual(fixture.model.playbackState, .stopped)
    }

    @MainActor
    func testDeletingPlayingMemoStopsOnlyThatMemoAndRemovesIt() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-delete-active")
        defer { fixture.cleanup() }
        let memoID = try MemoID("78787878-7878-7878-7878-787878787878")
        try await commitMemo(memoID: memoID, state: .received, in: fixture.store)
        await fixture.model.restore()
        let item = try XCTUnwrap(fixture.model.queueItems.first)
        await fixture.model.togglePlayback(item)

        await fixture.model.delete(item)

        XCTAssertEqual(fixture.player.events, [.play(memoID), .stop])
        XCTAssertEqual(fixture.model.playbackState, .stopped)
        await assertMemoIsMissing(memoID, from: fixture.store)
    }

    @MainActor
    func testDeletingDifferentMemoKeepsCurrentPlaybackRunning() async throws {
        let fixture = try PlaybackModelFixture(prefix: "watch-playback-delete-other")
        defer { fixture.cleanup() }
        let playingID = try MemoID("79797979-7979-7979-7979-797979797979")
        let deletedID = try MemoID("80808080-8080-8080-8080-808080808080")
        try await commitMemo(memoID: playingID, state: .saved, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: deletedID, state: .transcribing, in: fixture.store, capturedAt: Date(timeIntervalSince1970: 101))
        await fixture.model.restore()
        await fixture.model.togglePlayback(fixture.model.queueItems[0])

        await fixture.model.delete(fixture.model.queueItems[1])

        XCTAssertEqual(fixture.player.events, [.play(playingID)])
        XCTAssertEqual(fixture.model.playbackState, .playing(playingID))
        _ = try await fixture.store.load(memoID: playingID)
        await assertMemoIsMissing(deletedID, from: fixture.store)
    }

    @MainActor
    func testDeletingMemoOutsideActiveUploadDoesNotCancelAnotherMemosWork() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-delete-nonactive-upload")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeID = try MemoID("80808080-8080-8080-8080-808080808081")
        let deletedID = try MemoID("80808080-8080-8080-8080-808080808082")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: activeID, state: .saved, in: store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: deletedID, state: .saved, in: store, capturedAt: Date(timeIntervalSince1970: 101))
        let transport = BlockingUploadTransport()
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: TestWatchBridgeCredentialStore(try makeWatchCredential()),
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        let restore = Task { @MainActor in await model.restore() }
        let startedMemoID = await transport.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, activeID)
        let item = try XCTUnwrap(model.queueItems.first(where: { $0.id == deletedID }))

        await model.delete(item)

        await assertMemoIsMissing(deletedID, from: store)
        _ = try await store.load(memoID: activeID)
        let cancelledMemoIDs = await transport.cancelledMemoIDs
        XCTAssertTrue(cancelledMemoIDs.isEmpty)
        await transport.completeUpload(memoID: activeID)
        await restore.value
    }

    @MainActor
    func testDeletingActivelyUploadingMemoCancelsOnlyThatMemoBeforeRemoval() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-delete-active-upload")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeID = try MemoID("80808080-8080-8080-8080-808080808083")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: activeID, state: .saved, in: store)
        let transport = BlockingUploadTransport()
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: TestWatchBridgeCredentialStore(try makeWatchCredential()),
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        let restore = Task { @MainActor in await model.restore() }
        let startedMemoID = await transport.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, activeID)
        let item = try XCTUnwrap(model.queueItems.first)

        await model.delete(item)

        let memoWasDeleted: Bool
        do {
            _ = try await store.load(memoID: activeID)
            memoWasDeleted = false
        } catch WatchMemoStoreError.notFound {
            memoWasDeleted = true
        }
        await transport.completeUpload(memoID: activeID)
        await restore.value
        let cancelledMemoIDs = await transport.cancelledMemoIDs
        XCTAssertTrue(memoWasDeleted)
        XCTAssertEqual(cancelledMemoIDs, [activeID])
    }

    @MainActor
    func testDeletingActivelyPolledMemoCancelsOnlyThatMemoBeforeRemoval() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-delete-active-status")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeID = try MemoID("80808080-8080-8080-8080-808080808084")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: activeID, state: .received, in: store)
        let transport = BlockingStatusTransport()
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: TestWatchBridgeCredentialStore(try makeWatchCredential()),
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        let restore = Task { @MainActor in await model.restore() }
        let startedMemoID = await transport.nextStartedMemoID()
        XCTAssertEqual(startedMemoID, activeID)
        let item = try XCTUnwrap(model.queueItems.first)

        await model.delete(item)

        await assertMemoIsMissing(activeID, from: store)
        await transport.completeStatus(memoID: activeID)
        await restore.value
        let cancelledMemoIDs = await transport.cancelledMemoIDs
        XCTAssertEqual(cancelledMemoIDs, [activeID])
    }

    @MainActor
    func testDeletingFirstMemoPreservesActualSecondStatusOperation() async throws {
        let fixture = try await MultiMemoStatusDeletionFixture(prefix: "watch-delete-first-status")
        defer { fixture.cleanup() }
        let restore = Task { @MainActor in await fixture.model.restore() }
        let blockingMemoID = await fixture.transport.nextBlockingMemoID()
        XCTAssertEqual(blockingMemoID, fixture.secondID)

        let first = try XCTUnwrap(fixture.model.queueItems.first(where: { $0.id == fixture.firstID }))
        await fixture.model.delete(first)

        let cancelledMemoIDs = await fixture.transport.cancelledMemoIDs
        XCTAssertTrue(cancelledMemoIDs.isEmpty)
        await assertMemoIsMissing(fixture.firstID, from: fixture.store)
        _ = try await fixture.store.load(memoID: fixture.secondID)
        await fixture.transport.releaseBlockingStatus()
        await restore.value
    }

    @MainActor
    func testDeletingActualSecondStatusMemoCancelsAndAwaitsItsOperation() async throws {
        let fixture = try await MultiMemoStatusDeletionFixture(prefix: "watch-delete-second-status")
        defer { fixture.cleanup() }
        let restore = Task { @MainActor in await fixture.model.restore() }
        let blockingMemoID = await fixture.transport.nextBlockingMemoID()
        XCTAssertEqual(blockingMemoID, fixture.secondID)

        let second = try XCTUnwrap(fixture.model.queueItems.first(where: { $0.id == fixture.secondID }))
        await fixture.model.delete(second)

        let cancelledMemoIDs = await fixture.transport.cancelledMemoIDs
        XCTAssertEqual(cancelledMemoIDs, [fixture.secondID])
        _ = try await fixture.store.load(memoID: fixture.firstID)
        await assertMemoIsMissing(fixture.secondID, from: fixture.store)
        await fixture.transport.releaseBlockingStatus()
        await restore.value
    }

    @MainActor
    func testDeletingFirstMemoPreservesActualSecondFinalAckOperation() async throws {
        let fixture = try await MultiMemoFinalAckDeletionFixture(prefix: "watch-delete-first-final-ack")
        defer { fixture.cleanup() }
        let restore = Task { @MainActor in await fixture.model.restore() }
        let blockingMemoID = await fixture.transport.nextBlockingMemoID()
        XCTAssertEqual(blockingMemoID, fixture.secondID)

        let first = try XCTUnwrap(fixture.model.queueItems.first(where: { $0.id == fixture.firstID }))
        await fixture.model.delete(first)

        let cancelledMemoIDs = await fixture.transport.cancelledMemoIDs
        XCTAssertTrue(cancelledMemoIDs.isEmpty)
        await assertMemoIsMissing(fixture.firstID, from: fixture.store)
        _ = try await fixture.store.load(memoID: fixture.secondID)
        await fixture.transport.releaseBlockingAcknowledgement()
        await restore.value
    }

    @MainActor
    func testDeletingActualSecondFinalAckMemoCancelsAndAwaitsItsOperation() async throws {
        let fixture = try await MultiMemoFinalAckDeletionFixture(prefix: "watch-delete-second-final-ack")
        defer { fixture.cleanup() }
        let restore = Task { @MainActor in await fixture.model.restore() }
        let blockingMemoID = await fixture.transport.nextBlockingMemoID()
        XCTAssertEqual(blockingMemoID, fixture.secondID)

        let second = try XCTUnwrap(fixture.model.queueItems.first(where: { $0.id == fixture.secondID }))
        await fixture.model.delete(second)

        let cancelledMemoIDs = await fixture.transport.cancelledMemoIDs
        XCTAssertEqual(cancelledMemoIDs, [fixture.secondID])
        _ = try await fixture.store.load(memoID: fixture.firstID)
        await assertMemoIsMissing(fixture.secondID, from: fixture.store)
        await fixture.transport.releaseBlockingAcknowledgement()
        await restore.value
    }

    @MainActor
    func testEveryLocallyRetainedStateAllowsConfirmedPerMemoDeletion() async throws {
        let states: [MemoState] = [
            .saved, .uploading, .received, .transcribing, .readyForCodex,
            .inserting, .reconciling, .delivered, .needsAttention,
        ]
        for (index, state) in states.enumerated() {
            let fixture = try PlaybackModelFixture(prefix: "watch-delete-state-\(index)")
            defer { fixture.cleanup() }
            let memoID = try MemoID(String(format: "81818181-8181-8181-8181-%012d", index))
            try await commitMemo(memoID: memoID, state: state, in: fixture.store)
            await fixture.model.restore()

            await fixture.model.delete(try XCTUnwrap(fixture.model.queueItems.first))

            await assertMemoIsMissing(memoID, from: fixture.store)
            let acknowledgements = try await fixture.store.pendingFinalAcknowledgements()
            XCTAssertTrue(acknowledgements.isEmpty)
        }
    }

    @MainActor
    func testDeliveredAudioStaysVisibleUntilRetentionMaintenancePurgesIt() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-delivered-playback-retention")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableModelTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let memoID = try MemoID("82828282-8282-8282-8282-828282828282")
        try await commitMemo(memoID: memoID, state: .delivered, in: store)
        let player = PlaybackSpy()
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            audioPlayer: player,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: { clock.now }
        )

        await model.restore()
        model.handleQueueAppeared()
        XCTAssertEqual(model.queueItems.map(\.id), [memoID])
        XCTAssertEqual(model.queueItems.first?.statusText, "Saved to local Inbox")
        await model.togglePlayback(try XCTUnwrap(model.queueItems.first))
        XCTAssertEqual(model.playbackState, .playing(memoID))

        clock.now = clock.now.addingTimeInterval(7 * 24 * 60 * 60 + 1)
        await model.handleAppBecameActive()

        XCTAssertTrue(model.queueItems.isEmpty)
        XCTAssertEqual(model.playbackState, .stopped)
        await assertMemoIsMissing(memoID, from: store)
    }

    @MainActor
    func testRealPlayerMissingFileFailureIsMemoSpecificAndStopIsDeterministic() throws {
        let player = WatchAudioPlayer()
        let memoID = try MemoID("83838383-8383-8383-8383-838383838383")
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        XCTAssertThrowsError(try player.play(memoID: memoID, url: missingURL))
        XCTAssertEqual(player.state, .failed(memoID))

        player.stop()
        player.stop()
        XCTAssertEqual(player.state, .stopped)
    }

    @MainActor
    func testRealPlayerRejectsReplacementBeforeCreationAndRetainsLeaseUntilStop() throws {
        let root = try makeTemporaryDirectory(prefix: "watch-playback-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("memo.m4a")
        let originalURL = root.appendingPathComponent("memo.original.m4a")
        let audio = makeSilentWaveData()
        try audio.write(to: audioURL)
        try setPrivatePermissions(audioURL)
        let factoryProbe = AudioPlayerFactoryProbe()
        let memoID = try MemoID("83838383-8383-8383-8383-838383838381")
        let replacingPlayer = WatchAudioPlayer(
            playerFactory: { _ in
                factoryProbe.creationCount += 1
                return try AVAudioPlayer(data: audio)
            },
            beforePlayerCreation: {
                try FileManager.default.moveItem(at: audioURL, to: originalURL)
                try audio.write(to: audioURL)
                try setPrivatePermissions(audioURL)
            }
        )

        XCTAssertThrowsError(try replacingPlayer.play(memoID: memoID, url: audioURL)) { error in
            XCTAssertEqual(error as? WatchPlaybackFileLeaseError, .identityDrift)
        }
        XCTAssertEqual(factoryProbe.creationCount, 0)
        XCTAssertFalse(replacingPlayer.hasActivePlaybackLease)

        let retainedPlayer = WatchAudioPlayer(playerFactory: { _ in
            factoryProbe.creationCount += 1
            return try AVAudioPlayer(data: audio)
        })
        try retainedPlayer.play(memoID: memoID, url: audioURL)
        XCTAssertTrue(retainedPlayer.hasActivePlaybackLease)

        retainedPlayer.stop()

        XCTAssertFalse(retainedPlayer.hasActivePlaybackLease)
        XCTAssertEqual(retainedPlayer.state, .stopped)
    }

    @MainActor
    func testUnsuccessfulAsyncPlaybackCompletionFailsMemoAndHapticsExactlyOnce() async throws {
        let fixture = try await AsyncPlaybackFailureFixture(prefix: "watch-playback-unsuccessful-completion")
        defer { fixture.cleanup() }
        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))
        let systemPlayer = try XCTUnwrap(fixture.playerProbe.player)

        fixture.player.audioPlayerDidFinishPlaying(systemPlayer, successfully: false)
        fixture.player.audioPlayerDecodeErrorDidOccur(systemPlayer, error: PlaybackTestError.expected)

        XCTAssertEqual(fixture.model.playbackState, .failed(fixture.memoID))
        XCTAssertEqual(fixture.hapticProbe.failureCount, 1)
    }

    @MainActor
    func testAsyncDecodeFailureFailsMemoAndHapticsExactlyOnce() async throws {
        let fixture = try await AsyncPlaybackFailureFixture(prefix: "watch-playback-decode-failure")
        defer { fixture.cleanup() }
        await fixture.model.togglePlayback(try XCTUnwrap(fixture.model.queueItems.first))
        let systemPlayer = try XCTUnwrap(fixture.playerProbe.player)

        fixture.player.audioPlayerDecodeErrorDidOccur(systemPlayer, error: PlaybackTestError.expected)
        fixture.player.audioPlayerDidFinishPlaying(systemPlayer, successfully: false)

        XCTAssertEqual(fixture.model.playbackState, .failed(fixture.memoID))
        XCTAssertEqual(fixture.hapticProbe.failureCount, 1)
    }

    func testDeliveredQueueItemNamesTheVerifiedCodexOutcome() throws {
        let memoID = try MemoID("71717171-7171-7171-7171-717171717171")

        XCTAssertEqual(
            WatchQueueItem(id: memoID, capturedAt: .distantPast, state: .delivered).statusText,
            "Saved to local Inbox"
        )
    }

    @MainActor
    func testApplicationBackgroundRefreshRunsWorkSchedulesNextAndCompletes() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var didRun = false
        var scheduledDates: [Date] = []
        let coordinator = WatchBackgroundRefreshCoordinator(
            interval: 15 * 60,
            clock: { now },
            work: { didRun = true },
            schedule: { scheduledDates.append($0) }
        )
        let task = BackgroundRefreshTaskStub(isApplicationRefresh: true)

        coordinator.handle([task])
        for _ in 0 ..< 100 where task.completionCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(didRun)
        XCTAssertEqual(scheduledDates, [now.addingTimeInterval(15 * 60)])
        XCTAssertEqual(task.completionCount, 1)
    }

    @MainActor
    func testUnrecognizedBackgroundTaskCompletesWithoutRunningOrRescheduling() async {
        var didRun = false
        var scheduledDates: [Date] = []
        let coordinator = WatchBackgroundRefreshCoordinator(
            work: { didRun = true },
            schedule: { scheduledDates.append($0) }
        )
        let task = BackgroundRefreshTaskStub(isApplicationRefresh: false)

        coordinator.handle([task])
        await Task.yield()

        XCTAssertFalse(didRun)
        XCTAssertTrue(scheduledDates.isEmpty)
        XCTAssertEqual(task.completionCount, 1)
    }

    @MainActor
    func testRecordingLimitMatchesProtocolAndWarnsDuringTheFinalMinute() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-recording-limit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VoiceCaptureModel(
            storeForTesting: WatchMemoStore(root: root),
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(model.maximumDuration, 15 * 60)
        XCTAssertEqual(
            model.recordingLimitDetail(from: startedAt, to: startedAt.addingTimeInterval(839)),
            "Tap to stop"
        )
        XCTAssertEqual(
            model.recordingLimitDetail(from: startedAt, to: startedAt.addingTimeInterval(840)),
            "1 minute remaining"
        )
        XCTAssertEqual(
            model.recordingLimitDetail(from: startedAt, to: startedAt.addingTimeInterval(890)),
            "10 seconds remaining"
        )
        XCTAssertEqual(
            model.recordingLimitDetail(from: startedAt, to: startedAt.addingTimeInterval(900)),
            "Finishing recording"
        )
    }

    @MainActor
    func testExpiredBackgroundRefreshCancelsWorkAndCompletesExactlyOnce() async {
        var workStarted = false
        var didCancelWork = false
        var scheduledDates: [Date] = []
        let coordinator = WatchBackgroundRefreshCoordinator(
            work: {
                workStarted = true
                try? await Task.sleep(for: .seconds(10))
            },
            cancelWork: { didCancelWork = true },
            schedule: { scheduledDates.append($0) }
        )
        let task = BackgroundRefreshTaskStub(isApplicationRefresh: true)

        coordinator.handle([task])
        for _ in 0 ..< 100 where !workStarted {
            await Task.yield()
        }
        task.expirationHandler?()
        for _ in 0 ..< 100 where task.completionCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(workStarted)
        XCTAssertTrue(didCancelWork)
        XCTAssertTrue(scheduledDates.isEmpty)
        XCTAssertEqual(task.completionCount, 1)
    }

    func testPinnedDelegateImplementsTaskLevelAuthenticationChallengeCallback() throws {
        let pin = try CertificatePin(String(repeating: "a", count: 64))
        let delegate = PinnedBridgeSessionDelegate(expectedPin: pin)
        let callback = NSSelectorFromString(
            "URLSession:task:didReceiveChallenge:completionHandler:"
        )

        XCTAssertTrue(delegate.responds(to: callback))
    }

    func testWatchUploadUsesFileWithoutMaterializingThirtyTwoMiBBody() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-file-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("audio.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: nil))
        let byteCount = 32 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: audioURL)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: audioURL.path
        )
        let memoID = try MemoID("123e4567-e89b-12d3-a456-426614174000")
        let saved = try VoiceMemoMetadata(
            memoID: memoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioSHA256: String(repeating: "a", count: 64),
            byteCount: Int64(byteCount),
            durationMilliseconds: 1_000
        )
        let memo = try MemoStateTransition.transition(saved, to: .uploading, revision: 1)
        let receipt = try BridgeReceipt(
            memoID: memoID,
            audioSHA256: memo.audioSHA256,
            acknowledgedRevision: 2,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let uploader = RecordingWatchFileUploader(
            result: (
                try JSONEncoder().encode(BridgeEnvelope(payload: receipt)),
                HTTPURLResponse(
                    url: URL(string: "https://bridge.test/v1/memos/\(memoID.rawValue)")!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["content-type": "application/json"]
                )!
            )
        )
        let credential = try WatchBridgeCredential(
            bridgeName: "Test Mac",
            baseURL: URL(string: "https://bridge.test")!,
            certificatePin: CertificatePin(String(repeating: "a", count: 64)),
            tokenHex: String(repeating: "33", count: 32)
        )
        let transport = HTTPSBridgeTransport(
            credentialStore: TestWatchBridgeCredentialStore(credential),
            fileUploader: uploader
        )

        let uploaded = try await transport.upload(
            memo: memo,
            audioURL: audioURL,
            expectedRevision: 2
        )
        XCTAssertEqual(uploaded, receipt)
        let recordedInvocation = await uploader.invocation
        let invocation = try XCTUnwrap(recordedInvocation)
        XCTAssertEqual(invocation.fileURL, audioURL)
        XCTAssertNil(invocation.request.httpBody)
        XCTAssertEqual(invocation.request.value(forHTTPHeaderField: "content-length"), String(byteCount))
        XCTAssertEqual(invocation.maximumResponseBytes, 64 * 1_024)
    }

    func testMissingStatusRecoveryUploadsSameFileAndOriginalAcceptedRevision() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-status-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("audio.m4a")
        let audio = Data("preserved audio".utf8)
        try audio.write(to: audioURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: audioURL.path
        )
        let memoID = try MemoID("223e4567-e89b-12d3-a456-426614174000")
        let memo = try VoiceMemoMetadata(
            memoID: memoID,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioSHA256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(audio.count),
            durationMilliseconds: 1_000,
            localeHint: "pl-PL",
            state: .received,
            stateRevision: 2
        )
        let receipt = try BridgeReceipt(
            memoID: memoID,
            audioSHA256: memo.audioSHA256,
            acknowledgedRevision: 2,
            capturedAt: memo.capturedAt,
            localeHint: memo.localeHint,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let uploader = RecordingWatchFileUploader(result: (
            try JSONEncoder().encode(BridgeEnvelope(payload: receipt)),
            HTTPURLResponse(
                url: URL(string: "https://bridge.test/v1/memos/\(memoID.rawValue)")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["content-type": "application/json"]
            )!
        ))
        let credential = try WatchBridgeCredential(
            bridgeName: "Test Mac",
            baseURL: URL(string: "https://bridge.test")!,
            certificatePin: CertificatePin(String(repeating: "a", count: 64)),
            tokenHex: String(repeating: "33", count: 32)
        )
        let transport = HTTPSBridgeTransport(
            credentialStore: TestWatchBridgeCredentialStore(credential),
            fileUploader: uploader
        )

        try await transport.recoverAbsentStatus(memo: memo, audioURL: audioURL)

        let recordedInvocation = await uploader.invocation
        let invocation = try XCTUnwrap(recordedInvocation)
        XCTAssertEqual(invocation.fileURL, audioURL)
        XCTAssertEqual(invocation.request.url?.path, "/v1/memos/\(memoID.rawValue)")
        XCTAssertEqual(invocation.request.value(forHTTPHeaderField: "x-codex-revision"), "1")
        XCTAssertEqual(invocation.request.value(forHTTPHeaderField: "x-codex-body-sha256"), memo.audioSHA256)
    }

    func testValidatedUploadLeaseRejectsPathIdentityDriftBeforeTaskCreation() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-upload-identity-drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("audio.m4a")
        let replacementURL = root.appendingPathComponent("replacement.m4a")
        try Data("same".utf8).write(to: audioURL)
        try Data("same".utf8).write(to: replacementURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: audioURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: replacementURL.path
        )
        let lease = try ValidatedFileUploadLease(
            fileURL: audioURL,
            expectedByteCount: 4
        )
        XCTAssertEqual(Darwin.rename(replacementURL.path, audioURL.path), 0)
        let taskFactory = RecordingURLSessionUploadTaskFactory()
        let uploader = URLSessionWatchFileUploader(
            configuration: .ephemeral,
            taskFactory: taskFactory
        )

        do {
            _ = try await uploader.upload(
                request: URLRequest(url: URL(string: "https://bridge.test/upload")!),
                lease: lease,
                expectedPin: CertificatePin(String(repeating: "a", count: 64)),
                maximumResponseBytes: 64 * 1_024
            )
            XCTFail("identity drift should reject before task creation")
        } catch WatchFileUploadLeaseError.identityDrift {
            XCTAssertEqual(taskFactory.creationCount, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUploadResponseCollectorRegistersBeforeResumeAndCompletesExactlyOnce() async throws {
        let collector = BoundedUploadResponseCollector()
        let url = URL(string: "https://bridge.test/upload")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-length": "2"]
        )!
        let task = RecordingUploadTask(taskIdentifier: 7)
        task.onResume = {
            XCTAssertTrue(collector.receive(response: response, taskIdentifier: 7))
            collector.receive(data: Data("ok".utf8), taskIdentifier: 7)
            collector.complete(taskIdentifier: 7, error: nil)
            collector.complete(taskIdentifier: 7, error: WatchBridgeTransportFailure.transient)
        }

        let (body, receivedResponse) = try await collector.response(for: task, maximumBytes: 64 * 1_024)

        XCTAssertEqual(body, Data("ok".utf8))
        XCTAssertEqual((receivedResponse as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(task.resumeCount, 1)
        XCTAssertEqual(task.cancelCount, 0)
    }

    func testUploadResponseCollectorCancelsAtSixtyFourKiBOverflowAndCompletesOnce() async {
        let collector = BoundedUploadResponseCollector()
        let response = HTTPURLResponse(
            url: URL(string: "https://bridge.test/upload")!,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        let task = RecordingUploadTask(taskIdentifier: 8)
        task.onResume = {
            XCTAssertTrue(collector.receive(response: response, taskIdentifier: 8))
            collector.receive(data: Data(repeating: 0x61, count: 64 * 1_024), taskIdentifier: 8)
            collector.receive(data: Data([0x62]), taskIdentifier: 8)
            collector.complete(taskIdentifier: 8, error: nil)
        }

        do {
            _ = try await collector.response(for: task, maximumBytes: 64 * 1_024)
            XCTFail("response overflow should fail")
        } catch {
            XCTAssertEqual(task.resumeCount, 1)
            XCTAssertEqual(task.cancelCount, 1)
        }
    }

    func testUploadResponseCollectorDoesNotResumeAnAlreadyCancelledTask() async {
        let collector = BoundedUploadResponseCollector()
        let task = RecordingUploadTask(taskIdentifier: 9)

        let outcome = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await collector.response(for: task, maximumBytes: 64 * 1_024)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(outcome)
        XCTAssertEqual(task.resumeCount, 0)
        XCTAssertGreaterThanOrEqual(task.cancelCount, 1)
    }

    func testUploadResponseCollectorCancellationAtRegisteredBoundaryPreventsResume() async {
        let collector = BoundedUploadResponseCollector(
            startBoundary: BridgeUploadStartBoundary {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let task = RecordingUploadTask(taskIdentifier: 10)

        do {
            _ = try await collector.response(for: task, maximumBytes: 64 * 1_024)
            XCTFail("boundary cancellation should fail")
        } catch is CancellationError {
            XCTAssertEqual(task.resumeCount, 0)
            XCTAssertGreaterThanOrEqual(task.cancelCount, 1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testDiscoveryChangesInvalidateTheEnvironmentModelPresentation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-discovery-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchMemoStore(root: root)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        var invalidationCount = 0
        let observation = model.objectWillChange.sink {
            invalidationCount += 1
        }

        model.discovery.objectWillChange.send()

        XCTAssertEqual(invalidationCount, 1)
        withExtendedLifetime(observation) {}
    }

    func testBridgeAttentionTitleFitsTheCompactHomeStatusControl() {
        XCTAssertEqual(
            WatchBridgeConnectionState.needsAttention("repair").title,
            "Bridge attention"
        )
    }

    @MainActor
    func testForegroundMaintenanceReconsidersYoungDeliveredAudioAfterRetentionCutoff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-lifecycle-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memoID = try MemoID("dddddddd-dddd-dddd-dddd-dddddddddddd")
        let capturedAt = Date(timeIntervalSince1970: 100)
        let clock = MutableModelTestClock(capturedAt)
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let temporary = await store.temporaryRecordingURL(for: memoID)
        try Data("delivered-audio".utf8).write(to: temporary)
        _ = try await store.commitRecording(
            temporaryURL: temporary,
            memoID: memoID,
            capturedAt: capturedAt,
            durationMilliseconds: 100,
            localeHint: nil
        )
        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: memoID, to: state)
        }
        clock.now = clock.now.addingTimeInterval(7 * 24 * 60 * 60)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: { clock.now }
        )

        await model.restore()
        _ = try await store.load(memoID: memoID)

        clock.now = clock.now.addingTimeInterval(1)
        await model.handleAppBecameActive()
        do {
            _ = try await store.load(memoID: memoID)
            XCTFail("expired delivered audio should be removed on a later active lifecycle")
        } catch WatchMemoStoreError.notFound {
        }
    }

    @MainActor
    func testDeliveredRetentionDefaultsToSevenDaysWhenNoValueIsStored() throws {
        let preferences = InMemoryRetentionPreferences(days: 0)
        let fixture = try RetentionModelFixture(preferences: preferences)

        XCTAssertEqual(fixture.model.deliveredRetentionChoice, .sevenDays)
        XCTAssertEqual(preferences.deliveredRetentionDays, 7)
    }

    @MainActor
    func testDeliveredRetentionPersistsAcrossModelReconstruction() async throws {
        let preferences = InMemoryRetentionPreferences(days: 30)
        let fixture = try RetentionModelFixture(preferences: preferences)

        await fixture.model.setDeliveredRetentionChoice(.oneDay)

        let relaunchedFixture = try RetentionModelFixture(preferences: preferences)
        XCTAssertEqual(relaunchedFixture.model.deliveredRetentionChoice, .oneDay)
        XCTAssertEqual(preferences.deliveredRetentionDays, 1)
    }

    @MainActor
    func testUnsupportedStoredRetentionValueNormalizesToSevenDays() throws {
        let preferences = InMemoryRetentionPreferences(days: 14)
        let fixture = try RetentionModelFixture(preferences: preferences)

        XCTAssertEqual(fixture.model.deliveredRetentionChoice, .sevenDays)
        XCTAssertEqual(preferences.deliveredRetentionDays, 7)
    }

    @MainActor
    func testChangingRetentionFromThirtyToOneDayImmediatelyPurgesExpiredDeliveredAudio() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-retention-immediate")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableModelTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let deliveredID = try MemoID("12121212-1212-1212-1212-121212121212")
        try await commitMemo(memoID: deliveredID, state: .delivered, in: store)
        clock.now = clock.now.addingTimeInterval(2 * 24 * 60 * 60)
        let preferences = InMemoryRetentionPreferences(days: 30)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: preferences,
            clock: { clock.now }
        )

        await model.setDeliveredRetentionChoice(.oneDay)

        XCTAssertEqual(model.deliveredRetentionChoice, .oneDay)
        XCTAssertEqual(preferences.deliveredRetentionDays, 1)
        await assertMemoIsMissing(deliveredID, from: store)
    }

    @MainActor
    func testChangingRetentionRefreshesPublishedQueueAfterImmediateCleanup() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-retention-published-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableModelTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let deliveredID = try MemoID("16161616-1616-1616-1616-161616161616")
        try await commitMemo(memoID: deliveredID, state: .saved, in: store)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 30),
            clock: { clock.now }
        )

        await model.handleAppBecameActive()
        XCTAssertEqual(model.queueItems.map(\.id), [deliveredID])

        for state in [
            MemoState.uploading, .received, .transcribing,
            .readyForCodex, .inserting, .delivered,
        ] {
            _ = try await store.transition(memoID: deliveredID, to: state)
        }
        clock.now = clock.now.addingTimeInterval(2 * 24 * 60 * 60)

        await model.setDeliveredRetentionChoice(.oneDay)

        await assertMemoIsMissing(deliveredID, from: store)
        XCTAssertTrue(model.queueItems.isEmpty)
    }

    @MainActor
    func testRetentionMaintenanceFailureKeepsPreferenceAndQueuedDeliveredAudio() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-retention-maintenance-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WatchMemoStore(root: root)
        let deliveredID = try MemoID("13131313-1313-1313-1313-131313131313")
        let savedID = try MemoID("17171717-1717-1717-1717-171717171717")
        try await commitMemo(memoID: deliveredID, state: .delivered, in: store)
        try await commitMemo(memoID: savedID, state: .saved, in: store)
        let preferences = InMemoryRetentionPreferences(days: 30)
        let maintainer = FailingRetentionMaintainer()
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: preferences,
            clock: Date.init,
            retentionMaintainerFactory: { _ in maintainer }
        )

        await model.handleAppBecameActive()
        XCTAssertEqual(model.queueItems.map(\.id), [deliveredID, savedID])

        await model.setDeliveredRetentionChoice(.oneDay)

        XCTAssertEqual(model.deliveredRetentionChoice, .oneDay)
        XCTAssertEqual(preferences.deliveredRetentionDays, 1)
        _ = try await store.load(memoID: deliveredID)
        XCTAssertEqual(model.queueItems.map(\.id), [deliveredID, savedID])
        let maintenanceCount = await maintainer.performCount
        XCTAssertEqual(maintenanceCount, 2)
    }

    @MainActor
    func testChangingRetentionNeverPurgesWaitingOrAttentionAudio() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-retention-unresolved")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = MutableModelTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try WatchMemoStore(root: root, clock: { clock.now })
        let waitingID = try MemoID("14141414-1414-1414-1414-141414141414")
        let attentionID = try MemoID("15151515-1515-1515-1515-151515151515")
        try await commitMemo(memoID: waitingID, state: .saved, in: store)
        try await commitMemo(memoID: attentionID, state: .needsAttention, in: store)
        clock.now = clock.now.addingTimeInterval(60 * 24 * 60 * 60)
        let preferences = InMemoryRetentionPreferences(days: 30)
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            retentionPreferenceStore: preferences,
            clock: { clock.now }
        )

        await model.setDeliveredRetentionChoice(.oneDay)

        XCTAssertEqual(preferences.deliveredRetentionDays, 1)
        _ = try await store.load(memoID: waitingID)
        _ = try await store.load(memoID: attentionID)
    }

    func testSavedCredentialKeepsForgetEscapeHatchVisibleDuringAttention() {
        let attention = WatchBridgeConnectionState.needsAttention("repair")

        XCTAssertFalse(attention.isPaired)
        XCTAssertTrue(BridgeCredentialPresentation.showsSavedBridge(hasSavedCredential: true))
        XCTAssertFalse(BridgeCredentialPresentation.showsSavedBridge(hasSavedCredential: false))
    }

    func testRetryScheduleWakesAtPersistedDeadline() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            BridgeRetrySchedule.nanosecondsUntilRetry(
                now: now,
                notBefore: now.addingTimeInterval(5)
            ),
            5_000_000_000
        )
        XCTAssertEqual(
            BridgeRetrySchedule.nanosecondsUntilRetry(
                now: now,
                notBefore: now.addingTimeInterval(-1)
            ),
            0
        )
    }

    func testStatusPollingUsesFullJitterWithinFifteenMinuteBound() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            BridgeRetrySchedule.statusPollNotBefore(now: now, attempt: 1, sample: 0),
            now
        )
        XCTAssertEqual(
            BridgeRetrySchedule.statusPollNotBefore(now: now, attempt: 1, sample: 0.5),
            now.addingTimeInterval(2.5)
        )
        XCTAssertEqual(
            BridgeRetrySchedule.statusPollNotBefore(now: now, attempt: 1, sample: 1),
            now.addingTimeInterval(5)
        )
        XCTAssertEqual(
            BridgeRetrySchedule.statusPollNotBefore(now: now, attempt: 100, sample: 1),
            now.addingTimeInterval(900)
        )
    }

    func testRejectedUploadOnlyHidesForgetWhenCredentialIsConfirmedMissing() {
        let missing = BridgeCredentialPresentation.afterRejectedUpload(readStatus: .missing)
        let present = BridgeCredentialPresentation.afterRejectedUpload(readStatus: .present)
        let unreadable = BridgeCredentialPresentation.afterRejectedUpload(readStatus: .unreadable)

        XCTAssertEqual(missing, .init(hasSavedCredential: false, state: .notPaired))
        XCTAssertTrue(present.hasSavedCredential)
        XCTAssertEqual(
            present.state,
            .needsAttention("The bridge rejected this recording. The audio remains on this Watch.")
        )
        XCTAssertTrue(unreadable.hasSavedCredential)
        XCTAssertEqual(
            unreadable.state,
            .needsAttention("The saved bridge credential couldn’t be read.")
        )
    }

    func testPairingFlowUsesExactPairAgainRecoveryHeadline() {
        XCTAssertEqual(
            BridgeCredentialPresentation.discoveryHeadline(
                bridgeState: .needsAttention("Pair again"),
                discoveryUnavailable: false
            ),
            "Pair again"
        )
        XCTAssertEqual(
            BridgeCredentialPresentation.discoveryHeadline(
                bridgeState: .notPaired,
                discoveryUnavailable: true
            ),
            "Mac bridge unavailable"
        )
    }

    @MainActor
    func testPairAgainPersistsAcrossModelRelaunchAndSuccessfulPairingRetriesImmediately() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-pair-again-relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let memoID = try MemoID("16161616-1616-1616-1616-161616161616")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: memoID, state: .saved, in: store)
        let pin = try CertificatePin(String(repeating: "a", count: 64))
        let oldCredential = try WatchBridgeCredential(
            bridgeName: "Old Mac",
            baseURL: URL(string: "https://old-mac.local:7443")!,
            certificatePin: pin,
            tokenHex: String(repeating: "22", count: 32)
        )
        let replacementCredential = try WatchBridgeCredential(
            bridgeName: "Studio Mac",
            baseURL: URL(string: "https://studio-mac.local:7443")!,
            certificatePin: pin,
            tokenHex: String(repeating: "33", count: 32)
        )
        let credentials = TestWatchBridgeCredentialStore(oldCredential)
        let pairing = TestPairingClient(
            credential: replacementCredential,
            credentialStore: credentials
        )
        let transport = AuthenticationThenSuccessTransport()
        let firstCoordinator = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900),
            randomSample: { 1 }
        )
        let firstModel = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: credentials,
            pairingClient: pairing,
            transferCoordinator: firstCoordinator,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )

        await firstModel.restore()
        XCTAssertEqual(firstModel.bridgeState.title, "Pair again")
        let firstUploadCallCount = await transport.uploadCallCount
        XCTAssertEqual(firstUploadCallCount, 1)

        let relaunchedCoordinator = try WatchTransferCoordinator(
            store: try WatchMemoStore(root: root),
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900),
            randomSample: { 1 }
        )
        let relaunchedModel = try VoiceCaptureModel(
            storeForTesting: try WatchMemoStore(root: root),
            credentialStore: credentials,
            pairingClient: pairing,
            transferCoordinator: relaunchedCoordinator,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )

        await relaunchedModel.restore()
        XCTAssertEqual(relaunchedModel.bridgeState.title, "Pair again")
        let relaunchedUploadCallCount = await transport.uploadCallCount
        XCTAssertEqual(relaunchedUploadCallCount, 1)

        let paired = await relaunchedModel.pair(
            bridge: DiscoveredBridge(
                name: replacementCredential.bridgeName,
                baseURL: replacementCredential.baseURL,
                certificatePin: pin
            ),
            confirmedPin: pin.confirmedByUser(),
            code: "123456"
        )

        XCTAssertTrue(paired)
        let finalUploadCallCount = await transport.uploadCallCount
        let finalMemo = try await store.load(memoID: memoID)
        let pairingIsRequired = try await store.pairingIsRequired()
        XCTAssertEqual(finalUploadCallCount, 2)
        XCTAssertEqual(finalMemo.metadata.state, .received)
        XCTAssertFalse(pairingIsRequired)
    }

    @MainActor
    func testStatusAuthenticationPresentsPairAgainAndPreservesAcceptedMemo() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-status-auth-pair-again")
        defer { try? FileManager.default.removeItem(at: root) }
        let memoID = try MemoID("17171717-1717-1717-1717-171717171717")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: memoID, state: .saved, in: store)
        _ = try await store.transition(memoID: memoID, to: .uploading)
        _ = try await store.transition(memoID: memoID, to: .received)
        let credential = try WatchBridgeCredential(
            bridgeName: "Old Mac",
            baseURL: URL(string: "https://old-mac.local:7443")!,
            certificatePin: CertificatePin(String(repeating: "a", count: 64)),
            tokenHex: String(repeating: "22", count: 32)
        )
        let credentials = TestWatchBridgeCredentialStore(credential)
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: StatusAuthenticationTransport(),
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: credentials,
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )

        await model.restore()

        XCTAssertEqual(model.bridgeState.title, "Pair again")
        let savedCredential = await credentials.load()
        let pairingIsRequired = try await store.pairingIsRequired()
        let storedState = try await store.load(memoID: memoID).metadata.state
        XCTAssertNil(savedCredential)
        XCTAssertTrue(pairingIsRequired)
        XCTAssertEqual(storedState, .received)
    }

    @MainActor
    func testRepairDrainsReceivedStatusBeforeSchedulingFutureSavedRetry() async throws {
        let root = try makeTemporaryDirectory(prefix: "watch-repair-mixed-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let savedID = try MemoID("18181818-1818-1818-1818-181818181818")
        let receivedID = try MemoID("19191919-1919-1919-1919-191919191919")
        let store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: savedID, state: .saved, in: store)
        let savedRetry = Date().addingTimeInterval(3_600)
        try await store.setRetryNotBefore(memoID: savedID, date: savedRetry)
        try await commitMemo(memoID: receivedID, state: .saved, in: store)
        _ = try await store.transition(memoID: receivedID, to: .uploading)
        _ = try await store.transition(memoID: receivedID, to: .received)
        try await store.markPairingRequired()

        let pin = try CertificatePin(String(repeating: "a", count: 64))
        let oldCredential = try WatchBridgeCredential(
            bridgeName: "Old Mac",
            baseURL: URL(string: "https://old-mac.local:7443")!,
            certificatePin: pin,
            tokenHex: String(repeating: "22", count: 32)
        )
        let replacementCredential = try WatchBridgeCredential(
            bridgeName: "Studio Mac",
            baseURL: URL(string: "https://studio-mac.local:7443")!,
            certificatePin: pin,
            tokenHex: String(repeating: "33", count: 32)
        )
        let credentials = TestWatchBridgeCredentialStore(oldCredential)
        let pairing = TestPairingClient(
            credential: replacementCredential,
            credentialStore: credentials
        )
        let transport = MixedQueueStatusTransport()
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        let model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: credentials,
            pairingClient: pairing,
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )

        await model.restore()
        XCTAssertEqual(model.bridgeState.title, "Pair again")

        let paired = await model.pair(
            bridge: DiscoveredBridge(
                name: replacementCredential.bridgeName,
                baseURL: replacementCredential.baseURL,
                certificatePin: pin
            ),
            confirmedPin: pin.confirmedByUser(),
            code: "123456"
        )

        let statusMemoIDs = await transport.statusMemoIDs
        let uploadCallCount = await transport.uploadCallCount
        let preservedRetry = try await store.retryNotBefore(memoID: savedID)
        let savedState = try await store.load(memoID: savedID).metadata.state
        let receivedState = try await store.load(memoID: receivedID).metadata.state
        XCTAssertTrue(paired)
        XCTAssertEqual(statusMemoIDs, [receivedID])
        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(preservedRetry, savedRetry)
        XCTAssertEqual(savedState, .saved)
        XCTAssertEqual(receivedState, .received)
    }

    @MainActor
    func testMalformedStatusUsesInjectedFullJitterSamplesInModelRetryPath() async throws {
        let cases: [(String, Double, Int, UInt64)] = [
            ("20202020-2020-2020-2020-202020202020", 0, 1, 0),
            ("21212121-2121-2121-2121-212121212121", 0.5, 1, 2_500_000_000),
            ("22222222-2222-2222-2222-222222222222", 1, 1, 5_000_000_000),
            ("23232323-2323-2323-2323-232323232323", 1, 9, 900_000_000_000),
        ]
        for (rawMemoID, sample, restoreCount, expectedNanoseconds) in cases {
            let root = try makeTemporaryDirectory(prefix: "watch-status-jitter-model")
            defer { try? FileManager.default.removeItem(at: root) }
            let memoID = try MemoID(rawMemoID)
            let store = try WatchMemoStore(root: root)
            try await commitMemo(memoID: memoID, state: .saved, in: store)
            _ = try await store.transition(memoID: memoID, to: .uploading)
            _ = try await store.transition(memoID: memoID, to: .received)
            let credential = try WatchBridgeCredential(
                bridgeName: "Studio Mac",
                baseURL: URL(string: "https://studio-mac.local:7443")!,
                certificatePin: CertificatePin(String(repeating: "a", count: 64)),
                tokenHex: String(repeating: "33", count: 32)
            )
            let probe = RetrySleepProbe()
            let transfer = try WatchTransferCoordinator(
                store: store,
                transport: MalformedStatusResponseTransport(),
                retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
            )
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let model = try VoiceCaptureModel(
                storeForTesting: store,
                credentialStore: TestWatchBridgeCredentialStore(credential),
                transferCoordinator: transfer,
                retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
                clock: { now },
                statusPollRandomSample: { sample },
                retrySleep: { nanoseconds in
                    try await probe.sleep(nanoseconds: nanoseconds)
                }
            )

            var scheduledNanoseconds: UInt64 = 0
            for _ in 0 ..< restoreCount {
                await model.restore()
                scheduledNanoseconds = await probe.nextNanoseconds()
            }
            let storedState = try await store.load(memoID: memoID).metadata.state
            XCTAssertEqual(scheduledNanoseconds, expectedNanoseconds)
            XCTAssertEqual(model.bridgeState.title, "Waiting for Mac")
            XCTAssertEqual(storedState, .received)
        }
    }
}

private actor TestWatchBridgeCredentialStore: WatchBridgeCredentialStore {
    private var credential: WatchBridgeCredential?

    init(_ credential: WatchBridgeCredential) {
        self.credential = credential
    }

    func load() -> WatchBridgeCredential? { credential }
    func save(_ credential: WatchBridgeCredential) { self.credential = credential }
    func remove() { credential = nil }
}

private actor TestPairingClient: BridgePairingPerforming {
    private let credential: WatchBridgeCredential
    private let credentialStore: TestWatchBridgeCredentialStore

    init(
        credential: WatchBridgeCredential,
        credentialStore: TestWatchBridgeCredentialStore
    ) {
        self.credential = credential
        self.credentialStore = credentialStore
    }

    func pair(
        bridge _: DiscoveredBridge,
        confirmedPin _: ConfirmedCertificatePin,
        code _: String
    ) async throws -> WatchBridgeCredential {
        await credentialStore.save(credential)
        return credential
    }
}

private actor AuthenticationThenSuccessTransport: WatchBridgeTransport {
    private(set) var uploadCallCount = 0

    func upload(
        memo: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        uploadCallCount += 1
        if uploadCallCount == 1 {
            throw WatchBridgeTransportFailure.authentication
        }
        return try BridgeReceipt(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            acknowledgedRevision: expectedRevision,
            capturedAt: memo.capturedAt,
            localeHint: memo.localeHint,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }
}

private actor BlockingUploadTransport: WatchBridgeTransport {
    private struct BlockedUpload {
        let memo: VoiceMemoMetadata
        let expectedRevision: UInt64
        let continuation: CheckedContinuation<BridgeReceipt, any Error>
    }

    private var startedMemoIDs: [MemoID] = []
    private var startedWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var blockedUploads: [MemoID: BlockedUpload] = [:]
    private(set) var cancelledMemoIDs: [MemoID] = []

    func upload(
        memo: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt {
        if startedWaiters.isEmpty {
            startedMemoIDs.append(memo.memoID)
        } else {
            startedWaiters.removeFirst().resume(returning: memo.memoID)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    blockedUploads[memo.memoID] = .init(
                        memo: memo,
                        expectedRevision: expectedRevision,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelUpload(memoID: memo.memoID) }
        }
    }

    func nextStartedMemoID() async -> MemoID {
        if !startedMemoIDs.isEmpty {
            return startedMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func completeUpload(memoID: MemoID) {
        guard let blocked = blockedUploads.removeValue(forKey: memoID) else {
            return
        }
        do {
            blocked.continuation.resume(
                returning: try BridgeReceipt(
                    memoID: blocked.memo.memoID,
                    audioSHA256: blocked.memo.audioSHA256,
                    acknowledgedRevision: blocked.expectedRevision,
                    capturedAt: blocked.memo.capturedAt,
                    localeHint: blocked.memo.localeHint,
                    receivedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            )
        } catch {
            blocked.continuation.resume(throwing: error)
        }
    }

    private func cancelUpload(memoID: MemoID) {
        guard let blocked = blockedUploads.removeValue(forKey: memoID) else {
            return
        }
        cancelledMemoIDs.append(memoID)
        blocked.continuation.resume(throwing: CancellationError())
    }
}

private actor BlockingStatusTransport: WatchBridgeTransport {
    private struct BlockedStatus {
        let memo: VoiceMemoMetadata
        let continuation: CheckedContinuation<BridgeMemoStatus, any Error>
    }

    private var startedMemoIDs: [MemoID] = []
    private var startedWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var blockedStatuses: [MemoID: BlockedStatus] = [:]
    private(set) var cancelledMemoIDs: [MemoID] = []

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        if startedWaiters.isEmpty {
            startedMemoIDs.append(memo.memoID)
        } else {
            startedWaiters.removeFirst().resume(returning: memo.memoID)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    blockedStatuses[memo.memoID] = .init(
                        memo: memo,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelStatus(memoID: memo.memoID) }
        }
    }

    func nextStartedMemoID() async -> MemoID {
        if !startedMemoIDs.isEmpty {
            return startedMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func completeStatus(memoID: MemoID) {
        guard let blocked = blockedStatuses.removeValue(forKey: memoID) else {
            return
        }
        do {
            blocked.continuation.resume(
                returning: try BridgeMemoStatus(
                    memoID: blocked.memo.memoID,
                    audioSHA256: blocked.memo.audioSHA256,
                    state: blocked.memo.state,
                    stateRevision: blocked.memo.stateRevision,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
                )
            )
        } catch {
            blocked.continuation.resume(throwing: error)
        }
    }

    private func cancelStatus(memoID: MemoID) {
        guard let blocked = blockedStatuses.removeValue(forKey: memoID) else {
            return
        }
        cancelledMemoIDs.append(memoID)
        blocked.continuation.resume(throwing: CancellationError())
    }
}

private actor MultiMemoStatusDeletionTransport: WatchBridgeTransport {
    private let firstMemoID: MemoID
    private var secondAttemptCount = 0
    private var blockingMemoIDs: [MemoID] = []
    private var blockingWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var blockedMemo: VoiceMemoMetadata?
    private var continuation: CheckedContinuation<BridgeMemoStatus, any Error>?
    private(set) var cancelledMemoIDs: [MemoID] = []

    init(firstMemoID: MemoID) {
        self.firstMemoID = firstMemoID
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        if memo.memoID == firstMemoID {
            return try identicalStatus(for: memo)
        }
        secondAttemptCount += 1
        guard secondAttemptCount == 1 else {
            return try identicalStatus(for: memo)
        }
        blockedMemo = memo
        signalBlocking(memo.memoID)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancelBlockingStatus() }
        }
    }

    func nextBlockingMemoID() async -> MemoID {
        if !blockingMemoIDs.isEmpty {
            return blockingMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            blockingWaiters.append(continuation)
        }
    }

    func releaseBlockingStatus() {
        guard let blockedMemo,
              let continuation
        else { return }
        self.blockedMemo = nil
        self.continuation = nil
        do {
            continuation.resume(returning: try identicalStatus(for: blockedMemo))
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func signalBlocking(_ memoID: MemoID) {
        if blockingWaiters.isEmpty {
            blockingMemoIDs.append(memoID)
        } else {
            blockingWaiters.removeFirst().resume(returning: memoID)
        }
    }

    private func cancelBlockingStatus() {
        guard let blockedMemo,
              let continuation
        else { return }
        self.blockedMemo = nil
        self.continuation = nil
        cancelledMemoIDs.append(blockedMemo.memoID)
        continuation.resume(throwing: CancellationError())
    }

    private func identicalStatus(for memo: VoiceMemoMetadata) throws -> BridgeMemoStatus {
        try BridgeMemoStatus(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            state: memo.state,
            stateRevision: memo.stateRevision,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}

private actor MultiMemoFinalAckDeletionTransport: WatchBridgeTransport {
    private let firstMemoID: MemoID
    private var secondAttemptCount = 0
    private var blockingMemoIDs: [MemoID] = []
    private var blockingWaiters: [CheckedContinuation<MemoID, Never>] = []
    private var blockedMemoID: MemoID?
    private var continuation: CheckedContinuation<Void, any Error>?
    private(set) var cancelledMemoIDs: [MemoID] = []

    init(firstMemoID: MemoID) {
        self.firstMemoID = firstMemoID
    }

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws {
        guard acknowledgement.memoID != firstMemoID else { return }
        secondAttemptCount += 1
        guard secondAttemptCount == 1 else { return }
        blockedMemoID = acknowledgement.memoID
        signalBlocking(acknowledgement.memoID)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancelBlockingAcknowledgement() }
        }
    }

    func nextBlockingMemoID() async -> MemoID {
        if !blockingMemoIDs.isEmpty {
            return blockingMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            blockingWaiters.append(continuation)
        }
    }

    func releaseBlockingAcknowledgement() {
        blockedMemoID = nil
        continuation?.resume(returning: ())
        continuation = nil
    }

    private func signalBlocking(_ memoID: MemoID) {
        if blockingWaiters.isEmpty {
            blockingMemoIDs.append(memoID)
        } else {
            blockingWaiters.removeFirst().resume(returning: memoID)
        }
    }

    private func cancelBlockingAcknowledgement() {
        guard let blockedMemoID,
              let continuation
        else { return }
        self.blockedMemoID = nil
        self.continuation = nil
        cancelledMemoIDs.append(blockedMemoID)
        continuation.resume(throwing: CancellationError())
    }
}

private actor StatusAuthenticationTransport: WatchBridgeTransport {
    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        throw WatchBridgeTransportFailure.authentication
    }
}

private actor MixedQueueStatusTransport: WatchBridgeTransport {
    private(set) var uploadCallCount = 0
    private(set) var statusMemoIDs: [MemoID] = []

    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        uploadCallCount += 1
        throw WatchBridgeTransportFailure.transient
    }

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        statusMemoIDs.append(memo.memoID)
        return try BridgeMemoStatus(
            memoID: memo.memoID,
            audioSHA256: memo.audioSHA256,
            state: memo.state,
            stateRevision: memo.stateRevision,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}

private actor MalformedStatusResponseTransport: WatchBridgeTransport {
    func upload(
        memo _: VoiceMemoMetadata,
        audioURL _: URL,
        expectedRevision _: UInt64
    ) async throws -> BridgeReceipt {
        throw WatchBridgeTransportFailure.permanent
    }

    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        try BridgeStatusResponseDecoder.status(statusCode: 200, body: Data())
    }
}

private actor RetrySleepProbe {
    private var recorded: [UInt64] = []
    private var waiters: [CheckedContinuation<UInt64, Never>] = []

    func sleep(nanoseconds: UInt64) throws {
        if waiters.isEmpty {
            recorded.append(nanoseconds)
        } else {
            waiters.removeFirst().resume(returning: nanoseconds)
        }
        throw CancellationError()
    }

    func nextNanoseconds() async -> UInt64 {
        if !recorded.isEmpty {
            return recorded.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor RecordingWatchFileUploader: WatchFileUploadPerforming {
    struct Invocation: Sendable {
        let request: URLRequest
        let fileURL: URL
        let maximumResponseBytes: Int
    }

    private(set) var invocation: Invocation?
    private let result: (Data, URLResponse)

    init(result: (Data, URLResponse)) {
        self.result = result
    }

    func upload(
        request: URLRequest,
        lease: ValidatedFileUploadLease,
        expectedPin: CertificatePin,
        maximumResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        invocation = Invocation(
            request: request,
            fileURL: lease.fileURL,
            maximumResponseBytes: maximumResponseBytes
        )
        return result
    }
}

private final class RecordingURLSessionUploadTaskFactory: URLSessionUploadTaskCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCreationCount = 0

    var creationCount: Int { lock.withLock { storedCreationCount } }

    func makeUploadTask(
        session: URLSession,
        request: URLRequest,
        fileURL: URL
    ) throws -> URLSessionUploadTask {
        lock.withLock { storedCreationCount += 1 }
        throw WatchBridgeTransportFailure.transient
    }
}

private final class RecordingUploadTask: BridgeUploadTask, @unchecked Sendable {
    let taskIdentifier: Int
    var onResume: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var storedResumeCount = 0
    private var storedCancelCount = 0

    var resumeCount: Int { lock.withLock { storedResumeCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }

    init(taskIdentifier: Int) {
        self.taskIdentifier = taskIdentifier
    }

    func resume() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            storedResumeCount += 1
            return onResume
        }
        if let action {
            DispatchQueue.global().async(execute: action)
        }
    }

    func cancel() {
        lock.withLock { storedCancelCount += 1 }
    }
}

@MainActor
private final class RetentionModelFixture {
    let root: URL
    let model: VoiceCaptureModel

    init(preferences: InMemoryRetentionPreferences) throws {
        root = try makeTemporaryDirectory(prefix: "watch-retention-preference")
        model = try VoiceCaptureModel(
            storeForTesting: WatchMemoStore(root: root),
            retentionPreferenceStore: preferences,
            clock: Date.init
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PlaybackModelFixture {
    let root: URL
    let store: WatchMemoStore
    let player: PlaybackSpy
    let model: VoiceCaptureModel

    init(
        prefix: String,
        loader: SuspendedPlaybackLoader? = nil,
        supportsRecording: Bool = false
    ) throws {
        root = try makeTemporaryDirectory(prefix: prefix)
        store = try WatchMemoStore(root: root)
        player = PlaybackSpy()
        let coordinator = supportsRecording
            ? WatchCaptureCoordinator(store: store, recorder: PlaybackTestRecorder())
            : nil
        let playbackMemoLoader: (@Sendable (MemoID) async throws -> StoredWatchMemo)?
        if let loader {
            playbackMemoLoader = { memoID in
                try await loader.load(memoID: memoID)
            }
        } else {
            playbackMemoLoader = nil
        }
        model = try VoiceCaptureModel(
            storeForTesting: store,
            captureCoordinator: coordinator,
            audioPlayer: player,
            playbackMemoLoader: playbackMemoLoader,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        model.handleQueueAppeared()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class MultiMemoStatusDeletionFixture {
    let root: URL
    let firstID: MemoID
    let secondID: MemoID
    let store: WatchMemoStore
    let transport: MultiMemoStatusDeletionTransport
    let model: VoiceCaptureModel

    init(prefix: String) async throws {
        root = try makeTemporaryDirectory(prefix: prefix)
        firstID = try MemoID("85858585-8585-8585-8585-858585858581")
        secondID = try MemoID("85858585-8585-8585-8585-858585858582")
        store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: firstID, state: .received, in: store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: secondID, state: .received, in: store, capturedAt: Date(timeIntervalSince1970: 101))
        transport = MultiMemoStatusDeletionTransport(firstMemoID: firstID)
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: TestWatchBridgeCredentialStore(try makeWatchCredential()),
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class MultiMemoFinalAckDeletionFixture {
    let root: URL
    let firstID: MemoID
    let secondID: MemoID
    let store: WatchMemoStore
    let transport: MultiMemoFinalAckDeletionTransport
    let model: VoiceCaptureModel

    init(prefix: String) async throws {
        root = try makeTemporaryDirectory(prefix: prefix)
        firstID = try MemoID("86868686-8686-8686-8686-868686868681")
        secondID = try MemoID("86868686-8686-8686-8686-868686868682")
        store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: firstID, state: .delivered, in: store, capturedAt: Date(timeIntervalSince1970: 100))
        try await commitMemo(memoID: secondID, state: .delivered, in: store, capturedAt: Date(timeIntervalSince1970: 101))
        transport = MultiMemoFinalAckDeletionTransport(firstMemoID: firstID)
        let transfer = try WatchTransferCoordinator(
            store: store,
            transport: transport,
            retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
        )
        model = try VoiceCaptureModel(
            storeForTesting: store,
            credentialStore: TestWatchBridgeCredentialStore(try makeWatchCredential()),
            transferCoordinator: transfer,
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AsyncPlaybackFailureFixture {
    let root: URL
    let memoID: MemoID
    let store: WatchMemoStore
    let playerProbe: AudioPlayerFactoryProbe
    let player: WatchAudioPlayer
    let hapticProbe: PlaybackHapticProbe
    let model: VoiceCaptureModel

    init(prefix: String) async throws {
        root = try makeTemporaryDirectory(prefix: prefix)
        memoID = try MemoID("87878787-8787-8787-8787-878787878781")
        store = try WatchMemoStore(root: root)
        try await commitMemo(memoID: memoID, state: .saved, in: store)
        let resolvedPlayerProbe = AudioPlayerFactoryProbe()
        playerProbe = resolvedPlayerProbe
        let audio = makeSilentWaveData()
        player = WatchAudioPlayer(playerFactory: { _ in
            let systemPlayer = try AVAudioPlayer(data: audio)
            resolvedPlayerProbe.player = systemPlayer
            return systemPlayer
        })
        let resolvedHapticProbe = PlaybackHapticProbe()
        hapticProbe = resolvedHapticProbe
        model = try VoiceCaptureModel(
            storeForTesting: store,
            audioPlayer: player,
            playbackFailureHaptic: { resolvedHapticProbe.failureCount += 1 },
            retentionPreferenceStore: InMemoryRetentionPreferences(days: 7),
            clock: Date.init
        )
        model.handleQueueAppeared()
        await model.restore()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AudioPlayerFactoryProbe {
    var creationCount = 0
    var player: AVAudioPlayer?
}

@MainActor
private final class PlaybackHapticProbe {
    var failureCount = 0
}

private actor SuspendedPlaybackLoader {
    private var stored: [MemoID: StoredWatchMemo] = [:]
    private var continuations: [MemoID: CheckedContinuation<StoredWatchMemo, any Error>] = [:]
    private var startedMemoIDs: [MemoID] = []
    private var startedWaiters: [CheckedContinuation<MemoID, Never>] = []

    func store(_ memo: StoredWatchMemo) {
        stored[memo.metadata.memoID] = memo
    }

    func load(memoID: MemoID) async throws -> StoredWatchMemo {
        if startedWaiters.isEmpty {
            startedMemoIDs.append(memoID)
        } else {
            startedWaiters.removeFirst().resume(returning: memoID)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[memoID] = continuation
        }
    }

    func nextStartedMemoID() async -> MemoID {
        if !startedMemoIDs.isEmpty {
            return startedMemoIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func resume(memoID: MemoID) {
        guard let memo = stored[memoID],
              let continuation = continuations.removeValue(forKey: memoID)
        else { return }
        continuation.resume(returning: memo)
    }
}

@MainActor
private final class PlaybackSpy: WatchAudioPlaying {
    struct PlayRequest: Equatable {
        let memoID: MemoID
        let url: URL
    }

    enum Event: Equatable {
        case play(MemoID)
        case stop
    }

    private(set) var state: WatchPlaybackState = .stopped
    private(set) var playRequests: [PlayRequest] = []
    private(set) var events: [Event] = []
    var playError: (any Error)?

    func play(memoID: MemoID, url: URL) throws {
        playRequests.append(.init(memoID: memoID, url: url))
        events.append(.play(memoID))
        if let playError {
            state = .failed(memoID)
            throw playError
        }
        state = .playing(memoID)
    }

    func stop() {
        events.append(.stop)
        state = .stopped
    }
}

private actor PlaybackTestRecorder: WatchAudioRecording {
    func recordingPermission() -> WatchRecordingPermission {
        .granted
    }

    func requestRecordingPermission() -> Bool {
        true
    }

    func startRecording(to url: URL, maximumDuration _: TimeInterval) throws {
        try Data("recorded voice".utf8).write(to: url)
    }

    func stopRecording() -> WatchRecordingResult {
        WatchRecordingResult(durationMilliseconds: 1_000)
    }

    func cancelRecording() {}

    func waitForAutomaticCompletion() -> WatchRecordingCompletion {
        .cancelled
    }

    func inspectRecording(at _: URL) -> WatchRecordingResult {
        WatchRecordingResult(durationMilliseconds: 1_000)
    }
}

private enum PlaybackTestError: Error {
    case expected
}

private func makeWatchCredential() throws -> WatchBridgeCredential {
    try WatchBridgeCredential(
        bridgeName: "Studio Mac",
        baseURL: URL(string: "https://studio-mac.local:7443")!,
        certificatePin: CertificatePin(String(repeating: "a", count: 64)),
        tokenHex: String(repeating: "22", count: 32)
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func setPrivatePermissions(_ url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )
}

private func makeSilentWaveData(sampleCount: Int = 4_000) -> Data {
    var data = Data()
    func appendASCII(_ value: String) {
        data.append(contentsOf: value.utf8)
    }
    func appendUInt16(_ value: UInt16) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }
    func appendUInt32(_ value: UInt32) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
    let dataByteCount = UInt32(sampleCount * 2)
    appendASCII("RIFF")
    appendUInt32(36 + dataByteCount)
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendUInt32(16)
    appendUInt16(1)
    appendUInt16(1)
    appendUInt32(8_000)
    appendUInt32(16_000)
    appendUInt16(2)
    appendUInt16(16)
    appendASCII("data")
    appendUInt32(dataByteCount)
    data.append(Data(repeating: 0, count: Int(dataByteCount)))
    return data
}

private func commitMemo(
    memoID: MemoID,
    state: MemoState,
    in store: WatchMemoStore,
    capturedAt: Date = Date(timeIntervalSince1970: 100)
) async throws {
    let temporary = await store.temporaryRecordingURL(for: memoID)
    try Data("retention-audio".utf8).write(to: temporary)
    _ = try await store.commitRecording(
        temporaryURL: temporary,
        memoID: memoID,
        capturedAt: capturedAt,
        durationMilliseconds: 100,
        localeHint: nil
    )
    guard state != .saved else { return }
    if state == .needsAttention {
        _ = try await store.transition(memoID: memoID, to: .needsAttention)
        return
    }
    for transition in [
        MemoState.uploading, .received, .transcribing,
        .readyForCodex, .inserting, .reconciling, .delivered,
    ] {
        _ = try await store.transition(memoID: memoID, to: transition)
        if transition == state { return }
    }
}

private func assertMemoIsMissing(_ memoID: MemoID, from store: WatchMemoStore) async {
    do {
        _ = try await store.load(memoID: memoID)
        XCTFail("expected memo to be purged")
    } catch WatchMemoStoreError.notFound {
    } catch {
        XCTFail("unexpected error: \(error)")
    }
}

@MainActor
private final class InMemoryRetentionPreferences: WatchRetentionPreferenceStoring {
    var deliveredRetentionDays: Int

    init(days: Int) {
        deliveredRetentionDays = days
    }
}

private actor FailingRetentionMaintainer: WatchDeliveredRetentionMaintaining {
    private(set) var performCount = 0

    func performMaintenance() throws -> [MemoID] {
        performCount += 1
        throw RetentionMaintenanceFailure.expected
    }
}

private enum RetentionMaintenanceFailure: Error {
    case expected
}

@MainActor
private final class BackgroundRefreshTaskStub: WatchBackgroundRefreshTask {
    let isApplicationRefresh: Bool
    var expirationHandler: (() -> Void)?
    private(set) var completionCount = 0

    init(isApplicationRefresh: Bool) {
        self.isApplicationRefresh = isApplicationRefresh
    }

    func complete() {
        completionCount += 1
    }
}

private final class MutableModelTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
