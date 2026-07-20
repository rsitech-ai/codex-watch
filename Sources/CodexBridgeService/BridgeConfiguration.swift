import CodexBridgeShared
import CryptoKit
import Foundation

public enum BridgeConfigurationError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidClockSkew
}

public struct BridgeConfiguration: Equatable, Sendable {
    public static let defaultMaximumHeaderBytes = 16 * 1_024
    public static let defaultMaximumBodyBytes = 32 * 1_024 * 1_024
    public static let defaultHeaderTimeout: TimeInterval = 10
    public static let defaultIdleBodyTimeout: TimeInterval = 30
    public static let defaultTotalRequestTimeout: TimeInterval = 5 * 60
    public static let defaultMaximumConnections = 8
    public static let defaultMaximumUploads = 2

    public let maximumHeaderBytes: Int
    public let maximumBodyBytes: Int
    public let allowedClockSkew: TimeInterval
    public let headerTimeout: TimeInterval
    public let idleBodyTimeout: TimeInterval
    public let totalRequestTimeout: TimeInterval
    public let maximumConnections: Int
    public let maximumUploads: Int

    public init(
        maximumHeaderBytes: Int = Self.defaultMaximumHeaderBytes,
        maximumBodyBytes: Int = Self.defaultMaximumBodyBytes,
        allowedClockSkew: TimeInterval = 5 * 60,
        headerTimeout: TimeInterval = Self.defaultHeaderTimeout,
        idleBodyTimeout: TimeInterval = Self.defaultIdleBodyTimeout,
        totalRequestTimeout: TimeInterval = Self.defaultTotalRequestTimeout,
        maximumConnections: Int = Self.defaultMaximumConnections,
        maximumUploads: Int = Self.defaultMaximumUploads
    ) throws {
        guard maximumHeaderBytes > 0, maximumBodyBytes > 0,
              maximumConnections > 0, maximumUploads > 0
        else {
            throw BridgeConfigurationError.invalidLimit
        }
        guard allowedClockSkew.isFinite, allowedClockSkew > 0 else {
            throw BridgeConfigurationError.invalidClockSkew
        }
        guard headerTimeout.isFinite, headerTimeout > 0,
              idleBodyTimeout.isFinite, idleBodyTimeout > 0,
              totalRequestTimeout.isFinite, totalRequestTimeout > 0
        else { throw BridgeConfigurationError.invalidLimit }
        self.maximumHeaderBytes = maximumHeaderBytes
        self.maximumBodyBytes = maximumBodyBytes
        self.allowedClockSkew = allowedClockSkew
        self.headerTimeout = headerTimeout
        self.idleBodyTimeout = idleBodyTimeout
        self.totalRequestTimeout = totalRequestTimeout
        self.maximumConnections = maximumConnections
        self.maximumUploads = maximumUploads
    }
}

public enum AudioDigest {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidHex(_ value: String) -> Bool {
        SHA256Hex.isValid(value)
    }
}
