import SwiftUI

struct WatchPrimaryActionView: View {
    let action: WatchPrimaryAction
    var tone: WatchExperienceTone = .active
    var isDisabled = false
    let perform: () -> Void

    var body: some View {
        if let content = content {
            Button(action: perform) {
                Label(content.label, systemImage: content.symbol)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity)
                    .frame(height: WatchExperienceTheme.Metric.buttonHeight)
                    .foregroundStyle(.black.opacity(isDisabled ? 0.45 : 0.9))
                    .background {
                        RoundedRectangle(cornerRadius: WatchExperienceTheme.Metric.buttonRadius)
                            .fill(buttonColor.opacity(isDisabled ? 0.42 : 1))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: WatchExperienceTheme.Metric.buttonRadius))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(content.label)
            .accessibilityHint(content.hint)
        }
    }

    private var buttonColor: Color {
        WatchExperienceTheme.ColorToken.forTone(tone)
    }

    private var content: ActionContent? {
        switch action {
        case .record:
            ActionContent(
                label: "Tap to record",
                symbol: "waveform",
                hint: "Starts a new voice recording on this Watch"
            )
        case .stopAndSave:
            ActionContent(
                label: "Stop & save",
                symbol: "stop.fill",
                hint: "Stops recording and saves the audio on this Watch"
            )
        case .openPairing:
            ActionContent(
                label: "Pair with Mac",
                symbol: "link",
                hint: "Opens secure Mac pairing"
            )
        case .retryRelay:
            ActionContent(
                label: "Retry relay",
                symbol: "arrow.clockwise",
                hint: "Retries delivery of the saved recording"
            )
        case .recordAnother:
            ActionContent(
                label: "Record another",
                symbol: "plus",
                hint: "Starts another voice recording on this Watch"
            )
        case .none:
            nil
        }
    }
}

private struct ActionContent {
    let label: String
    let symbol: String
    let hint: String
}
