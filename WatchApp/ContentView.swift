import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: VoiceCaptureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                connectionStatus
                recordingStatus
                recordButton
                queueLink
                retentionLink
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("Voice Inbox")
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

    private var connectionStatus: some View {
        NavigationLink {
            PairingView()
                .environmentObject(model)
        } label: {
            Label(model.bridgeState.title, systemImage: bridgeStatusIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(bridgeStatusColor)
                .lineLimit(1)
        }
        .accessibilityLabel("Mac bridge status: \(model.bridgeState.title)")
        .accessibilityHint("Opens local Mac bridge pairing")
    }

    private var bridgeStatusIcon: String {
        switch model.bridgeState {
        case .notPaired, .needsAttention:
            return "desktopcomputer.trianglebadge.exclamationmark"
        case .pairing, .waiting:
            return "desktopcomputer.and.arrow.down"
        case .sending:
            return "arrow.up.circle.fill"
        case .received:
            return "checkmark.circle.fill"
        case .paired:
            return "desktopcomputer"
        }
    }

    private var bridgeStatusColor: Color {
        switch model.bridgeState {
        case .notPaired, .waiting:
            return .orange
        case .needsAttention:
            return .red
        case .pairing, .sending:
            return .blue
        case .received, .paired:
            return .green
        }
    }

    private var recordingStatus: some View {
        VStack(spacing: 2) {
            if model.isRecording, let startedAt = model.recordingStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let limitDetail = model.recordingLimitDetail(
                        from: startedAt,
                        to: context.date
                    )
                    VStack(spacing: 2) {
                        Text(elapsedText(from: startedAt, to: context.date))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .accessibilityLabel("Recording time")
                            .accessibilityValue(elapsedText(from: startedAt, to: context.date))
                        Text(limitDetail)
                            .font(.caption2)
                            .foregroundStyle(limitDetail == "Tap to stop" ? Color.secondary : Color.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(model.stateTitle)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                Text(model.stateDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 42)
        .accessibilityElement(children: .combine)
    }

    private var recordButton: some View {
        Button {
            Task {
                await model.toggleRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        model.isRecording
                            ? AnyShapeStyle(Color.red.gradient)
                            : AnyShapeStyle(Color.accentColor.gradient)
                    )
                Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.isRecording && !reduceMotion)
            }
            .frame(width: 82, height: 82)
            .shadow(color: (model.isRecording ? Color.red : Color.accentColor).opacity(0.3), radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(model.primaryActionDisabled)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Record idea")
        .accessibilityValue(model.stateTitle)
        .accessibilityHint(model.isRecording ? "Stops and saves the idea on this Watch" : "Starts a new voice recording")
    }

    private var queueLink: some View {
        NavigationLink {
            QueueView()
                .environmentObject(model)
        } label: {
            HStack {
                Label("Saved ideas", systemImage: "tray.full.fill")
                Spacer()
                Text("\(model.queueItems.count)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue("\(model.queueItems.count) items")
    }

    private var retentionLink: some View {
        NavigationLink {
            RetentionSettingsView()
                .environmentObject(model)
        } label: {
            HStack {
                Text("Keep delivered audio")
                Spacer()
                Text(model.deliveredRetentionChoice.label)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityHint("Changes how long ideas already added to Codex remain on this Watch")
    }

    private func elapsedText(from start: Date, to now: Date) -> String {
        let elapsed = min(Int(now.timeIntervalSince(start)), Int(model.maximumDuration))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }
}
