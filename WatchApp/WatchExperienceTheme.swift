import CodexBridgeShared
import SwiftUI

enum WatchExperienceTheme {
    enum RGB {
        static let active = SignalExperienceToken.RGB.active
        static let confirmed = SignalExperienceToken.RGB.confirmed
        static let attention = SignalExperienceToken.RGB.attention
        static let destructive = SignalExperienceToken.RGB.destructive
        static let catalogAccent = (red: 0.169, green: 0.604, blue: 0.996)
    }

    enum ColorToken {
        static let active = Color(
            red: RGB.active.red,
            green: RGB.active.green,
            blue: RGB.active.blue
        )
        static let confirmed = Color(
            red: RGB.confirmed.red,
            green: RGB.confirmed.green,
            blue: RGB.confirmed.blue
        )
        static let attention = Color(
            red: RGB.attention.red,
            green: RGB.attention.green,
            blue: RGB.attention.blue
        )
        static let destructive = Color(
            red: RGB.destructive.red,
            green: RGB.destructive.green,
            blue: RGB.destructive.blue
        )
        static let neutral = Color.white.opacity(0.42)
        static let surface = Color.white.opacity(0.10)
        static let surfacePressed = Color.white.opacity(0.16)

        static func forTone(_ tone: WatchExperienceTone) -> Color {
            switch tone {
            case .neutral:
                neutral
            case .active:
                active
            case .confirmed:
                confirmed
            case .attention:
                attention
            case .destructive:
                destructive
            }
        }

        static func forNode(_ state: SignalNodeVisualState) -> Color {
            switch state {
            case .pending:
                neutral
            case .active:
                active
            case .confirmed:
                confirmed
            case .attention:
                attention
            }
        }
    }

    enum TypeRole {
        static func kicker(compact: Bool) -> Font {
            .system(size: compact ? 9 : 10, weight: .bold, design: .rounded)
        }

        static func kickerTracking(compact: Bool) -> CGFloat {
            compact ? 0.4 : 0.75
        }

        static let spineLabel = Font.system(size: 10, weight: .semibold, design: .rounded)
        static let spineTracking: CGFloat = 0.7

        static func heroHeadline(compact: Bool) -> Font {
            .system(compact ? .headline : .title3, design: .rounded, weight: .bold)
        }

        static func recordingTime(compact: Bool) -> Font {
            .system(compact ? .title2 : .title, design: .rounded, weight: .bold)
        }

        static let detail = Font.caption2
        static let primaryAction = Font.system(.body, design: .rounded, weight: .semibold)
        static let headerUtility = Font.caption2.weight(.semibold)
        static let pairingRailTitle = Font.system(size: 9, weight: .bold, design: .rounded)
        static let pairingRailTracking: CGFloat = 0.7
        static let ledgerStatus = Font.caption.weight(.bold)
        static let emptyHeadline = Font.system(.headline, design: .rounded, weight: .bold)
    }

    enum Connector {
        static func opacity(destinationPending: Bool) -> Double {
            destinationPending ? 0.45 : 0.8
        }

        static func color(destination: SignalNodeVisualState) -> Color {
            let pending = destination == .pending
            let base = pending ? ColorToken.neutral : ColorToken.forNode(destination)
            return base.opacity(opacity(destinationPending: pending))
        }
    }

    enum Metric {
        static let nodeSize: CGFloat = 17
        static let spineWidth: CGFloat = 2
        static let nodeSpacing: CGFloat = 16
        static let buttonHeight: CGFloat = 42
        static let buttonRadius: CGFloat = 13
    }
}
