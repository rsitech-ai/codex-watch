import SwiftUI

struct RelayLedgerSummary: Equatable {
    let count: Int

    var accessibilityValue: String {
        switch count {
        case 0:
            "No saved recordings"
        case 1:
            "1 saved recording"
        default:
            "\(count) saved recordings"
        }
    }
}

struct RelayLedgerRow: View {
    let item: WatchQueueItem
    let presentation: RelayItemPresentation
    let isLast: Bool
    let playbackActionTitle: String
    let playbackIcon: String
    let playbackDisabled: Bool
    var timestampLabel: String? = nil
    let onPlayback: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            chronologicalRule

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(toneColor)
                        .lineLimit(2)
                    Text(presentation.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    timestamp
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityValue)
                .accessibilityValue(timestampAccessibilityValue)

                HStack(spacing: 12) {
                    Button(action: onPlayback) {
                        Image(systemName: playbackIcon)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .disabled(playbackDisabled)
                    .accessibilityLabel(playbackActionTitle)
                    .accessibilityValue(presentation.status)

                    if item.canDelete {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete from Watch")
                        .accessibilityHint("Opens a confirmation before deleting this recording")
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var chronologicalRule: some View {
        VStack(spacing: 3) {
            node
            if !isLast {
                Rectangle()
                    .fill(WatchExperienceTheme.ColorToken.neutral.opacity(0.45))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let timestampLabel {
            Text(timestampLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        } else {
            Text(item.capturedAt, style: .relative)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var timestampAccessibilityValue: Text {
        if let timestampLabel {
            return Text(timestampLabel)
        }
        return Text(item.capturedAt, style: .relative)
    }

    @ViewBuilder
    private var node: some View {
        switch presentation.tone {
        case .neutral:
            Circle()
                .stroke(toneColor, lineWidth: 1.5)
                .frame(width: 11, height: 11)
        case .active:
            RoundedRectangle(cornerRadius: 2)
                .fill(toneColor)
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(45))
        case .confirmed:
            ZStack {
                Circle()
                    .fill(toneColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.black)
            }
            .frame(width: 13, height: 13)
        case .attention, .destructive:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(toneColor)
        }
    }

    private var toneColor: Color {
        WatchExperienceTheme.ColorToken.forTone(presentation.tone)
    }
}
