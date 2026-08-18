import SwiftUI

enum WatchPrimaryActionCopy {
    static func content(for action: WatchPrimaryAction) -> (label: String, symbol: String, hint: String)? {
        switch action {
        case .record:
            ("Tap to record", "waveform", "Starts a new voice recording on this Watch")
        case .stopAndSave:
            ("Stop & save", "stop.fill", "Stops recording and saves the audio on this Watch")
        case .openPairing:
            ("Pair with Mac", "link", "Opens secure Mac pairing")
        case .retryRelay:
            ("Retry relay", "arrow.clockwise", "Retries delivery of the saved recording")
        case .recordAnother:
            ("Record another", "plus", "Starts another voice recording on this Watch")
        case .none:
            nil
        }
    }
}

struct WatchPrimaryActionView: View {
    let action: WatchPrimaryAction
    var tone: WatchExperienceTone = .active
    var isDisabled = false
    let perform: () -> Void

    var body: some View {
        if let content = WatchPrimaryActionCopy.content(for: action) {
            Button(action: perform) {
                Label(content.label, systemImage: content.symbol)
                    .font(WatchExperienceTheme.TypeRole.primaryAction)
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
            .buttonStyle(WatchFilledActionStyle(isDisabled: isDisabled))
            .disabled(isDisabled)
            .accessibilityLabel(content.label)
            .accessibilityHint(content.hint)
        }
    }

    private var buttonColor: Color {
        WatchExperienceTheme.ColorToken.forTone(tone)
    }
}

private struct WatchFilledActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isDisabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !isDisabled && !reduceMotion ? 0.97 : 1)
            .animation(
                SignalMotionStyle.forTransition(reduceMotion: reduceMotion).animation,
                value: configuration.isPressed
            )
    }
}
