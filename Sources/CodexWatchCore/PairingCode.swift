import Foundation

public enum PairingCodeError: Error, Equatable, Sendable {
    case invalidCode
}

public struct PairingCode: RawRepresentable, Equatable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 6,
              rawValue.utf8.allSatisfy({ (48 ... 57).contains($0) })
        else { throw PairingCodeError.invalidCode }
        self.rawValue = rawValue
    }

    public init?(rawValue: String) {
        try? self.init(rawValue)
    }

    public static func sanitizeInput(_ input: String) -> String {
        let bytes = input.utf8.lazy.filter { (48 ... 57).contains($0) }.prefix(6)
        return String(decoding: bytes, as: UTF8.self)
    }
}
