import CodexBridgeShared
import CodexWatchCore
import Combine
import Foundation
import SwiftUI
import WatchKit

struct WatchQueueItem: Identifiable, Equatable {
    let id: MemoID
    let capturedAt: Date
    let state: MemoState

    var statusText: String {
        state.watchStatusText
    }

    var canDelete: Bool {
        true
    }

    var deletionWarning: String {
        if state == .delivered {
            return "This removes the retained audio from this Watch. The Inbox entry is not deleted."
        }
        return "This unresolved recording may be the only copy. Deleting it cannot be undone."
    }
}

enum WatchBridgeConnectionState: Equatable {
    case notPaired
    case pairing
    case paired(String)
    case waiting(String)
    case sending(String)
    case received(String)
    case needsAttention(String?)

    var isPaired: Bool {
        switch self {
        case .paired, .waiting, .sending, .received:
            return true
        case .notPaired, .pairing, .needsAttention:
            return false
        }
    }

    var title: String {
        switch self {
        case .notPaired:
            return "Pair with Mac"
        case .pairing:
            return "Pairing with Mac"
        case let .paired(name):
            return "Paired with \(name)"
        case .waiting:
            return "Waiting for Mac"
        case .sending:
            return "Sending to Mac"
        case .received:
            return "Received by Mac"
        case let .needsAttention(message):
            return message == "Pair again" ? "Pair again" : "Bridge attention"
        }
    }

    var detail: String {
        switch self {
        case .notPaired:
            return "Recordings stay on this Watch until a bridge is paired."
        case .pairing:
            return "Confirming the local bridge identity."
        case let .paired(name):
            return "\(name) can receive saved recordings."
        case let .waiting(name):
            return "Saved safely. Waiting for \(name)."
        case let .sending(name):
            return "Uploading securely to \(name)."
        case let .received(name):
            return "\(name) acknowledged the audio. Codex delivery is still pending."
        case let .needsAttention(message):
            return message == "Pair again"
                ? "Pair again to resume preserved recordings."
                : message ?? "Open pairing and check the Mac bridge."
        }
    }
}

protocol BridgePairingPerforming: Sendable {
    func pair(
        bridge: DiscoveredBridge,
        confirmedPin: ConfirmedCertificatePin,
        code: String
    ) async throws -> WatchBridgeCredential
}

extension BridgePairingClient: BridgePairingPerforming {}

@MainActor
final class VoiceCaptureModel: ObservableObject {
    @Published private(set) var captureState: WatchCaptureState = .idle
    @Published private(set) var queueItems: [WatchQueueItem] = []
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var bridgeState: WatchBridgeConnectionState = .notPaired
    @Published private(set) var hasSavedBridgeCredential = false
    @Published private(set) var deliveredRetentionChoice: WatchDeliveredRetentionChoice
    @Published private(set) var playbackState: WatchPlaybackState = .stopped

    let maximumDuration = TimeInterval(
        VoiceMemoMetadata.maximumDurationMilliseconds
    ) / 1_000
    let discovery = BridgeDiscovery()

    private let store: WatchMemoStore?
    private let coordinator: WatchCaptureCoordinator?
    private let audioPlayer: any WatchAudioPlaying
    private let playbackMemoLoader: @Sendable (MemoID) async throws -> StoredWatchMemo
    private let playbackFailureHaptic: @MainActor () -> Void
    private let credentialStore: any WatchBridgeCredentialStore
    private let pairingClient: any BridgePairingPerforming
    private let transferCoordinator: WatchTransferCoordinator?
    private let transferActivityRegistry: WatchTransferActivityRegistry?
    private let retentionPreferenceStore: WatchRetentionPreferenceStoring
    private let retentionClock: @Sendable () -> Date
    private let statusPollRandomSample: @Sendable () -> Double
    private let retrySleep: @Sendable (UInt64) async throws -> Void
    private let retentionMaintainerFactoryOverride: (@MainActor (WatchDeliveredRetentionChoice) -> any WatchDeliveredRetentionMaintaining)?
    private var deliveredRetentionMaintainer: (any WatchDeliveredRetentionMaintaining)?
    private var recorderCompletionTask: Task<Void, Never>?
    private var playbackRequestGeneration: UInt64 = 0
    private var requestedPlaybackMemoID: MemoID?
    private var queueIsPresented = false
    private var activeUploadTask: Task<Void, Never>?
    private var activeUploadID: UUID?
    private var retryUploadTask: Task<Void, Never>?
    private var bridgeSessionGeneration: UInt64 = 0
    private var statusPollAttempt: UInt64 = 0
    private var discoveryObservation: AnyCancellable?

    init() {
        let credentialStore = BridgeKeychainStore()
        let audioPlayer = WatchAudioPlayer()
        let retentionPreferenceStore = WatchUserDefaultsRetentionPreferenceStore()
        let initialRetentionChoice = Self.normalizedRetentionChoice(
            from: retentionPreferenceStore
        )
        self.credentialStore = credentialStore
        self.audioPlayer = audioPlayer
        playbackFailureHaptic = { WKInterfaceDevice.current().play(.failure) }
        pairingClient = BridgePairingClient(credentialStore: credentialStore)
        self.retentionPreferenceStore = retentionPreferenceStore
        retentionClock = Date.init
        statusPollRandomSample = { Double.random(in: 0 ... 1) }
        retrySleep = { try await Task.sleep(nanoseconds: $0) }
        retentionMaintainerFactoryOverride = nil
        deliveredRetentionChoice = initialRetentionChoice
        var resolvedStore: WatchMemoStore?
        var resolvedCoordinator: WatchCaptureCoordinator?
        var resolvedTransferCoordinator: WatchTransferCoordinator?
        var resolvedRetentionMaintainer: WatchDeliveredRetentionMaintainer?
        var storageUnavailable = true
        do {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw WatchMemoStoreError.invalidRoot
            }
            let root = applicationSupport
                .appendingPathComponent("VoiceMemoQueue", isDirectory: true)
            let watchStore = try WatchMemoStore(root: root)
            let watchCoordinator = WatchCaptureCoordinator(
                store: watchStore,
                recorder: WatchAudioRecorder(),
                maximumDuration: maximumDuration,
                localeHint: Locale.current.identifier
            )
            let watchTransferCoordinator = try WatchTransferCoordinator(
                store: watchStore,
                transport: HTTPSBridgeTransport(credentialStore: credentialStore),
                retryPolicy: WatchRetryPolicy(baseDelay: 5, maximumDelay: 900)
            )
            resolvedStore = watchStore
            resolvedCoordinator = watchCoordinator
            resolvedTransferCoordinator = watchTransferCoordinator
            resolvedRetentionMaintainer = try Self.makeRetentionMaintainer(
                store: watchStore,
                choice: initialRetentionChoice,
                clock: retentionClock
            )
            storageUnavailable = false
        } catch {
        }
        store = resolvedStore
        coordinator = resolvedCoordinator
        transferCoordinator = resolvedTransferCoordinator
        transferActivityRegistry = resolvedTransferCoordinator?.activityRegistry
        let playbackStore = resolvedStore
        playbackMemoLoader = { memoID in
            guard let playbackStore else { throw WatchMemoStoreError.invalidRoot }
            return try await playbackStore.load(memoID: memoID)
        }
        deliveredRetentionMaintainer = resolvedRetentionMaintainer
        if storageUnavailable {
            captureState = .failed(.recovery)
        }
        audioPlayer.onStateChange = { [weak self] state in
            self?.publishPlaybackState(state)
        }
        observeDiscoveryChanges()
    }

    init(
        storeForTesting store: WatchMemoStore,
        captureCoordinator coordinatorOverride: WatchCaptureCoordinator? = nil,
        audioPlayer audioPlayerOverride: (any WatchAudioPlaying)? = nil,
        playbackMemoLoader playbackMemoLoaderOverride: (@Sendable (MemoID) async throws -> StoredWatchMemo)? = nil,
        playbackFailureHaptic playbackFailureHapticOverride: (@MainActor () -> Void)? = nil,
        credentialStore credentialStoreOverride: (any WatchBridgeCredentialStore)? = nil,
        pairingClient pairingClientOverride: (any BridgePairingPerforming)? = nil,
        transferCoordinator: WatchTransferCoordinator? = nil,
        retentionPreferenceStore: WatchRetentionPreferenceStoring,
        clock: @escaping @Sendable () -> Date,
        statusPollRandomSample: @escaping @Sendable () -> Double = {
            Double.random(in: 0 ... 1)
        },
        retrySleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        retentionMaintainerFactory: (@MainActor (WatchDeliveredRetentionChoice) -> any WatchDeliveredRetentionMaintaining)? = nil
    ) throws {
        let credentialStore: any WatchBridgeCredentialStore
        let audioPlayer = audioPlayerOverride ?? WatchAudioPlayer()
        if let credentialStoreOverride {
            credentialStore = credentialStoreOverride
        } else {
            credentialStore = BridgeKeychainStore()
        }
        self.credentialStore = credentialStore
        self.audioPlayer = audioPlayer
        playbackFailureHaptic = playbackFailureHapticOverride ?? {
            WKInterfaceDevice.current().play(.failure)
        }
        if let pairingClientOverride {
            pairingClient = pairingClientOverride
        } else {
            pairingClient = BridgePairingClient(credentialStore: credentialStore)
        }
        self.store = store
        coordinator = coordinatorOverride
        self.transferCoordinator = transferCoordinator
        transferActivityRegistry = transferCoordinator?.activityRegistry
        playbackMemoLoader = playbackMemoLoaderOverride ?? { memoID in
            try await store.load(memoID: memoID)
        }
        self.retentionPreferenceStore = retentionPreferenceStore
        retentionClock = clock
        self.statusPollRandomSample = statusPollRandomSample
        self.retrySleep = retrySleep
        retentionMaintainerFactoryOverride = retentionMaintainerFactory
        deliveredRetentionChoice = Self.normalizedRetentionChoice(
            from: retentionPreferenceStore
        )
        if let retentionMaintainerFactory {
            deliveredRetentionMaintainer = retentionMaintainerFactory(
                deliveredRetentionChoice
            )
        } else {
            deliveredRetentionMaintainer = try Self.makeRetentionMaintainer(
                store: store,
                choice: deliveredRetentionChoice,
                clock: clock
            )
        }
        if let audioPlayer = audioPlayer as? WatchAudioPlayer {
            audioPlayer.onStateChange = { [weak self] state in
                self?.publishPlaybackState(state)
            }
        }
        observeDiscoveryChanges()
    }

    deinit {
        recorderCompletionTask?.cancel()
        activeUploadTask?.cancel()
        retryUploadTask?.cancel()
    }

    private func observeDiscoveryChanges() {
        discoveryObservation = discovery.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var isRecording: Bool {
        if case .recording = captureState { return true }
        return false
    }

    var primaryActionDisabled: Bool {
        switch captureState {
        case .preparing, .saving:
            return true
        default:
            return coordinator == nil
        }
    }

    var stateTitle: String {
        switch captureState {
        case .idle:
            return "Ready to capture"
        case .preparing:
            return "Preparing microphone"
        case .recording:
            return "Recording"
        case .saving:
            return "Saving securely"
        case .savedOnWatch:
            return "Saved on Watch"
        case .permissionDenied:
            return "Microphone access needed"
        case let .interruptedRecordingFound(count):
            return count == 1 ? "Interrupted recording found" : "\(count) recordings need attention"
        case let .failed(failure):
            switch failure {
            case .recorderStart:
                return "Couldn’t start recording"
            case .recorderStop:
                return "Recording needs recovery"
            case .queueCommit:
                return "Couldn’t save recording"
            case .identifier, .recovery:
                return "Storage unavailable"
            }
        }
    }

    var stateDetail: String {
        switch captureState {
        case .recording:
            return "Tap to stop"
        case .savedOnWatch:
            return "Waiting for your Mac bridge"
        case .permissionDenied:
            return "Allow microphone access in Watch Settings"
        case .interruptedRecordingFound, .failed(.recorderStop), .failed(.queueCommit):
            return "Audio is still preserved locally"
        case .preparing, .saving:
            return "Keep Voice Inbox open"
        default:
            return "Ideas stay on your devices"
        }
    }

    func recordingLimitDetail(from startedAt: Date, to now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
        let remaining = max(0, Int(maximumDuration) - elapsed)
        switch remaining {
        case 0:
            return "Finishing recording"
        case 1:
            return "1 second remaining"
        case 2 ..< 60:
            return "\(remaining) seconds remaining"
        case 60:
            return "1 minute remaining"
        default:
            return "Tap to stop"
        }
    }

    func restore() async {
        // Keychain recovery is independent of capture storage. Keep the
        // pairing escape hatch available even when the memo queue cannot open.
        await restoreBridgeState()
        await performDeliveredRetentionMaintenance()
        if let coordinator {
            await coordinator.recoverInterruptedCapture()
        }
        await refreshStateAndQueue()
        await attemptUpload()
    }

    func handleAppBecameActive() async {
        await performDeliveredRetentionMaintenance()
        await refreshQueue()
        await attemptUpload()
    }

    func handleAppBecameInactive() {
        stopPlayback()
    }

    func handleQueueDisappeared() {
        queueIsPresented = false
        stopPlayback()
    }

    func handleQueueAppeared() {
        queueIsPresented = true
    }

    func handleBackgroundRefresh() async {
        await restore()
    }

    func cancelBackgroundRefresh() {
        invalidateBridgeOperations()
    }

    func setDeliveredRetentionChoice(_ choice: WatchDeliveredRetentionChoice) async {
        guard choice != deliveredRetentionChoice else { return }
        deliveredRetentionChoice = choice
        retentionPreferenceStore.deliveredRetentionDays = choice.rawValue
        do {
            try rebuildDeliveredRetentionMaintainer()
        } catch {
            // The selected preference remains durable and queued audio stays
            // available for the next lifecycle maintenance retry.
            await refreshQueue()
            return
        }
        await performDeliveredRetentionMaintenance()
        await refreshQueue()
    }

    func toggleRecording() async {
        if !isRecording {
            stopPlayback()
        }
        guard let coordinator else { return }
        if isRecording {
            recorderCompletionTask?.cancel()
            await coordinator.finishCapture()
            recordingStartedAt = nil
        } else {
            await coordinator.beginCapture()
            if case .recording = await coordinator.currentState {
                recordingStartedAt = Date()
                WKInterfaceDevice.current().play(.start)
                waitForRecorderCompletion()
            }
        }
        await refreshStateAndQueue()
        if case .savedOnWatch = captureState {
            WKInterfaceDevice.current().play(.success)
            await attemptUpload()
        } else if case .failed = captureState {
            WKInterfaceDevice.current().play(.failure)
        }
    }

    func togglePlayback(_ item: WatchQueueItem) async {
        guard !isRecording,
              queueIsPresented,
              queueItems.contains(where: { $0.id == item.id })
        else { return }
        if playbackState == .playing(item.id) {
            stopPlayback()
            return
        }
        stopPlayback()
        let requestGeneration = playbackRequestGeneration
        requestedPlaybackMemoID = item.id
        do {
            let stored = try await playbackMemoLoader(item.id)
            guard requestGeneration == playbackRequestGeneration,
                  requestedPlaybackMemoID == item.id,
                  !isRecording,
                  queueIsPresented,
                  queueItems.contains(where: { $0.id == item.id })
            else { return }
            try audioPlayer.play(memoID: item.id, url: stored.audioURL)
            publishPlaybackState(audioPlayer.state)
        } catch {
            guard requestGeneration == playbackRequestGeneration,
                  requestedPlaybackMemoID == item.id,
                  !isRecording,
                  queueIsPresented,
                  queueItems.contains(where: { $0.id == item.id })
            else { return }
            publishPlaybackState(.failed(item.id))
        }
    }

    func stopPlayback() {
        playbackRequestGeneration &+= 1
        requestedPlaybackMemoID = nil
        if playbackState != .stopped || audioPlayer.state != .stopped {
            audioPlayer.stop()
        }
        publishPlaybackState(.stopped)
    }

    private func publishPlaybackState(_ state: WatchPlaybackState) {
        guard playbackState != state else { return }
        playbackState = state
        if case .failed = state {
            playbackFailureHaptic()
        }
    }

    func delete(_ item: WatchQueueItem) async {
        guard item.canDelete, let store else { return }
        if playbackState == .playing(item.id) || requestedPlaybackMemoID == item.id {
            stopPlayback()
        }
        let cancelledBridgeWork = await cancelBridgeWork(for: item.id)
        do {
            try await store.deleteConfirmedLocal(memoID: item.id)
        } catch {
            captureState = .failed(.queueCommit)
        }
        await refreshQueue()
        if cancelledBridgeWork {
            await attemptUpload()
        }
    }

    func pair(
        bridge: DiscoveredBridge,
        confirmedPin: ConfirmedCertificatePin,
        code: String
    ) async -> Bool {
        bridgeState = .pairing
        do {
            let credential = try await pairingClient.pair(
                bridge: bridge,
                confirmedPin: confirmedPin,
                code: code
            )
            invalidateBridgeOperations()
            if let store {
                try await store.clearPairingRequirement()
            }
            hasSavedBridgeCredential = true
            bridgeState = .paired(credential.bridgeName)
            discovery.stop()
            await attemptUpload()
            return true
        } catch is CancellationError {
            bridgeState = .notPaired
            return false
        } catch {
            bridgeState = .needsAttention("Pairing failed. The code may be invalid or the bridge may be unavailable.")
            return false
        }
    }

    func forgetBridge() async {
        invalidateBridgeOperations()
        do {
            try await credentialStore.remove()
            hasSavedBridgeCredential = false
            bridgeState = .notPaired
        } catch {
            hasSavedBridgeCredential = true
            bridgeState = .needsAttention("Couldn’t remove the saved bridge credential.")
        }
    }

    private func waitForRecorderCompletion() {
        recorderCompletionTask?.cancel()
        recorderCompletionTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, let coordinator else { return }
            await coordinator.finishWhenRecorderCompletes()
            guard !Task.isCancelled else { return }
            recordingStartedAt = nil
            await refreshStateAndQueue()
            if case .savedOnWatch = captureState {
                WKInterfaceDevice.current().play(.success)
                await attemptUpload()
            } else if case .failed = captureState {
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }

    private func refreshStateAndQueue() async {
        if let coordinator {
            captureState = await coordinator.currentState
        }
        await refreshQueue()
    }

    private func refreshQueue() async {
        guard let store else { return }
        do {
            queueItems = try await store.loadAllMetadata().map {
                WatchQueueItem(
                    id: $0.memoID,
                    capturedAt: $0.capturedAt,
                    state: $0.state
                )
            }
            if let requestedPlaybackMemoID,
               !queueItems.contains(where: { $0.id == requestedPlaybackMemoID })
            {
                stopPlayback()
            }
        } catch {
            captureState = .failed(.recovery)
        }
    }

    private func restoreBridgeState() async {
        do {
            if let store, try await store.pairingIsRequired() {
                try? await credentialStore.remove()
                hasSavedBridgeCredential = false
                bridgeState = .needsAttention("Pair again")
                return
            }
            guard let credential = try await credentialStore.load() else {
                hasSavedBridgeCredential = false
                bridgeState = .notPaired
                return
            }
            hasSavedBridgeCredential = true
            bridgeState = persistedBridgeState(for: credential)
        } catch {
            hasSavedBridgeCredential = true
            bridgeState = .needsAttention("The saved bridge credential couldn’t be read.")
        }
    }

    private func attemptUpload() async {
        retryUploadTask?.cancel()
        retryUploadTask = nil
        if let activeUploadTask {
            await activeUploadTask.value
            return
        }
        let generation = bridgeSessionGeneration
        let uploadID = UUID()
        activeUploadID = uploadID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performUpload(generation: generation)
        }
        activeUploadTask = task
        await task.value
        if activeUploadID == uploadID {
            activeUploadID = nil
            activeUploadTask = nil
        }
    }

    private func performUpload(generation: UInt64) async {
        guard let transferCoordinator else { return }
        let credential: WatchBridgeCredential
        do {
            guard let loaded = try await credentialStore.load() else {
                guard generation == bridgeSessionGeneration else { return }
                hasSavedBridgeCredential = false
                if let store, (try? await store.pairingIsRequired()) == true {
                    bridgeState = .needsAttention("Pair again")
                } else {
                    bridgeState = .notPaired
                }
                return
            }
            credential = loaded
            guard generation == bridgeSessionGeneration, !Task.isCancelled else { return }
            hasSavedBridgeCredential = true
        } catch {
            guard generation == bridgeSessionGeneration, !Task.isCancelled else { return }
            hasSavedBridgeCredential = true
            bridgeState = .needsAttention("The saved bridge credential couldn’t be read.")
            return
        }

        if queueItems.contains(where: { $0.state == .saved }) {
            bridgeState = .sending(credential.bridgeName)
        }
        var receivedAtLeastOne = false
        var nextWorkNotBefore: Date?
        func recordNextWork(_ notBefore: Date) {
            nextWorkNotBefore = min(nextWorkNotBefore ?? notBefore, notBefore)
        }
        do {
            uploadLoop: for _ in 0 ..< WatchMemoStore.maximumMemoCount {
                let outcome = try await transferCoordinator.uploadNext()
                guard generation == bridgeSessionGeneration, !Task.isCancelled else { return }
                await refreshQueue()
                guard generation == bridgeSessionGeneration, !Task.isCancelled else { return }
                switch outcome {
                case .idle:
                    break uploadLoop
                case .busy:
                    bridgeState = .sending(credential.bridgeName)
                    return
                case .received:
                    receivedAtLeastOne = true
                    bridgeState = .received(credential.bridgeName)
                case let .retryScheduled(_, notBefore):
                    bridgeState = .waiting(credential.bridgeName)
                    recordNextWork(notBefore)
                    break uploadLoop
                case .pairingRequired:
                    try? await credentialStore.remove()
                    hasSavedBridgeCredential = false
                    bridgeState = .needsAttention("Pair again")
                    return
                case .needsAttention:
                    let readStatus: BridgeCredentialReadStatus
                    do {
                        readStatus = try await credentialStore.load() == nil ? .missing : .present
                    } catch {
                        readStatus = .unreadable
                    }
                    guard generation == bridgeSessionGeneration else { return }
                    let presentation = BridgeCredentialPresentation.afterRejectedUpload(
                        readStatus: readStatus
                    )
                    hasSavedBridgeCredential = presentation.hasSavedCredential
                    bridgeState = presentation.state
                    return
                case .statusUpdated:
                    break uploadLoop
                }
            }

            var hasPostReceiptWork = false
            statusLoop: for _ in 0 ..< WatchMemoStore.maximumMemoCount {
                let outcome = try await transferCoordinator.syncNextStatus()
                guard generation == bridgeSessionGeneration, !Task.isCancelled else { return }
                switch outcome {
                case .idle:
                    break
                case .busy:
                    hasPostReceiptWork = true
                    break
                case let .statusUpdated(_, state):
                    hasPostReceiptWork = state != .delivered && state != .needsAttention
                    if state == .delivered {
                        await performDeliveredRetentionMaintenance()
                        WKInterfaceDevice.current().play(.success)
                    }
                    await refreshQueue()
                    if state == .needsAttention {
                        bridgeState = .needsAttention("The Mac bridge needs attention. Audio remains on this Watch.")
                        return
                    }
                    continue
                case let .retryScheduled(_, notBefore):
                    bridgeState = .waiting(credential.bridgeName)
                    recordNextWork(notBefore)
                    break statusLoop
                case .pairingRequired:
                    try? await credentialStore.remove()
                    hasSavedBridgeCredential = false
                    bridgeState = .needsAttention("Pair again")
                    return
                case .needsAttention:
                    bridgeState = .needsAttention(
                        "The Mac bridge needs attention. Audio remains on this Watch."
                    )
                    return
                case .received:
                    break
                }
                break
            }
            await refreshQueue()
            hasPostReceiptWork = hasPostReceiptWork || queueItems.contains(where: {
                switch $0.state {
                case .received, .transcribing, .readyForCodex, .inserting, .reconciling: true
                case .saved, .uploading, .delivered, .needsAttention: false
                }
            })
            bridgeState = receivedAtLeastOne
                ? .received(credential.bridgeName)
                : persistedBridgeState(for: credential)
            if hasPostReceiptWork {
                statusPollAttempt &+= 1
                recordNextWork(
                    BridgeRetrySchedule.statusPollNotBefore(
                        now: retentionClock(),
                        attempt: statusPollAttempt,
                        sample: statusPollRandomSample()
                    )
                )
            } else {
                statusPollAttempt = 0
            }
            if let nextWorkNotBefore {
                scheduleRetry(notBefore: nextWorkNotBefore, generation: generation)
            }
        } catch is CancellationError {
            guard generation == bridgeSessionGeneration else { return }
            bridgeState = .waiting(credential.bridgeName)
        } catch let failure as WatchBridgeTransportFailure {
            guard generation == bridgeSessionGeneration else { return }
            switch failure {
            case .transient, .statusAbsent:
                statusPollAttempt &+= 1
                bridgeState = .waiting(credential.bridgeName)
                scheduleRetry(
                    notBefore: BridgeRetrySchedule.statusPollNotBefore(
                        now: retentionClock(),
                        attempt: statusPollAttempt,
                        sample: statusPollRandomSample()
                    ),
                    generation: generation
                )
            case .authentication:
                invalidateBridgeOperations()
                hasSavedBridgeCredential = false
                bridgeState = .notPaired
            case .conflict, .permanent:
                bridgeState = .needsAttention("The recording remains on this Watch. The Mac bridge status could not be verified.")
            }
        } catch {
            guard generation == bridgeSessionGeneration else { return }
            statusPollAttempt &+= 1
            bridgeState = .waiting(credential.bridgeName)
            scheduleRetry(
                notBefore: BridgeRetrySchedule.statusPollNotBefore(
                    now: retentionClock(),
                    attempt: statusPollAttempt,
                    sample: statusPollRandomSample()
                ),
                generation: generation
            )
        }
    }

    private func cancelBridgeWork(for memoID: MemoID) async -> Bool {
        guard let transferActivityRegistry,
              let task = activeUploadTask
        else { return false }
        let cancelled = await transferActivityRegistry.cancelIfActive(memoID) {
            task.cancel()
        }
        guard cancelled else { return false }
        await task.value
        activeUploadTask = nil
        activeUploadID = nil
        return true
    }

    private func scheduleRetry(notBefore: Date, generation: UInt64) {
        retryUploadTask?.cancel()
        let nanoseconds = BridgeRetrySchedule.nanosecondsUntilRetry(
            now: retentionClock(),
            notBefore: notBefore
        )
        let retrySleep = retrySleep
        retryUploadTask = Task { @MainActor [weak self] in
            do {
                try await retrySleep(nanoseconds)
            } catch {
                return
            }
            guard let self,
                  generation == bridgeSessionGeneration,
                  hasSavedBridgeCredential
            else { return }
            retryUploadTask = nil
            await attemptUpload()
        }
    }

    private func performDeliveredRetentionMaintenance() async {
        guard let deliveredRetentionMaintainer else { return }
        // Failure is fail-safe: raw audio remains and the next lifecycle will
        // retry the delivered-only maintenance pass.
        _ = try? await deliveredRetentionMaintainer.performMaintenance()
    }

    private func rebuildDeliveredRetentionMaintainer() throws {
        guard let store else {
            deliveredRetentionMaintainer = nil
            return
        }
        if let retentionMaintainerFactoryOverride {
            deliveredRetentionMaintainer = retentionMaintainerFactoryOverride(
                deliveredRetentionChoice
            )
        } else {
            deliveredRetentionMaintainer = try Self.makeRetentionMaintainer(
                store: store,
                choice: deliveredRetentionChoice,
                clock: retentionClock
            )
        }
    }

    private static func normalizedRetentionChoice(
        from preferenceStore: WatchRetentionPreferenceStoring
    ) -> WatchDeliveredRetentionChoice {
        guard let choice = WatchDeliveredRetentionChoice(
            rawValue: preferenceStore.deliveredRetentionDays
        ) else {
            preferenceStore.deliveredRetentionDays = WatchDeliveredRetentionChoice.sevenDays.rawValue
            return .sevenDays
        }
        return choice
    }

    private static func makeRetentionMaintainer(
        store: WatchMemoStore,
        choice: WatchDeliveredRetentionChoice,
        clock: @escaping @Sendable () -> Date
    ) throws -> WatchDeliveredRetentionMaintainer {
        WatchDeliveredRetentionMaintainer(
            store: store,
            policy: try WatchDeliveredRetentionPolicy(
                retentionInterval: TimeInterval(choice.rawValue * 24 * 60 * 60)
            ),
            clock: clock
        )
    }

    private func invalidateBridgeOperations() {
        bridgeSessionGeneration &+= 1
        activeUploadTask?.cancel()
        activeUploadTask = nil
        activeUploadID = nil
        retryUploadTask?.cancel()
        retryUploadTask = nil
        statusPollAttempt = 0
    }

    private func persistedBridgeState(for credential: WatchBridgeCredential) -> WatchBridgeConnectionState {
        if queueItems.contains(where: { $0.state == .needsAttention }) {
            return .needsAttention("A saved recording needs attention. Its audio remains on this Watch.")
        }
        if queueItems.contains(where: { $0.state == .uploading }) {
            return .sending(credential.bridgeName)
        }
        if queueItems.contains(where: {
            switch $0.state {
            case .received, .transcribing, .readyForCodex, .inserting, .reconciling: true
            case .saved, .uploading, .delivered, .needsAttention: false
            }
        }) {
            return .received(credential.bridgeName)
        }
        if queueItems.contains(where: { $0.state == .saved }) {
            return .waiting(credential.bridgeName)
        }
        return .paired(credential.bridgeName)
    }
}

enum BridgeRetrySchedule {
    private static let fullJitter = try! FullJitterBackoff(
        baseDelay: 5,
        maximumDelay: 900
    )

    static func nanosecondsUntilRetry(now: Date, notBefore: Date) -> UInt64 {
        let seconds = max(0, notBefore.timeIntervalSince(now))
        let bounded = min(seconds, 24 * 60 * 60)
        return UInt64((bounded * 1_000_000_000).rounded(.up))
    }

    static func statusPollNotBefore(
        now: Date,
        attempt: UInt64,
        sample: Double
    ) -> Date {
        let zeroBasedAttempt = attempt > 0 ? attempt - 1 : 0
        return now.addingTimeInterval(
            fullJitter.delay(afterAttempt: zeroBasedAttempt, sample: sample)
        )
    }
}
