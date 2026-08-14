import SwiftUI

enum WatchExperienceTheme {
    enum ColorToken {
        static let active = Color(red: 0.18, green: 0.86, blue: 0.94)
        static let confirmed = Color(red: 0.69, green: 0.93, blue: 0.22)
        static let attention = Color(red: 1.00, green: 0.68, blue: 0.18)
        static let destructive = Color(red: 1.00, green: 0.27, blue: 0.32)
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

    enum Metric {
        static let nodeSize: CGFloat = 17
        static let spineWidth: CGFloat = 2
        static let nodeSpacing: CGFloat = 16
        static let buttonHeight: CGFloat = 42
        static let buttonRadius: CGFloat = 13
    }
}
