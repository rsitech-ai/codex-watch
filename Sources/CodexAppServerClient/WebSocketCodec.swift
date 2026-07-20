import Foundation

enum WebSocketCodecError: Error, Equatable {
    case invalidHandshake
    case invalidMaskingKey
    case reservedBits
    case maskedServerFrame
    case unsupportedOpcode(UInt8)
    case protocolViolation
    case messageTooLarge
    case invalidUTF8
}

struct WebSocketReceiveResult: Sendable {
    var messages: [Data] = []
    var outboundFrames: [Data] = []
    var receivedClose = false
}

struct WebSocketCodec {
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let maxMessageBytes: Int
    private let maskingKey: @Sendable () -> [UInt8]
    private var buffer = Data()
    private var fragmentedText = Data()
    private var isFragmentingText = false

    init(
        maxMessageBytes: Int,
        maskingKey: @escaping @Sendable () -> [UInt8] = {
            var generator = SystemRandomNumberGenerator()
            return (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
    ) {
        self.maxMessageBytes = maxMessageBytes
        self.maskingKey = maskingKey
    }

    static func makeUpgradeRequest() -> (data: Data, key: String) {
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let key = nonce.base64EncodedString()
        let request = "GET / HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        return (Data(request.utf8), key)
    }

    @discardableResult
    static func validateUpgrade(response: Data, requestKey: String) throws -> Data {
        guard let text = String(data: response, encoding: .utf8) else {
            throw WebSocketCodecError.invalidHandshake
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first else { throw WebSocketCodecError.invalidHandshake }
        let statusParts = status.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), statusParts[1] == "101" else {
            throw WebSocketCodecError.invalidHandshake
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw WebSocketCodecError.invalidHandshake }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }

        guard headerTokens(headers["upgrade"]).contains("websocket"),
              headerTokens(headers["connection"]).contains("upgrade")
        else { throw WebSocketCodecError.invalidHandshake }

        let expected = acceptValue(for: requestKey)
        guard headers["sec-websocket-accept"] == [expected] else {
            throw WebSocketCodecError.invalidHandshake
        }
        return response
    }

    static func acceptValue(for requestKey: String) -> String {
        Data(sha1(Data((requestKey + guid).utf8))).base64EncodedString()
    }

    mutating func encodeClientText(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessageBytes else { throw WebSocketCodecError.messageTooLarge }
        guard String(data: payload, encoding: .utf8) != nil else { throw WebSocketCodecError.invalidUTF8 }
        return try encodeClientFrame(opcode: 0x1, payload: payload)
    }

    mutating func encodeClientClose() throws -> Data {
        try encodeClientFrame(opcode: 0x8, payload: Data())
    }

    mutating func receiveServerData(_ data: Data) throws -> WebSocketReceiveResult {
        buffer.append(data)
        var result = WebSocketReceiveResult()

        while let frame = try parseFrame() {
            switch frame.opcode {
            case 0x0:
                guard isFragmentingText else { throw WebSocketCodecError.protocolViolation }
                guard fragmentedText.count <= maxMessageBytes - frame.payload.count else {
                    throw WebSocketCodecError.messageTooLarge
                }
                fragmentedText.append(frame.payload)
                if frame.fin {
                    try appendTextMessage(fragmentedText, to: &result)
                    fragmentedText.removeAll(keepingCapacity: true)
                    isFragmentingText = false
                }
            case 0x1:
                guard !isFragmentingText else { throw WebSocketCodecError.protocolViolation }
                if frame.fin {
                    try appendTextMessage(frame.payload, to: &result)
                } else {
                    fragmentedText = frame.payload
                    isFragmentingText = true
                }
            case 0x2:
                throw WebSocketCodecError.unsupportedOpcode(0x2)
            case 0x8:
                guard frame.fin, frame.payload.count != 1 else {
                    throw WebSocketCodecError.protocolViolation
                }
                if frame.payload.count > 2,
                   String(data: frame.payload.dropFirst(2), encoding: .utf8) == nil {
                    throw WebSocketCodecError.invalidUTF8
                }
                result.receivedClose = true
            case 0x9:
                guard frame.fin, frame.payload.count <= 125 else {
                    throw WebSocketCodecError.protocolViolation
                }
                result.outboundFrames.append(try encodeClientFrame(opcode: 0xA, payload: frame.payload))
            case 0xA:
                guard frame.fin, frame.payload.count <= 125 else {
                    throw WebSocketCodecError.protocolViolation
                }
            default:
                throw WebSocketCodecError.unsupportedOpcode(frame.opcode)
            }
        }
        return result
    }

    private mutating func appendTextMessage(_ payload: Data, to result: inout WebSocketReceiveResult) throws {
        guard payload.count <= maxMessageBytes else { throw WebSocketCodecError.messageTooLarge }
        guard String(data: payload, encoding: .utf8) != nil else { throw WebSocketCodecError.invalidUTF8 }
        result.messages.append(payload)
    }

    private mutating func parseFrame() throws -> (fin: Bool, opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.index(after: buffer.startIndex)]
        guard first & 0x70 == 0 else { throw WebSocketCodecError.reservedBits }
        guard second & 0x80 == 0 else { throw WebSocketCodecError.maskedServerFrame }

        var headerBytes = 2
        var payloadLength = UInt64(second & 0x7f)
        if payloadLength == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLength = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            headerBytes = 4
        } else if payloadLength == 127 {
            guard buffer.count >= 10 else { return nil }
            guard buffer[2] & 0x80 == 0 else { throw WebSocketCodecError.protocolViolation }
            payloadLength = 0
            for byte in buffer[2..<10] { payloadLength = payloadLength << 8 | UInt64(byte) }
            headerBytes = 10
        }
        guard payloadLength <= UInt64(maxMessageBytes) else { throw WebSocketCodecError.messageTooLarge }
        guard payloadLength <= UInt64(Int.max), buffer.count >= headerBytes + Int(payloadLength) else {
            return nil
        }
        let opcode = first & 0x0f
        if opcode >= 0x8, payloadLength > 125 { throw WebSocketCodecError.protocolViolation }
        let payload = Data(buffer[headerBytes..<(headerBytes + Int(payloadLength))])
        buffer = Data(buffer.dropFirst(headerBytes + Int(payloadLength)))
        return (first & 0x80 != 0, opcode, payload)
    }

    private mutating func encodeClientFrame(opcode: UInt8, payload: Data) throws -> Data {
        let key = maskingKey()
        guard key.count == 4 else { throw WebSocketCodecError.invalidMaskingKey }
        var frame = Data([0x80 | opcode])
        if payload.count <= 125 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xff))
            }
        }
        frame.append(contentsOf: key)
        for (index, byte) in payload.enumerated() { frame.append(byte ^ key[index % 4]) }
        return frame
    }

    private static func headerTokens(_ values: [String]?) -> Set<String> {
        Set((values ?? []).flatMap { value in
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        })
    }
}

private func sha1(_ data: Data) -> [UInt8] {
    var message = [UInt8](data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var hash: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        var words = [UInt32](repeating: 0, count: 80)
        for index in 0..<16 {
            let start = chunkStart + index * 4
            words[index] = UInt32(message[start]) << 24 | UInt32(message[start + 1]) << 16 |
                UInt32(message[start + 2]) << 8 | UInt32(message[start + 3])
        }
        for index in 16..<80 {
            words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16])
                .rotatedLeft(1)
        }
        var (a, b, c, d, e) = (hash[0], hash[1], hash[2], hash[3], hash[4])
        for index in 0..<80 {
            let f: UInt32
            let k: UInt32
            switch index {
            case 0..<20: (f, k) = ((b & c) | ((~b) & d), 0x5A827999)
            case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
            case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
            default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
            }
            let next = a.rotatedLeft(5) &+ f &+ e &+ k &+ words[index]
            (a, b, c, d, e) = (next, a, b.rotatedLeft(30), c, d)
        }
        hash = [hash[0] &+ a, hash[1] &+ b, hash[2] &+ c, hash[3] &+ d, hash[4] &+ e]
    }
    return hash.flatMap { word in
        stride(from: 24, through: 0, by: -8).map { UInt8((word >> UInt32($0)) & 0xff) }
    }
}

private extension UInt32 {
    func rotatedLeft(_ count: UInt32) -> UInt32 { self << count | self >> (32 - count) }
}
