import CodexBridgeShared
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: VoiceCaptureModel
    @State private var itemPendingDeletion: WatchQueueItem?

    private var summary: RelayLedgerSummary {
        RelayLedgerSummary(count: model.queueItems.count)
    }

    var body: some View {
        Group {
            if model.queueItems.isEmpty {
                RelayLedgerEmptyView()
            } else {
                List {
                    Section {
                        ForEach(Array(model.queueItems.enumerated()), id: \.element.id) { index, item in
                            let presentation = RelayItemPresentation.make(item: item)
                            RelayLedgerRow(
                                item: item,
                                presentation: presentation,
                                isLast: index == model.queueItems.count - 1,
                                playbackActionTitle: playbackActionTitle(for: item),
                                playbackIcon: playbackIcon(for: item),
                                playbackDisabled: model.isRecording,
                                onPlayback: {
                                    Task { await model.togglePlayback(item) }
                                },
                                onDelete: {
                                    itemPendingDeletion = item
                                }
                            )
                        }
                    } header: {
                        Text(summary.accessibilityValue)
                            .font(WatchExperienceTheme.TypeRole.headerUtility)
                    }
                }
            }
        }
        .navigationTitle("Relay ledger")
        .onAppear {
            model.handleQueueAppeared()
        }
        .onDisappear {
            model.handleQueueDisappeared()
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete recording", role: .destructive) {
                guard let item = itemPendingDeletion else { return }
                itemPendingDeletion = nil
                Task { await model.delete(item) }
            }
            Button("Keep recording", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text(itemPendingDeletion?.deletionWarning ?? "")
        }
    }

    private func playbackActionTitle(for item: WatchQueueItem) -> String {
        switch model.playbackState {
        case let .playing(memoID) where memoID == item.id:
            "Stop playback"
        case let .failed(memoID) where memoID == item.id:
            "Try playback again"
        default:
            "Play recording"
        }
    }

    private func playbackIcon(for item: WatchQueueItem) -> String {
        model.playbackState == .playing(item.id) ? "stop.fill" : "play.fill"
    }
}
