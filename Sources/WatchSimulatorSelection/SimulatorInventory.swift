import Foundation

public struct SimulatorRuntime: Sendable, Equatable {
    public let identifier: String
    public let version: String
    public let platform: String
    public let isAvailable: Bool
}

public struct SimulatorDevice: Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let runtimeIdentifier: String
    public let deviceTypeIdentifier: String
    public let isAvailable: Bool
}

public enum WatchSimulatorSelectionError: String, Error, Equatable, Sendable {
    case invalidSDKVersion = "INVALID_SDK_VERSION"
    case malformedInventory = "MALFORMED_INVENTORY"
    case exactRuntimeUnavailable = "EXACT_RUNTIME_UNAVAILABLE"
    case noAvailableWatch = "NO_AVAILABLE_WATCH"
    case unknownDisplaySize = "UNKNOWN_DISPLAY_SIZE"
    case contradictoryInventory = "CONTRADICTORY_INVENTORY"
}

public enum SimulatorInventory {
    public static func decodeRuntimes(_ data: Data) throws -> [SimulatorRuntime] {
        do {
            return try JSONDecoder().decode(RuntimeEnvelope.self, from: data).runtimes.map {
                SimulatorRuntime(
                    identifier: $0.identifier,
                    version: $0.version,
                    platform: $0.platform,
                    isAvailable: $0.isAvailable
                )
            }
        } catch {
            throw WatchSimulatorSelectionError.malformedInventory
        }
    }

    public static func decodeDevices(_ data: Data) throws -> [SimulatorDevice] {
        do {
            let envelope = try JSONDecoder().decode(DeviceEnvelope.self, from: data)
            return envelope.devices.flatMap { runtimeIdentifier, devices in
                devices.map {
                    SimulatorDevice(
                        name: $0.name,
                        identifier: $0.udid,
                        runtimeIdentifier: runtimeIdentifier,
                        deviceTypeIdentifier: $0.deviceTypeIdentifier,
                        isAvailable: $0.isAvailable
                    )
                }
            }
        } catch {
            throw WatchSimulatorSelectionError.malformedInventory
        }
    }
}

private struct RuntimeEnvelope: Decodable {
    struct Runtime: Decodable {
        let identifier: String
        let version: String
        let platform: String
        let isAvailable: Bool
    }

    let runtimes: [Runtime]
}

private struct DeviceEnvelope: Decodable {
    struct Device: Decodable {
        let name: String
        let udid: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String
    }

    let devices: [String: [Device]]
}
