import Foundation

public enum ThreadStatus: Codable, Sendable, Equatable {
    case notLoaded
    case idle
    case active
    case systemError
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    init(rawValue: String) {
        switch rawValue {
        case "notLoaded": self = .notLoaded
        case "idle": self = .idle
        case "active": self = .active
        case "systemError": self = .systemError
        default: self = .unknown(rawValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .notLoaded: "notLoaded"
        case .idle: "idle"
        case .active: "active"
        case .systemError: "systemError"
        case let .unknown(value): value
        }
    }
}

public enum ThreadSourceKind: Codable, Sendable, Equatable {
    case cli
    case vscode
    case appServer
    case subAgent
    case exec
    case unknown(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    init(rawValue: String) {
        switch rawValue {
        case "cli": self = .cli
        case "vscode": self = .vscode
        case "appServer": self = .appServer
        case "subAgent": self = .subAgent
        case "exec": self = .exec
        default: self = .unknown(rawValue)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .cli: "cli"
        case .vscode: "vscode"
        case .appServer: "appServer"
        case .subAgent: "subAgent"
        case .exec: "exec"
        case let .unknown(value): value
        }
    }
}

public struct ThreadProjection: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let cwd: String?
    public let status: ThreadStatus?
    public let sourceKind: ThreadSourceKind?
    public let additionalFields: [String: JSONValue]
    private let statusWireValue: JSONValue?

    public init(
        id: String,
        name: String? = nil,
        cwd: String? = nil,
        status: ThreadStatus? = nil,
        sourceKind: ThreadSourceKind? = nil,
        additionalFields: [String: JSONValue] = [:],
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.status = status
        self.sourceKind = sourceKind
        self.additionalFields = additionalFields
        statusWireValue = status.map { .string($0.rawValue) }
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            throw DecodingError.typeMismatch(
                ThreadProjection.self,
                .init(codingPath: decoder.codingPath, debugDescription: "A thread projection must be a JSON object"),
            )
        }
        guard case let .string(id)? = fields["id"] else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "A thread projection requires a string id"),
            )
        }

        self.id = id
        name = try Self.optionalString("name", in: fields, decoder: decoder)
        cwd = try Self.optionalString("cwd", in: fields, decoder: decoder)
        status = Self.threadStatus(from: fields["status"])
        sourceKind = try Self.optionalString("sourceKind", in: fields, decoder: decoder).map(ThreadSourceKind.init(rawValue:))
        additionalFields = fields.filter { !CodingKeys.knownNames.contains($0.key) }
        statusWireValue = fields["status"]
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = additionalFields
        fields["id"] = .string(id)
        if let name { fields["name"] = .string(name) }
        if let cwd { fields["cwd"] = .string(cwd) }
        if let statusWireValue {
            fields["status"] = statusWireValue
        } else if let status {
            fields["status"] = .string(status.rawValue)
        }
        if let sourceKind { fields["sourceKind"] = .string(sourceKind.rawValue) }
        try JSONValue.object(fields).encode(to: encoder)
    }

    private static func optionalString(
        _ key: String,
        in fields: [String: JSONValue],
        decoder: any Decoder,
    ) throws -> String? {
        switch fields[key] {
        case nil, .null?:
            nil
        case let .string(value)?:
            value
        default:
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Thread field \(key) must be a string or null"),
            )
        }
    }

    private static func threadStatus(from value: JSONValue?) -> ThreadStatus? {
        switch value {
        case let .string(rawValue)?:
            ThreadStatus(rawValue: rawValue)
        case let .object(fields)?:
            if case let .string(rawValue)? = fields["type"] {
                ThreadStatus(rawValue: rawValue)
            } else {
                nil
            }
        case nil, .null?:
            nil
        default:
            nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case cwd
        case status
        case sourceKind

        static let knownNames = Set([id.rawValue, name.rawValue, cwd.rawValue, status.rawValue, sourceKind.rawValue])
    }
}
