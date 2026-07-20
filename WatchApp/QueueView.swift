import CodexBridgeShared
import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var model: VoiceCaptureModel
    @State private var itemPendingDeletion: WatchQueueItem?

    var body: some View {
        Group {
            if model.queueItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No saved ideas")
                        .font(.headline)
                    Text("Record an idea and it will wait here until your Mac bridge receives it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                List(model.queueItems) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(item.statusText, systemImage: icon(for: item.state))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: item.state))
                            .accessibilityValue(item.statusText)
                        Text(item.capturedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            Task {
                                await model.togglePlayback(item)
                            }
                        } label: {
                            Label(
                                playbackActionTitle(for: item),
                                systemImage: playbackIcon(for: item)
                            )
                        }
                        .font(.caption2)
                        .accessibilityValue(item.statusText)
                        .disabled(model.isRecording)
                        if item.canDelete {
                            Button("Delete from Watch", role: .destructive) {
                                itemPendingDeletion = item
                            }
                            .font(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved ideas")
        .onAppear {
            model.handleQueueAppeared()
        }
        .onDisappear {
            model.handleQueueDisappeared()
        }
        .confirmationDialog(
            "Delete this idea?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete recording", role: .destructive) {
                guard let item = itemPendingDeletion else { return }
                itemPendingDeletion = nil
                Task {
                    await model.delete(item)
                }
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
            return "Stop playback"
        case let .failed(memoID) where memoID == item.id:
            return "Try playback again"
        default:
            return "Play recording"
        }
    }

    private func playbackIcon(for item: WatchQueueItem) -> String {
        model.playbackState == .playing(item.id) ? "stop.fill" : "play.fill"
    }

    private func icon(for state: MemoState) -> String {
        switch state {
        case .saved:
            return "applewatch"
        case .uploading, .received:
            return "arrow.up.circle.fill"
        case .transcribing:
            return "waveform"
        case .readyForCodex, .inserting, .reconciling:
            return "sparkles"
        case .delivered:
            return "checkmark.circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        }
    }

    private func color(for state: MemoState) -> Color {
        switch state {
        case .delivered:
            return .green
        case .needsAttention:
            return .orange
        default:
            return .accentColor
        }
    }
}
