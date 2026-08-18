import Foundation

public enum SignalExperienceToken: Sendable {
    public enum RGB: Sendable {
        public static let active = (red: 0.18, green: 0.86, blue: 0.94)
        public static let confirmed = (red: 0.69, green: 0.93, blue: 0.22)
        public static let attention = (red: 1.00, green: 0.68, blue: 0.18)
        public static let destructive = (red: 1.00, green: 0.27, blue: 0.32)
    }

    public enum Motion: Sendable {
        public static let springResponse = 0.35
        public static let springDamping = 1.0
        public static let crossFadeDuration = 0.2
    }
}
