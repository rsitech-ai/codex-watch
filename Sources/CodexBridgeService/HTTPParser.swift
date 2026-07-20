import Foundation

public enum HTTPParserError: Error, Equatable, Sendable {
    case invalidConfiguration
    case headersTooLarge
    case bodyTooLarge
    case malformedRequest
    case unsupportedVersion
    case missingHost
    case missingContentLength
    case duplicateHeader
    case unsupportedTransferEncoding
    case trailingBytes
    case alreadyComplete
}

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPRequestHead: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let contentLength: Int

    public init(method: String, path: String, headers: [String: String], contentLength: Int) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
    }
}

public struct ParsedRequestHead: Equatable, Sendable {
    public let head: HTTPRequestHead
    public let initialBodyBytes: Data

    public init(head: HTTPRequestHead, initialBodyBytes: Data) {
        self.head = head
        self.initialBodyBytes = initialBodyBytes
    }
}

public struct HTTPRequestHeadParser: Sendable {
    private static let headerTerminator = Data([13, 10, 13, 10])
    private static let absoluteMaximumHeaderBytes = 16 * 1_024

    private let maxHeaderBytes: Int
    private var buffer = Data()
    private var complete = false

    public init(maxHeaderBytes: Int) throws {
        guard maxHeaderBytes > 0,
              maxHeaderBytes <= Self.absoluteMaximumHeaderBytes
        else {
            throw HTTPParserError.invalidConfiguration
        }
        self.maxHeaderBytes = maxHeaderBytes
    }

    public mutating func append(_ bytes: Data) throws -> ParsedRequestHead? {
        guard !complete else { throw HTTPParserError.alreadyComplete }

        let previousCount = buffer.count
        let maximumSearchBytes = maxHeaderBytes + Self.headerTerminator.count
        let bytesToSearch = min(bytes.count, maximumSearchBytes - previousCount)
        buffer.append(bytes.prefix(bytesToSearch))

        guard let terminator = buffer.range(of: Self.headerTerminator) else {
            if Self.containsBareLineFeed(buffer) {
                throw HTTPParserError.malformedRequest
            }
            guard bytesToSearch == bytes.count,
                  buffer.count <= maxHeaderBytes + Self.headerTerminator.count - 1
            else {
                throw HTTPParserError.headersTooLarge
            }
            return nil
        }
        guard terminator.lowerBound <= maxHeaderBytes else {
            throw HTTPParserError.headersTooLarge
        }

        let parsed = try HTTPParser.parseHeaders(Data(buffer[..<terminator.lowerBound]))
        let bytesConsumedFromCurrentAppend = terminator.upperBound - previousCount
        guard bytesConsumedFromCurrentAppend >= 0,
              bytesConsumedFromCurrentAppend <= bytes.count
        else {
            throw HTTPParserError.malformedRequest
        }

        complete = true
        return ParsedRequestHead(
            head: HTTPRequestHead(
                method: parsed.method,
                path: parsed.path,
                headers: parsed.headers,
                contentLength: parsed.contentLength
            ),
            initialBodyBytes: Data(bytes.dropFirst(bytesConsumedFromCurrentAppend))
        )
    }

    private static func containsBareLineFeed(_ data: Data) -> Bool {
        for index in data.indices where data[index] == 10 {
            if index == data.startIndex || data[data.index(before: index)] != 13 {
                return true
            }
        }
        return false
    }
}

public struct HTTPParser: Sendable {
    private static let headerTerminator = Data([13, 10, 13, 10])

    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int
    private var buffer = Data()
    private var expectedBodyBytes: Int?
    private var bodyOffset: Int?
    private var parsedMethod: String?
    private var parsedPath: String?
    private var parsedHeaders: [String: String]?
    private var complete = false

    public init(maxHeaderBytes: Int, maxBodyBytes: Int) throws {
        guard maxHeaderBytes > 0,
              maxBodyBytes >= 0,
              maxHeaderBytes <= Int.max - Self.headerTerminator.count - maxBodyBytes
        else {
            throw HTTPParserError.invalidConfiguration
        }
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func append(_ data: Data) throws -> HTTPRequest? {
        guard !complete else { throw HTTPParserError.alreadyComplete }
        let maximumBufferedBytes = maxHeaderBytes + Self.headerTerminator.count + maxBodyBytes
        guard data.count <= maximumBufferedBytes - buffer.count else {
            throw expectedBodyBytes == nil
                ? HTTPParserError.headersTooLarge
                : HTTPParserError.bodyTooLarge
        }
        buffer.append(data)

        if expectedBodyBytes == nil {
            guard let terminator = buffer.range(of: Self.headerTerminator) else {
                if Self.containsBareLineFeed(buffer) {
                    throw HTTPParserError.malformedRequest
                }
                guard buffer.count <= maxHeaderBytes else { throw HTTPParserError.headersTooLarge }
                return nil
            }
            guard terminator.lowerBound <= maxHeaderBytes else { throw HTTPParserError.headersTooLarge }
            let parsed = try Self.parseHeaders(Data(buffer[..<terminator.lowerBound]))
            guard parsed.contentLength <= maxBodyBytes else { throw HTTPParserError.bodyTooLarge }
            parsedMethod = parsed.method
            parsedPath = parsed.path
            parsedHeaders = parsed.headers
            expectedBodyBytes = parsed.contentLength
            bodyOffset = terminator.upperBound
        }

        guard let expectedBodyBytes, let bodyOffset else { throw HTTPParserError.malformedRequest }
        let expectedTotal = bodyOffset + expectedBodyBytes
        guard buffer.count <= expectedTotal else { throw HTTPParserError.trailingBytes }
        guard buffer.count == expectedTotal else { return nil }
        guard let parsedMethod, let parsedPath, let parsedHeaders else {
            throw HTTPParserError.malformedRequest
        }
        complete = true
        return HTTPRequest(
            method: parsedMethod,
            path: parsedPath,
            headers: parsedHeaders,
            body: Data(buffer[bodyOffset..<expectedTotal])
        )
    }

    private static func containsBareLineFeed(_ data: Data) -> Bool {
        for index in data.indices where data[index] == 10 {
            if index == data.startIndex || data[data.index(before: index)] != 13 {
                return true
            }
        }
        return false
    }

    fileprivate static func parseHeaders(_ data: Data) throws -> (
        method: String,
        path: String,
        headers: [String: String],
        contentLength: Int
    ) {
        guard !data.isEmpty,
              data.allSatisfy({ $0 == 13 || $0 == 10 || ($0 >= 0x20 && $0 <= 0x7E) }),
              let text = String(data: data, encoding: .ascii)
        else {
            throw HTTPParserError.malformedRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HTTPParserError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              !requestParts.contains(where: \.isEmpty)
        else {
            throw HTTPParserError.malformedRequest
        }
        let method = String(requestParts[0])
        let path = String(requestParts[1])
        let version = String(requestParts[2])
        guard version == "HTTP/1.1" else { throw HTTPParserError.unsupportedVersion }
        guard method.utf8.allSatisfy({ (65 ... 90).contains($0) }),
              path.first == "/",
              path.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
        else {
            throw HTTPParserError.malformedRequest
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  line.first != " ", line.first != "\t",
                  let colon = line.firstIndex(of: ":")
            else {
                throw HTTPParserError.malformedRequest
            }
            let rawName = line[..<colon]
            let rawValue = line[line.index(after: colon)...]
            guard !rawName.isEmpty,
                  rawName.utf8.allSatisfy({ byte in
                      (48 ... 57).contains(byte)
                          || (65 ... 90).contains(byte)
                          || (97 ... 122).contains(byte)
                          || byte == 45
                  }),
                  rawValue.utf8.allSatisfy({ $0 == 9 || ($0 >= 0x20 && $0 <= 0x7E) })
            else {
                throw HTTPParserError.malformedRequest
            }
            let name = rawName.lowercased()
            guard headers[name] == nil else { throw HTTPParserError.duplicateHeader }
            headers[name] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let host = headers["host"], !host.isEmpty else { throw HTTPParserError.missingHost }
        guard headers["transfer-encoding"] == nil else {
            throw HTTPParserError.unsupportedTransferEncoding
        }
        guard let rawLength = headers["content-length"],
              !rawLength.isEmpty,
              rawLength.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let contentLength = Int(rawLength)
        else {
            throw HTTPParserError.missingContentLength
        }
        return (method, path, headers, contentLength)
    }
}
