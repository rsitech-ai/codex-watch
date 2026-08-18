import SwiftUI

enum SignalSpineAccessibility {
    static let label = "Delivery path"

    static func value(for presentation: SignalSpinePresentation) -> String {
        presentation.accessibilityValue
    }
}

struct SignalSpineView: View {
    let presentation: SignalSpinePresentation
    var nodeSpacing = WatchExperienceTheme.Metric.nodeSpacing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nodes: [(label: String, state: SignalNodeVisualState)] {
        [
            ("WATCH", presentation.watch),
            ("MAC", presentation.mac),
            ("CODEX", presentation.codex),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                HStack(spacing: 8) {
                    SignalNode(state: node.state)
                    Text(node.label)
                        .font(WatchExperienceTheme.TypeRole.spineLabel)
                        .tracking(WatchExperienceTheme.TypeRole.spineTracking)
                        .foregroundStyle(color(for: node.state))
                }
                .frame(height: WatchExperienceTheme.Metric.nodeSize)

                if index < nodes.count - 1 {
                    Rectangle()
                        .fill(segmentColor(after: index))
                        .frame(
                            width: WatchExperienceTheme.Metric.spineWidth,
                            height: nodeSpacing
                        )
                        .padding(.leading, (WatchExperienceTheme.Metric.nodeSize - WatchExperienceTheme.Metric.spineWidth) / 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SignalSpineAccessibility.label)
        .accessibilityValue(SignalSpineAccessibility.value(for: presentation))
        .animation(
            SignalMotionStyle.forTransition(reduceMotion: reduceMotion).animation,
            value: presentation
        )
    }

    private func color(for state: SignalNodeVisualState) -> Color {
        WatchExperienceTheme.ColorToken.forNode(state)
    }

    private func segmentColor(after index: Int) -> Color {
        let states = [presentation.watch, presentation.mac, presentation.codex]
        return WatchExperienceTheme.Connector.color(destination: states[index + 1])
    }
}

private struct SignalNode: View {
    let state: SignalNodeVisualState

    var body: some View {
        ZStack {
            switch state {
            case .pending:
                Circle()
                    .stroke(color, lineWidth: 1.5)
                    .padding(3)
            case .active:
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color)
                    .padding(3)
                    .rotationEffect(.degrees(45))
            case .confirmed:
                Circle()
                    .fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.black)
            case .attention:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(
            width: WatchExperienceTheme.Metric.nodeSize,
            height: WatchExperienceTheme.Metric.nodeSize
        )
        .accessibilityHidden(true)
    }

    private var color: Color {
        WatchExperienceTheme.ColorToken.forNode(state)
    }
}
