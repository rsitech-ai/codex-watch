import Foundation

public enum JSONRPCID: Codable, Sendable, Equatable, Hashable {
    case integer(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                .init(codingPath: decoder.codingPath, debugDescription: "A JSON-RPC ID must be an integer or string")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable, Equatable {
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue

    public init(id: JSONRPCID, method: String, params: JSONValue) {
        self.id = id
        self.method = method
        self.params = params
    }

    public init(id: JSONRPCID, method: AppServerMethod) {
        self.init(id: id, method: method.name, params: method.params)
    }
}

public struct JSONRPCResponse: Codable, Sendable, Equatable {
    public let id: JSONRPCID
    public let result: JSONValue

    public init(id: JSONRPCID, result: JSONValue) {
        self.id = id
        self.result = result
    }
}

public struct JSONRPCError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCErrorResponse: Codable, Sendable, Equatable {
    public let id: JSONRPCID
    public let error: JSONRPCError

    public init(id: JSONRPCID, error: JSONRPCError) {
        self.id = id
        self.error = error
    }
}

public struct JSONRPCNotification: Codable, Sendable, Equatable {
    public let method: String
    public let params: JSONValue

    public init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }

    public init(method: AppServerMethod) {
        self.init(method: method.name, params: method.params)
    }
}

public enum JSONRPCMessage: Codable, Sendable, Equatable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(JSONRPCResponse)
    case errorResponse(JSONRPCErrorResponse)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let envelope = try container.decode([String: JSONValue].self)
        let hasID = envelope["id"] != nil
        let hasMethod = envelope["method"] != nil
        let hasResult = envelope["result"] != nil
        let hasError = envelope["error"] != nil

        switch (hasID, hasMethod, hasResult, hasError) {
        case (true, true, false, false):
            self = .request(try JSONRPCRequest(from: decoder))
        case (false, true, false, false):
            self = .notification(try JSONRPCNotification(from: decoder))
        case (true, false, true, false):
            self = .response(try JSONRPCResponse(from: decoder))
        case (true, false, false, true):
            self = .errorResponse(try JSONRPCErrorResponse(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected exactly one JSON-RPC request, notification, response, or error response envelope"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .request(request):
            try request.encode(to: encoder)
        case let .notification(notification):
            try notification.encode(to: encoder)
        case let .response(response):
            try response.encode(to: encoder)
        case let .errorResponse(errorResponse):
            try errorResponse.encode(to: encoder)
        }
    }

    public var methodName: String? {
        switch self {
        case let .request(request):
            request.method
        case let .notification(notification):
            notification.method
        case .response, .errorResponse:
            nil
        }
    }
}
