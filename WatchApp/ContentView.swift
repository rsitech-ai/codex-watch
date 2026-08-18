import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: VoiceCaptureModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsPairing = false
    @State private var showsQueue = false
    @State private var showsRetention = false

    private var presentation: CaptureScenePresentation {
        CaptureScenePresentation.make(
            captureState: model.captureState,
            bridgeState: model.bridgeState
        )
    }

    var body: some View {
        CaptureScene(
            presentation: presentation,
            bridgeTitle: model.bridgeState.title,
            recordingStartedAt: model.recordingStartedAt,
            maximumDuration: model.maximumDuration,
            recordingLimitDetail: { now in
                guard let startedAt = model.recordingStartedAt else {
                    return presentation.detail
                }
                return model.recordingLimitDetail(from: startedAt, to: now)
            },
            queueCount: model.queueItems.count,
            onPrimaryAction: performPrimaryAction,
            onOpenPairing: { showsPairing = true },
            onOpenRetention: { showsRetention = true },
            onOpenQueue: { showsQueue = true },
            bridgeIsPaired: model.bridgeState.isPaired
        )
        .navigationDestination(isPresented: $showsPairing) {
            PairingView()
                .environmentObject(model)
        }
        .navigationDestination(isPresented: $showsQueue) {
            QueueView()
                .environmentObject(model)
        }
        .navigationDestination(isPresented: $showsRetention) {
            RetentionSettingsView()
                .environmentObject(model)
        }
        .task {
            await model.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.handleAppBecameActive() }
            } else {
                model.handleAppBecameInactive()
            }
        }
    }

    private func performPrimaryAction(_ action: WatchPrimaryAction) {
        switch action {
        case .record, .stopAndSave, .recordAnother:
            Task { await model.toggleRecording() }
        case .openPairing:
            showsPairing = true
        case .retryRelay:
            Task { await model.handleAppBecameActive() }
        case .none:
            break
        }
    }
}
