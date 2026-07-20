import Darwin
import Foundation
import Testing
@testable import CodexAppServerClient

@Suite struct UnixSocketTransportTests {
    @Test func pendingFixtureAcceptTeardownCompletesWithoutAClient() async throws {
        let fixture = try UnixWebSocketServerFixture(response: Data())
        fixture.close()
        do {
            _ = try await fixture.result.value
            Issue.record("pending accept unexpectedly accepted a client")
        } catch {
            // Any close/cancel terminal error is acceptable; the regression is
            // that this await returns rather than leaving a detached accept.
        }
    }

    @Test func exchangesOneJSONRPCMessageWithInProcessUnixWebSocketServer() async throws {
        let expectedRequest = Data(#"{"id":1,"method":"thread/list"}"#.utf8)
        let response = Data(#"{"id":1,"result":{"data":[]}}"#.utf8)
        let fixture = try UnixWebSocketServerFixture(response: response)
        defer { fixture.close() }
        let transport = UnixSocketTransport(path: fixture.path)
        var frames = transport.frames().makeAsyncIterator()

        try await transport.connect()
        try await transport.send(expectedRequest)
        let received = try await frames.next()
        await transport.close()
        let serverReceived = try await fixture.result.value

        #expect(serverReceived == expectedRequest)
        #expect(received == response)
        #expect(FileManager.default.fileExists(atPath: fixture.path))
        #expect(fixture.listenerIsOpen)
    }

    @Test func rejectsSocketPathReplacementAfterConnect() async throws {
        let coordinator = SocketReplacementCoordinator()
        let fixture = try UnixSocketReplacementFixture(coordinator: coordinator)
        defer { fixture.close() }
        let validation = OrderedRealSocketValidation(coordinator: coordinator)
        let transport = UnixSocketTransport(
            path: fixture.path,
            validation: validation.validate
        )

        await #expect(throws: UnixSocketTransportError.socketChanged) {
            try await transport.connect()
        }
        let replacement = try await fixture.result.value

        #expect(
            fixture.originalMetadata.device != replacement.device ||
                fixture.originalMetadata.inode != replacement.inode
        )
        #expect(validation.validationCount == 2)
    }

    @Test func expectedSocketIdentityRejectsSameUserReplacementBeforeHandshake() async throws {
        let coordinator = SocketReplacementCoordinator()
        let fixture = try UnixSocketReplacementFixture(coordinator: coordinator)
        defer { fixture.close() }
        let validation = OrderedRealSocketValidation(coordinator: coordinator)
        let transport = UnixSocketTransport(
            path: fixture.path,
            expectedMetadata: fixture.originalMetadata,
            validation: validation.validate,
        )

        await #expect(throws: UnixSocketTransportError.socketChanged) {
            try await transport.connect()
        }
        #expect(validation.validationCount == 2)
    }

    @Test func expectedSocketIdentityRejectsMismatchBeforeConnect() async throws {
        let fixture = try UnixWebSocketServerFixture(response: Data())
        defer { fixture.close() }
        let actual = try UnixSocketValidator.validate(path: fixture.path, expectedUID: getuid())
        let stale = UnixSocketMetadata(
            path: actual.path,
            ownerUID: actual.ownerUID,
            permissions: actual.permissions,
            device: actual.device,
            inode: actual.inode &+ 1,
        )
        let transport = UnixSocketTransport(path: fixture.path, expectedMetadata: stale)

        await #expect(throws: UnixSocketTransportError.socketChanged) {
            try await transport.connect()
        }
    }
}

private final class UnixWebSocketServerFixture: @unchecked Sendable {
    private let listener: UnixListenerFixture
    let path: String
    let result: Task<Data, Error>

    init(response: Data) throws {
        let listener = try UnixListenerFixture(mode: 0o600)
        self.listener = listener
        path = listener.path
        result = Task.detached {
            let client = try acceptCancellable(listener.descriptor)
            guard client >= 0 else { throw POSIXError(.ECONNABORTED) }
            defer { Darwin.close(client) }

            let request = try readUntilHeaderEnd(client)
            let key = try header(named: "Sec-WebSocket-Key", in: request)
            let accept = WebSocketCodec.acceptValue(for: key)
            let responseHeaders = Data((
                "HTTP/1.1 101 Switching Protocols\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
            ).utf8)
            try writeAll(client, responseHeaders)
            let clientFrame = try readOneClientFrame(client)
            try writeAll(client, serverFrame(opcode: 0x1, payload: response))
            return clientFrame
        }
    }

    var listenerIsOpen: Bool { listener.listenerIsOpen }
    func close() {
        result.cancel()
        listener.close()
    }
}

private final class UnixSocketReplacementFixture: @unchecked Sendable {
    private let listener: UnixListenerFixture
    let path: String
    let originalMetadata: UnixSocketMetadata
    let result: Task<UnixSocketMetadata, Error>

    init(coordinator: SocketReplacementCoordinator) throws {
        let listener = try UnixListenerFixture(mode: 0o600)
        self.listener = listener
        path = listener.path
        originalMetadata = try UnixSocketValidator.validate(path: listener.path, expectedUID: getuid())
        result = Task.detached {
            let client = try acceptCancellable(listener.descriptor)
            guard client >= 0 else {
                let error = POSIXError(.ECONNABORTED)
                coordinator.fail(error)
                throw error
            }
            defer { Darwin.close(client) }

            var replacement: Int32 = -1
            do {
                guard Darwin.unlink(listener.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                replacement = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard replacement >= 0 else { throw POSIXError(.ENFILE) }
                defer { Darwin.close(replacement) }

                var address = try makeUnixAddress(path: listener.path)
                let bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(replacement, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard bound == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard chmod(listener.path, 0o600) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard Darwin.listen(replacement, 1) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                let metadata = try UnixSocketValidator.validate(
                    path: listener.path,
                    expectedUID: getuid()
                )
                coordinator.didReplaceSocket(metadata)
                return metadata
            } catch {
                coordinator.fail(error)
                throw error
            }
        }
    }

    func close() {
        result.cancel()
        listener.close()
    }
}

private final class SocketReplacementCoordinator: @unchecked Sendable {
    private enum State {
        case waiting
        case replaced(UnixSocketMetadata)
        case failed(any Error)
    }

    private let condition = NSCondition()
    private var state = State.waiting

    func didReplaceSocket(_ metadata: UnixSocketMetadata) {
        condition.withLock {
            state = .replaced(metadata)
            condition.broadcast()
        }
    }

    func fail(_ error: any Error) {
        condition.withLock {
            state = .failed(error)
            condition.broadcast()
        }
    }

    func waitUntilReplaced(timeout: TimeInterval) throws -> UnixSocketMetadata {
        let deadline = Date().addingTimeInterval(timeout)
        return try condition.withLock {
            while case .waiting = state {
                guard condition.wait(until: deadline) else {
                    throw TestServerError.synchronizationTimeout
                }
            }
            switch state {
            case let .replaced(metadata): return metadata
            case let .failed(error): throw error
            case .waiting: throw TestServerError.synchronizationTimeout
            }
        }
    }
}

private final class OrderedRealSocketValidation: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: SocketReplacementCoordinator
    private var count = 0

    init(coordinator: SocketReplacementCoordinator) {
        self.coordinator = coordinator
    }

    var validationCount: Int { lock.withLock { count } }

    func validate(path: String, expectedUID: uid_t) throws -> UnixSocketMetadata {
        let invocation = lock.withLock {
            count += 1
            return count
        }
        guard invocation <= 2 else { throw TestServerError.unexpectedValidation }
        if invocation == 2 {
            _ = try coordinator.waitUntilReplaced(timeout: 2)
        }
        return try UnixSocketValidator.validate(path: path, expectedUID: expectedUID)
    }
}

private func readUntilHeaderEnd(_ descriptor: Int32) throws -> Data {
    var data = Data()
    while data.range(of: Data("\r\n\r\n".utf8)) == nil {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { throw POSIXError(.ECONNRESET) }
        data.append(contentsOf: bytes.prefix(count))
    }
    return data
}

/// Test-fixture accept must be cancellable: closing a listener descriptor from
/// another thread does not reliably interrupt a blocking Darwin.accept.
private func acceptCancellable(_ descriptor: Int32) throws -> Int32 {
    while true {
        if Task.isCancelled { throw CancellationError() }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let polled = Darwin.poll(&event, 1, 20)
        if polled == 0 { continue }
        if polled < 0 {
            if errno == EINTR { continue }
            if Task.isCancelled { throw CancellationError() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if event.revents & Int16(POLLIN) != 0 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client >= 0 { return client }
            if errno == EINTR || errno == ECONNABORTED { continue }
            if Task.isCancelled { throw CancellationError() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if Task.isCancelled { throw CancellationError() }
        throw POSIXError(.ECONNABORTED)
    }
}

private func header(named name: String, in data: Data) throws -> String {
    guard let text = String(data: data, encoding: .utf8) else { throw TestServerError.invalidHandshake }
    for line in text.components(separatedBy: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].caseInsensitiveCompare(name) == .orderedSame {
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    throw TestServerError.invalidHandshake
}

private func readOneClientFrame(_ descriptor: Int32) throws -> Data {
    var data = Data()
    while true {
        if let decoded = try? decodeCompleteClientFrame(data) { return decoded }
        var byte: UInt8 = 0
        let count = Darwin.read(descriptor, &byte, 1)
        guard count == 1 else { throw POSIXError(.ECONNRESET) }
        data.append(byte)
    }
}

private func decodeCompleteClientFrame(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count >= 2, bytes[1] & 0x80 != 0 else { throw TestServerError.incomplete }
    var index = 2
    var length = Int(bytes[1] & 0x7f)
    if length == 126 {
        guard bytes.count >= 4 else { throw TestServerError.incomplete }
        length = Int(bytes[2]) << 8 | Int(bytes[3]); index = 4
    } else if length == 127 {
        guard bytes.count >= 10 else { throw TestServerError.incomplete }
        length = 0
        for byte in bytes[2..<10] { length = length << 8 | Int(byte) }
        index = 10
    }
    guard bytes.count >= index + 4 + length else { throw TestServerError.incomplete }
    let key = Array(bytes[index..<(index + 4)]); index += 4
    return Data(bytes[index..<(index + length)].enumerated().map { offset, byte in byte ^ key[offset % 4] })
}

private func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            guard count > 0 else { throw POSIXError(.EPIPE) }
            offset += count
        }
    }
}

private enum TestServerError: Error {
    case incomplete
    case invalidHandshake
    case synchronizationTimeout
    case unexpectedValidation
}
