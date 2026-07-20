import Foundation
import Testing
@testable import CodexAppServerClient

@Suite struct WebSocketCodecTests {
    @Test func clientTextFramesAreMaskedAndRoundTrip() throws {
        var codec = WebSocketCodec(maxMessageBytes: 1_048_576, maskingKey: { [1, 2, 3, 4] })
        let encoded = try codec.encodeClientText(Data("hello".utf8))

        #expect(encoded[1] & 0x80 == 0x80)
        let decoded = try decodeClientFrame(encoded)
        #expect(decoded.opcode == 0x1)
        #expect(decoded.payload == Data("hello".utf8))
    }

    @Test func encodesClientLengthsUsingSevenSixteenAndSixtyFourBitForms() throws {
        var codec = WebSocketCodec(maxMessageBytes: 100_000, maskingKey: { [1, 2, 3, 4] })
        let small = try codec.encodeClientText(Data(repeating: 0x61, count: 125))
        let medium = try codec.encodeClientText(Data(repeating: 0x61, count: 126))
        let large = try codec.encodeClientText(Data(repeating: 0x61, count: 65_536))

        #expect(small[1] & 0x7f == 125)
        #expect(medium[1] & 0x7f == 126)
        #expect(large[1] & 0x7f == 127)
        #expect(try decodeClientFrame(small).payload.count == 125)
        #expect(try decodeClientFrame(medium).payload.count == 126)
        #expect(try decodeClientFrame(large).payload.count == 65_536)
    }

    @Test func validatesPublishedUpgradeResponseVector() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let response = Data((
            "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: keep-alive, Upgrade\r\n" +
                "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        ).utf8)

        #expect(try WebSocketCodec.validateUpgrade(response: response, requestKey: key).isEmpty == false)
    }

    @Test(arguments: [
        Data("HTTP/1.1 200 OK\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8),
        Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8),
        Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: close\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8),
        Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: wrong\r\n\r\n".utf8),
    ])
    func rejectsInvalidUpgradeResponses(_ response: Data) {
        #expect(throws: WebSocketCodecError.self) {
            _ = try WebSocketCodec.validateUpgrade(
                response: response,
                requestKey: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        }
    }

    @Test func upgradeRequestUsesRootLocalhostAndSixteenByteNonce() throws {
        let request = WebSocketCodec.makeUpgradeRequest()
        let text = try #require(String(data: request.data, encoding: .utf8))

        #expect(text.hasPrefix("GET / HTTP/1.1\r\n"))
        #expect(text.contains("Host: localhost\r\n"))
        #expect(text.contains("Upgrade: websocket\r\n"))
        #expect(text.contains("Connection: Upgrade\r\n"))
        #expect(Data(base64Encoded: request.key)?.count == 16)
    }

    @Test func incrementallyDecodesUnmaskedServerTextAcrossAllLengthForms() throws {
        var codec = WebSocketCodec(maxMessageBytes: 100_000)
        let frames = [
            serverFrame(opcode: 0x1, payload: Data(repeating: 0x61, count: 5)),
            serverFrame(opcode: 0x1, payload: Data(repeating: 0x62, count: 126)),
            serverFrame(opcode: 0x1, payload: Data(repeating: 0x63, count: 65_536)),
        ]
        let wire = frames.reduce(into: Data(), +=)
        var messages: [Data] = []

        for byte in wire {
            messages.append(contentsOf: try codec.receiveServerData(Data([byte])).messages)
        }

        #expect(messages.map(\.count) == [5, 126, 65_536])
    }

    @Test func assemblesContinuationAndEmitsExactlyOneMessage() throws {
        var codec = WebSocketCodec(maxMessageBytes: 1_048_576)
        let first = serverFrame(fin: false, opcode: 0x1, payload: Data("hel".utf8))
        let second = serverFrame(opcode: 0x0, payload: Data("lo".utf8))

        let firstResult = try codec.receiveServerData(first)
        let secondResult = try codec.receiveServerData(second)

        #expect(firstResult.messages.isEmpty)
        #expect(secondResult.messages == [Data("hello".utf8)])
    }

    @Test func pingProducesMaskedPongAndCloseIsReported() throws {
        var codec = WebSocketCodec(maxMessageBytes: 1_048_576, maskingKey: { [5, 6, 7, 8] })
        let pingResult = try codec.receiveServerData(
            serverFrame(opcode: 0x9, payload: Data("hi".utf8))
        )
        let closeResult = try codec.receiveServerData(serverFrame(opcode: 0x8))

        let pong = try #require(pingResult.outboundFrames.first)
        #expect(pong[1] & 0x80 == 0x80)
        #expect(try decodeClientFrame(pong).opcode == 0xA)
        #expect(try decodeClientFrame(pong).payload == Data("hi".utf8))
        #expect(closeResult.receivedClose)
    }

    @Test(arguments: [
        serverFrame(rsv: 0x40, opcode: 0x1),
        serverFrame(opcode: 0x2),
        serverFrame(opcode: 0x3),
        serverFrame(opcode: 0x1, payload: Data(), masked: true),
    ])
    func rejectsReservedBinaryInvalidAndMaskedServerFrames(_ frame: Data) {
        var codec = WebSocketCodec(maxMessageBytes: 1_048_576)
        #expect(throws: WebSocketCodecError.self) {
            _ = try codec.receiveServerData(frame)
        }
    }

    @Test func rejectsInvalidUTF8AndOversizedMessages() {
        var invalidUTF8Codec = WebSocketCodec(maxMessageBytes: 1024)
        #expect(throws: WebSocketCodecError.invalidUTF8) {
            _ = try invalidUTF8Codec.receiveServerData(
                serverFrame(opcode: 0x1, payload: Data([0xC3, 0x28]))
            )
        }

        var oversizedCodec = WebSocketCodec(maxMessageBytes: 4)
        #expect(throws: WebSocketCodecError.messageTooLarge) {
            _ = try oversizedCodec.receiveServerData(
                serverFrame(opcode: 0x1, payload: Data("hello".utf8))
            )
        }
    }
}

private struct DecodedClientFrame {
    let opcode: UInt8
    let payload: Data
}

private func decodeClientFrame(_ data: Data) throws -> DecodedClientFrame {
    let bytes = [UInt8](data)
    guard bytes.count >= 6, bytes[1] & 0x80 != 0 else { throw TestFrameError.invalid }
    var index = 2
    var length = Int(bytes[1] & 0x7f)
    if length == 126 {
        guard bytes.count >= index + 2 else { throw TestFrameError.invalid }
        length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
    } else if length == 127 {
        guard bytes.count >= index + 8 else { throw TestFrameError.invalid }
        length = 0
        for byte in bytes[index..<(index + 8)] { length = length << 8 | Int(byte) }
        index += 8
    }
    guard bytes.count >= index + 4 + length else { throw TestFrameError.invalid }
    let key = Array(bytes[index..<(index + 4)])
    index += 4
    let payload = Data(bytes[index..<(index + length)].enumerated().map { offset, byte in
        byte ^ key[offset % 4]
    })
    return DecodedClientFrame(opcode: bytes[0] & 0x0f, payload: payload)
}

func serverFrame(
    fin: Bool = true,
    rsv: UInt8 = 0,
    opcode: UInt8,
    payload: Data = Data(),
    masked: Bool = false
) -> Data {
    var frame = Data([(fin ? 0x80 : 0) | rsv | opcode])
    let maskBit: UInt8 = masked ? 0x80 : 0
    if payload.count <= 125 {
        frame.append(maskBit | UInt8(payload.count))
    } else if payload.count <= 65_535 {
        frame.append(maskBit | 126)
        frame.append(UInt8((payload.count >> 8) & 0xff))
        frame.append(UInt8(payload.count & 0xff))
    } else {
        frame.append(maskBit | 127)
        for shift in stride(from: 56, through: 0, by: -8) {
            frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xff))
        }
    }
    if masked {
        frame.append(contentsOf: [1, 2, 3, 4])
        for (index, byte) in payload.enumerated() { frame.append(byte ^ UInt8((index % 4) + 1)) }
    } else {
        frame.append(payload)
    }
    return frame
}

private enum TestFrameError: Error { case invalid }
