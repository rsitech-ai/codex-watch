@testable import CodexBridgeService
import Foundation
import Testing

@Test func parserReturnsAuthenticatedHeadWithoutBufferingDeclaredBody() throws {
    var parser = try HTTPRequestHeadParser(maxHeaderBytes: 16 * 1_024)
    let bytes = Data(
        "POST /v1/memos/id HTTP/1.1\r\nHost: mac\r\nContent-Length: 33554432\r\n\r\nabc".utf8
    )

    let result = try parser.append(bytes)
    let parsed = try #require(result)

    #expect(parsed.head.method == "POST")
    #expect(parsed.head.path == "/v1/memos/id")
    #expect(parsed.head.headers["host"] == "mac")
    #expect(parsed.head.contentLength == 32 * 1_024 * 1_024)
    #expect(parsed.initialBodyBytes == Data("abc".utf8))
}

@Test func parserReturnsOnlyRemainderFromCompletingCallback() throws {
    var parser = try HTTPRequestHeadParser(maxHeaderBytes: 256)

    #expect(try parser.append(Data("POST / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    let result = try parser.append(Data("Content-Length: 5\r\n\r\nabc".utf8))
    let parsed = try #require(result)

    #expect(parsed.head.contentLength == 5)
    #expect(parsed.initialBodyBytes == Data("abc".utf8))
    #expect(throws: HTTPParserError.alreadyComplete) {
        _ = try parser.append(Data("de".utf8))
    }
}

@Test func parserAcceptsHeaderAtExactBoundaryAndRejectsOneByteBeyondIt() throws {
    let maximum = 16 * 1_024
    let prefix = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nX-Fill: "
    let exactHead = prefix + String(repeating: "a", count: maximum - prefix.utf8.count)

    var exactParser = try HTTPRequestHeadParser(maxHeaderBytes: maximum)
    let result = try exactParser.append(Data((exactHead + "\r\n\r\n").utf8))
    let parsed = try #require(result)
    #expect(parsed.head.contentLength == 0)

    var oversizedParser = try HTTPRequestHeadParser(maxHeaderBytes: maximum)
    #expect(throws: HTTPParserError.headersTooLarge) {
        _ = try oversizedParser.append(Data((exactHead + "a\r\n\r\n").utf8))
    }
}

@Test func parserRejectsHeaderGrowthPastBoundaryBeforeTerminator() throws {
    var parser = try HTTPRequestHeadParser(maxHeaderBytes: 32)
    #expect(throws: HTTPParserError.headersTooLarge) {
        _ = try parser.append(Data("POST / HTTP/1.1\r\nX-Fill: 12345678901234567890".utf8))
    }
}

@Test(arguments: [
    ("POST / HTTP/1.1\nHost: x\nContent-Length: 0\n\n", HTTPParserError.malformedRequest),
    ("POST / HTTP/1.0\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .unsupportedVersion),
    ("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", .duplicateHeader),
    ("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", .unsupportedTransferEncoding),
    ("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\n", .missingHost),
    ("POST / HTTP/1.1\r\nHost: x\r\n\r\n", .missingContentLength),
    ("POST  / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .malformedRequest),
    ("POST relative HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .malformedRequest),
])
func parserRejectsAmbiguousOrUnsupportedHTTPGrammar(
    _ raw: String,
    _ expectedError: HTTPParserError
) throws {
    var parser = try HTTPRequestHeadParser(maxHeaderBytes: 512)
    #expect(throws: expectedError) {
        _ = try parser.append(Data(raw.utf8))
    }
}

@Test func parserRejectsInvalidConfiguration() {
    #expect(throws: HTTPParserError.invalidConfiguration) {
        _ = try HTTPRequestHeadParser(maxHeaderBytes: 0)
    }
    #expect(throws: HTTPParserError.invalidConfiguration) {
        _ = try HTTPRequestHeadParser(maxHeaderBytes: 16 * 1_024 + 1)
    }
    #expect(throws: HTTPParserError.invalidConfiguration) {
        _ = try HTTPRequestHeadParser(maxHeaderBytes: Int.max)
    }

    #expect(throws: Never.self) {
        _ = try HTTPRequestHeadParser(maxHeaderBytes: 1)
    }
}

@Test(arguments: [1, 2, 3])
func parserRecognizesHeaderTerminatorSplitAtEveryInternalBoundary(_ split: Int) throws {
    let head = Data("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 4".utf8)
    let terminator = Data("\r\n\r\n".utf8)
    var parser = try HTTPRequestHeadParser(maxHeaderBytes: 256)

    #expect(try parser.append(head + terminator.prefix(split)) == nil)
    let result = try parser.append(terminator.dropFirst(split) + Data("body".utf8))
    let parsed = try #require(result)

    #expect(parsed.head.contentLength == 4)
    #expect(parsed.initialBodyBytes == Data("body".utf8))
}
