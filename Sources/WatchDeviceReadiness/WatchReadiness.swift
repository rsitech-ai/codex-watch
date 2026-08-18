import Foundation

public struct WatchReadiness: Sendable, Equatable {
    public enum Code: String, Sendable, CaseIterable {
        case ready = "READY"
        case noMatchingWatch = "NO_MATCHING_WATCH"
        case ambiguousWatch = "AMBIGUOUS_WATCH"
        case selectedWatchMissing = "SELECTED_WATCH_MISSING"
        case watchNotPaired = "WATCH_NOT_PAIRED"
        case developerModeDisabled = "DEVELOPER_MODE_DISABLED"
        case developerModeUnknown = "DEVELOPER_MODE_UNKNOWN"
        case supportingPhoneUnavailable = "SUPPORTING_PHONE_UNAVAILABLE"
        case watchTunnelDisconnected = "WATCH_TUNNEL_DISCONNECTED"
        case ddiServicesUnavailable = "DDI_SERVICES_UNAVAILABLE"
        case deviceLocked = "DEVICE_LOCKED"
        case lockStateUnknown = "LOCK_STATE_UNKNOWN"
        case contradictoryState = "CONTRADICTORY_STATE"
    }

    public let code: Code
    public let deviceName: String?
    public let model: String?
    public let osVersion: String?
    public let lockStateObserved: Bool
}

public enum WatchReadinessClassifier {
    public static func classify(
        _ inventory: DeviceInventory,
        selectedIdentifier: String? = nil
    ) -> WatchReadiness {
        let watches = inventory.devices.filter {
            $0.reality == "physical"
                && $0.platform == "watchOS"
                && $0.deviceType == "appleWatch"
        }
        let selected: DeviceInventory.Device

        if let selectedIdentifier {
            guard let match = watches.first(where: { $0.identifier == selectedIdentifier }) else {
                return result(.selectedWatchMissing)
            }
            selected = match
        } else {
            guard !watches.isEmpty else { return result(.noMatchingWatch) }
            guard watches.count == 1 else { return result(.ambiguousWatch) }
            selected = watches[0]
        }

        if selected.tunnelState == "connected", selected.bootState != "booted" {
            return result(.contradictoryState, device: selected)
        }
        guard selected.pairingState == "paired" else {
            return result(.watchNotPaired, device: selected)
        }
        switch selected.developerModeStatus {
        case "enabled": break
        case "disabled": return result(.developerModeDisabled, device: selected)
        default: return result(.developerModeUnknown, device: selected)
        }

        let supportingPhoneIsReady = inventory.devices.contains {
            $0.reality == "physical"
                && $0.platform == "iOS"
                && $0.deviceType == "iPhone"
                && $0.pairingState == "paired"
                && $0.bootState == "booted"
                && $0.tunnelState == "connected"
                && $0.ddiServicesAvailable == true
        }
        guard supportingPhoneIsReady else {
            return result(.supportingPhoneUnavailable, device: selected)
        }
        guard selected.tunnelState == "connected" else {
            return result(.watchTunnelDisconnected, device: selected)
        }
        guard selected.ddiServicesAvailable == true else {
            return result(.ddiServicesUnavailable, device: selected)
        }
        switch selected.lockState {
        case .locked:
            return result(.deviceLocked, device: selected)
        case .unknown:
            return result(.lockStateUnknown, device: selected)
        case .unlocked, .unobserved:
            return result(.ready, device: selected)
        }
    }

    private static func result(
        _ code: WatchReadiness.Code,
        device: DeviceInventory.Device? = nil
    ) -> WatchReadiness {
        WatchReadiness(
            code: code,
            deviceName: device?.name,
            model: device?.model,
            osVersion: device?.osVersion,
            lockStateObserved: device.map { $0.lockState != .unobserved } ?? false
        )
    }
}
