import Foundation

public struct WatchSimulatorDestination: Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let runtimeIdentifier: String
    public let runtimeVersion: String
    public let displayMillimeters: Int
    public let rationale: String
}

public enum WatchSimulatorSelector {
    private static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime.watchOS-"
    private static let watchDevicePrefix = "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-"

    public static func select(
        activeSDK: String,
        runtimes: [SimulatorRuntime],
        devices: [SimulatorDevice]
    ) throws -> WatchSimulatorDestination {
        let candidates = try validatedCandidates(
            activeSDK: activeSDK,
            runtimes: runtimes,
            devices: devices,
            rationale: "smallest-available-display-on-exact-active-runtime"
        )
        return candidates.sorted(by: stableDestinationOrder)[0]
    }

    public static func selectEachDisplaySize(
        activeSDK: String,
        runtimes: [SimulatorRuntime],
        devices: [SimulatorDevice]
    ) throws -> [WatchSimulatorDestination] {
        let candidates = try validatedCandidates(
            activeSDK: activeSDK,
            runtimes: runtimes,
            devices: devices,
            rationale: "one-stable-destination-per-display-on-exact-active-runtime"
        )
        let destinationsBySize = Dictionary(grouping: candidates, by: \.displayMillimeters)
        return destinationsBySize.keys.sorted().compactMap { size in
            destinationsBySize[size]?.sorted(by: stableDestinationOrder).first
        }
    }

    private static func validatedCandidates(
        activeSDK: String,
        runtimes: [SimulatorRuntime],
        devices: [SimulatorDevice],
        rationale: String
    ) throws -> [WatchSimulatorDestination] {
        guard activeSDK.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw WatchSimulatorSelectionError.invalidSDKVersion
        }

        let exactRuntimes = runtimes.filter {
            $0.platform == "watchOS"
                && $0.isAvailable
                && $0.version == activeSDK
                && $0.identifier.hasPrefix(runtimePrefix)
        }
        let runtimeIdentifiers = Set(exactRuntimes.map(\.identifier))
        guard !runtimeIdentifiers.isEmpty else {
            throw WatchSimulatorSelectionError.exactRuntimeUnavailable
        }
        guard runtimeIdentifiers.count == 1,
              let runtimeIdentifier = runtimeIdentifiers.first
        else {
            throw WatchSimulatorSelectionError.contradictoryInventory
        }

        let watchDevices = devices.filter {
            $0.runtimeIdentifier == runtimeIdentifier
                && $0.isAvailable
                && $0.deviceTypeIdentifier.hasPrefix(watchDevicePrefix)
        }
        guard !watchDevices.isEmpty else {
            throw WatchSimulatorSelectionError.noAvailableWatch
        }
        guard Set(watchDevices.map(\.identifier)).count == watchDevices.count else {
            throw WatchSimulatorSelectionError.contradictoryInventory
        }

        let candidates = try watchDevices.map { device -> WatchSimulatorDestination in
            guard let displayMillimeters = displaySize(from: device.name) else {
                throw WatchSimulatorSelectionError.unknownDisplaySize
            }
            return WatchSimulatorDestination(
                name: device.name,
                identifier: device.identifier,
                runtimeIdentifier: runtimeIdentifier,
                runtimeVersion: activeSDK,
                displayMillimeters: displayMillimeters,
                rationale: rationale
            )
        }
        return candidates
    }

    private static func stableDestinationOrder(
        _ lhs: WatchSimulatorDestination,
        _ rhs: WatchSimulatorDestination
    ) -> Bool {
        if lhs.displayMillimeters != rhs.displayMillimeters {
            return lhs.displayMillimeters < rhs.displayMillimeters
        }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.identifier < rhs.identifier
    }

    private static func displaySize(from name: String) -> Int? {
        guard let range = name.range(
            of: #"\(([0-9]{2})mm\)$"#,
            options: .regularExpression
        ) else { return nil }
        let suffix = name[range]
        guard let digits = suffix.split(whereSeparator: { !$0.isNumber }).first else {
            return nil
        }
        return Int(digits)
    }
}
