import Foundation

public struct DeviceInventory: Sendable, Equatable {
    public enum LockState: Sendable, Equatable {
        case locked
        case unlocked
        case unobserved
        case unknown
    }

    public struct Device: Sendable, Equatable {
        public let identifier: String
        public let name: String
        public let model: String
        public let osVersion: String
        public let platform: String
        public let reality: String
        public let deviceType: String
        public let pairingState: String?
        public let tunnelState: String?
        public let transportType: String?
        public let developerModeStatus: String?
        public let bootState: String?
        public let ddiServicesAvailable: Bool?
        public let lockState: LockState
    }

    public enum DecodingFailure: Error, Equatable, Sendable {
        case malformed
        case unsuccessfulOutcome
    }

    public let devices: [Device]

    public static func decode(_ data: Data) throws -> DeviceInventory {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw DecodingFailure.malformed
        }
        guard envelope.info.outcome == "success" else {
            throw DecodingFailure.unsuccessfulOutcome
        }
        return DeviceInventory(devices: envelope.result.devices.map(\.device))
    }
}

private struct Envelope: Decodable {
    struct Info: Decodable {
        let outcome: String
    }

    struct Result: Decodable {
        let devices: [DecodedDevice]
    }

    let info: Info
    let result: Result
}

private struct DecodedDevice: Decodable {
    struct DeviceProperties: Decodable {
        let bootState: String?
        let ddiServicesAvailable: Bool?
        let developerModeStatus: String?
        let isLocked: DecodedLockState?
        let name: String
        let osVersionNumber: String
    }

    struct HardwareProperties: Decodable {
        let deviceType: String
        let marketingName: String
        let platform: String
        let reality: String
    }

    struct ConnectionProperties: Decodable {
        let pairingState: String?
        let transportType: String?
        let tunnelState: String?
    }

    let identifier: String
    let deviceProperties: DeviceProperties
    let hardwareProperties: HardwareProperties
    let connectionProperties: ConnectionProperties

    var device: DeviceInventory.Device {
        DeviceInventory.Device(
            identifier: identifier,
            name: deviceProperties.name,
            model: hardwareProperties.marketingName,
            osVersion: deviceProperties.osVersionNumber,
            platform: hardwareProperties.platform,
            reality: hardwareProperties.reality,
            deviceType: hardwareProperties.deviceType,
            pairingState: connectionProperties.pairingState,
            tunnelState: connectionProperties.tunnelState,
            transportType: connectionProperties.transportType,
            developerModeStatus: deviceProperties.developerModeStatus,
            bootState: deviceProperties.bootState,
            ddiServicesAvailable: deviceProperties.ddiServicesAvailable,
            lockState: deviceProperties.isLocked?.value ?? .unobserved
        )
    }
}

private struct DecodedLockState: Decodable {
    let value: DeviceInventory.LockState

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let isLocked = try? container.decode(Bool.self) {
            value = isLocked ? .locked : .unlocked
        } else {
            value = .unknown
        }
    }
}
