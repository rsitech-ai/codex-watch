import Foundation

public struct ReadinessReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let label: String
    public let code: String
    public let device: String
    public let model: String
    public let osVersion: String
    public let lockState: String

    public init(readiness: WatchReadiness) {
        schemaVersion = 1
        label = readiness.code == .ready ? "unverified" : "blocked:external"
        code = readiness.code.rawValue
        device = Self.sanitize(readiness.deviceName ?? "unknown")
        model = Self.sanitize(readiness.model ?? "unknown")
        osVersion = Self.sanitize(readiness.osVersion ?? "unknown")
        switch readiness.code {
        case .deviceLocked:
            lockState = "locked"
        case .lockStateUnknown:
            lockState = "unknown"
        default:
            lockState = readiness.lockStateObserved ? "unlocked" : "unobserved"
        }
    }

    public init(code: String, label: String = "blocked:external") {
        schemaVersion = 1
        self.label = label
        self.code = Self.sanitize(code)
        device = "unknown"
        model = "unknown"
        osVersion = "unknown"
        lockState = "unobserved"
    }

    public var humanDescription: String {
        "label=\(label); code=\(code); device=\(device); model=\(model); os=\(osVersion); lock-state=\(lockState)"
    }

    private static func sanitize(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            switch character {
            case ";", "=", "\n", "\r", "\t": " "
            default: character
            }
        }
        let normalized = String(replaced)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String((normalized.isEmpty ? "unknown" : normalized).prefix(128))
    }
}
