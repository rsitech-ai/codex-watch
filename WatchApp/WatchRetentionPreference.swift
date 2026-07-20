import CodexBridgeShared
import CodexWatchCore
import Foundation

enum WatchDeliveredRetentionChoice: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }
}

@MainActor
protocol WatchRetentionPreferenceStoring: AnyObject {
    var deliveredRetentionDays: Int { get set }
}

@MainActor
final class WatchUserDefaultsRetentionPreferenceStore: WatchRetentionPreferenceStoring {
    static let deliveredRetentionDaysKey = "deliveredRetentionDays"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deliveredRetentionDays: Int {
        get { defaults.integer(forKey: Self.deliveredRetentionDaysKey) }
        set { defaults.set(newValue, forKey: Self.deliveredRetentionDaysKey) }
    }
}

protocol WatchDeliveredRetentionMaintaining: AnyObject, Sendable {
    func performMaintenance() async throws -> [MemoID]
}

extension WatchDeliveredRetentionMaintainer: WatchDeliveredRetentionMaintaining {}
