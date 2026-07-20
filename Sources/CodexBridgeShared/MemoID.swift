import Foundation

public enum MemoIDError: Error, Equatable, Sendable {
    case invalidValue
}

public struct MemoID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw MemoIDError.invalidValue
        }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Memo ID must be a UUID string"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
