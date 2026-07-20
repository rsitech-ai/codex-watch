import Darwin
import Foundation

public enum UnixSocketTransportError: Error, Equatable {
    case alreadyConnected
    case notConnected
    case pathTooLong
    case socketChanged
    case handshakeTooLarge
    case systemCall(operation: String, code: Int32)
}

public actor UnixSocketTransport: AppServerTransport {
    private let path: String
    private let expectedUID: uid_t
    private let expectedMetadata: UnixSocketMetadata?
    private let maxMessageBytes: Int
    private let validation: @Sendable (String, uid_t) throws -> UnixSocketMetadata
    private let frameEmitter: UnixSocketFrameEmitter
    private var outboundCodec: WebSocketCodec
    private var descriptor: Int32?
    private var readTask: Task<Void, Never>?
    private var didConnect = false

    public nonisolated let frameStream: AsyncThrowingStream<Data, Error>

    public init(
        path: String,
        expectedUID: uid_t = getuid(),
        expectedMetadata: UnixSocketMetadata? = nil,
        maxMessageBytes: Int = 1_048_576
    ) {
        self.path = path
        self.expectedUID = expectedUID
        self.expectedMetadata = expectedMetadata
        self.maxMessageBytes = maxMessageBytes
        validation = UnixSocketValidator.validate
        outboundCodec = WebSocketCodec(maxMessageBytes: maxMessageBytes)
        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        frameStream = frames.stream
        frameEmitter = UnixSocketFrameEmitter(continuation: frames.continuation)
    }

    init(
        path: String,
        expectedUID: uid_t = getuid(),
        expectedMetadata: UnixSocketMetadata? = nil,
        maxMessageBytes: Int = 1_048_576,
        validation: @escaping @Sendable (String, uid_t) throws -> UnixSocketMetadata
    ) {
        self.path = path
        self.expectedUID = expectedUID
        self.expectedMetadata = expectedMetadata
        self.maxMessageBytes = maxMessageBytes
        self.validation = validation
        outboundCodec = WebSocketCodec(maxMessageBytes: maxMessageBytes)
        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        frameStream = frames.stream
        frameEmitter = UnixSocketFrameEmitter(continuation: frames.continuation)
    }

    public func connect() async throws {
        guard !didConnect else { throw UnixSocketTransportError.alreadyConnected }
        didConnect = true
        let before = try validation(path, expectedUID)
        if let expectedMetadata, !Self.sameIdentity(before, expectedMetadata) {
            throw UnixSocketTransportError.socketChanged
        }

        let ownedDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard ownedDescriptor >= 0 else {
            throw UnixSocketTransportError.systemCall(operation: "socket", code: errno)
        }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(
                ownedDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw UnixSocketTransportError.systemCall(operation: "setsockopt", code: errno)
            }
            var address = try Self.makeAddress(path: path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(ownedDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else {
                throw UnixSocketTransportError.systemCall(operation: "connect", code: errno)
            }

            let after = try validation(path, expectedUID)
            guard Self.sameIdentity(before, after),
                  expectedMetadata.map({ Self.sameIdentity(after, $0) }) ?? true
            else {
                throw UnixSocketTransportError.socketChanged
            }

            let upgrade = WebSocketCodec.makeUpgradeRequest()
            try Self.writeAll(descriptor: ownedDescriptor, data: upgrade.data)
            let handshake = try Self.readHandshake(descriptor: ownedDescriptor)
            try WebSocketCodec.validateUpgrade(response: handshake.headers, requestKey: upgrade.key)

            descriptor = ownedDescriptor
            startReadLoop(descriptor: ownedDescriptor, initialData: handshake.remainder)
        } catch {
            Darwin.shutdown(ownedDescriptor, SHUT_RDWR)
            Darwin.close(ownedDescriptor)
            frameEmitter.finish(throwing: error)
            throw error
        }
    }

    private static func sameIdentity(
        _ lhs: UnixSocketMetadata,
        _ rhs: UnixSocketMetadata
    ) -> Bool {
        lhs.path == rhs.path
            && lhs.ownerUID == rhs.ownerUID
            && lhs.permissions == rhs.permissions
            && lhs.device == rhs.device
            && lhs.inode == rhs.inode
    }

    public func send(_ frame: Data) async throws {
        guard let descriptor else { throw UnixSocketTransportError.notConnected }
        let encoded = try outboundCodec.encodeClientText(frame)
        try Self.writeAll(descriptor: descriptor, data: encoded)
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        frameStream
    }

    public func close() async {
        guard let ownedDescriptor = descriptor else {
            frameEmitter.finish()
            return
        }
        if let closeFrame = try? outboundCodec.encodeClientClose() {
            try? Self.writeAll(descriptor: ownedDescriptor, data: closeFrame)
        }
        descriptor = nil
        Darwin.shutdown(ownedDescriptor, SHUT_RDWR)
        Darwin.close(ownedDescriptor)
        readTask?.cancel()
        readTask = nil
        frameEmitter.finish()
    }

    private func startReadLoop(descriptor: Int32, initialData: Data) {
        let maxMessageBytes = self.maxMessageBytes
        let emitter = frameEmitter
        readTask = Task.detached { [weak self] in
            var codec = WebSocketCodec(maxMessageBytes: maxMessageBytes)
            do {
                if !initialData.isEmpty {
                    let result = try codec.receiveServerData(initialData)
                    for frame in result.messages { emitter.yield(frame) }
                    for response in result.outboundFrames {
                        try await self?.writeControl(response, on: descriptor)
                    }
                    if result.receivedClose {
                        await self?.readerFinished(descriptor: descriptor, error: nil)
                        return
                    }
                }

                var bytes = [UInt8](repeating: 0, count: 16_384)
                while !Task.isCancelled {
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count == 0 {
                        await self?.readerFinished(descriptor: descriptor, error: nil)
                        return
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if Task.isCancelled { return }
                        throw UnixSocketTransportError.systemCall(operation: "read", code: errno)
                    }
                    let result = try codec.receiveServerData(Data(bytes.prefix(count)))
                    for frame in result.messages { emitter.yield(frame) }
                    for response in result.outboundFrames {
                        try await self?.writeControl(response, on: descriptor)
                    }
                    if result.receivedClose {
                        await self?.readerFinished(descriptor: descriptor, error: nil)
                        return
                    }
                }
            } catch {
                await self?.readerFinished(descriptor: descriptor, error: error)
            }
        }
    }

    private func writeControl(_ frame: Data, on expectedDescriptor: Int32) throws {
        guard descriptor == expectedDescriptor else { throw UnixSocketTransportError.notConnected }
        try Self.writeAll(descriptor: expectedDescriptor, data: frame)
    }

    private func readerFinished(descriptor finishedDescriptor: Int32, error: Error?) {
        guard descriptor == finishedDescriptor else { return }
        descriptor = nil
        readTask = nil
        Darwin.shutdown(finishedDescriptor, SHUT_RDWR)
        Darwin.close(finishedDescriptor)
        frameEmitter.finish(throwing: error)
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketTransportError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        return address
    }

    private static func readHandshake(descriptor: Int32) throws -> (headers: Data, remainder: Data) {
        let delimiter = Data("\r\n\r\n".utf8)
        var data = Data()
        while let range = data.range(of: delimiter) {
            return (Data(data[..<range.upperBound]), Data(data[range.upperBound...]))
        }
        while data.count <= 64 * 1024 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else {
                throw UnixSocketTransportError.systemCall(
                    operation: "read handshake",
                    code: count == 0 ? ECONNRESET : errno
                )
            }
            data.append(contentsOf: bytes.prefix(count))
            if let range = data.range(of: delimiter) {
                return (Data(data[..<range.upperBound]), Data(data[range.upperBound...]))
            }
        }
        throw UnixSocketTransportError.handshakeTooLarge
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw UnixSocketTransportError.systemCall(operation: "write", code: errno)
                }
                offset += count
            }
        }
    }
}

private final class UnixSocketFrameEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var isFinished = false

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func yield(_ frame: Data) {
        lock.lock()
        let shouldYield = !isFinished
        lock.unlock()
        if shouldYield { continuation.yield(frame) }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        lock.unlock()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
