import CodexAppServerProtocol
import Foundation

public actor AppServerClient {
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        var sendTask: Task<Void, Never>?
    }

    private let transport: any AppServerTransport
    private let notificationStream: AsyncStream<JSONRPCNotification>
    private let notificationContinuation: AsyncStream<JSONRPCNotification>.Continuation

    private var readerTask: Task<Void, Never>?
    private var pending: [JSONRPCID: PendingRequest] = [:]
    private var nextRequestID = 1
    private var isConnected = false
    private var hasConnected = false
    private var isInitializing = false
    private var isInitialized = false

    public init(transport: any AppServerTransport) {
        self.transport = transport
        let notifications = AsyncStream<JSONRPCNotification>.makeStream()
        notificationStream = notifications.stream
        notificationContinuation = notifications.continuation
    }

    public nonisolated func notifications() -> AsyncStream<JSONRPCNotification> {
        notificationStream
    }

    public func initialize(clientName: String, title: String, version: String) async throws {
        guard !isInitialized, !isInitializing else {
            throw AppServerClientError.alreadyInitialized
        }

        isInitializing = true
        defer { isInitializing = false }

        if !isConnected {
            do {
                try await transport.connect()
            } catch let error as UnixSocketSafetyError {
                switch error {
                case .symlink, .notSocket, .wrongOwner, .permissions:
                    throw AppServerClientError.endpointSafety
                case .systemCall:
                    throw AppServerClientError.notConnected
                }
            } catch let error as UnixSocketTransportError {
                throw Self.translate(error)
            } catch is WebSocketCodecError {
                throw AppServerClientError.malformedFrame
            } catch {
                throw AppServerClientError.notConnected
            }
            isConnected = true
            hasConnected = true
            startReader()
        }

        _ = try await request(.initialize(clientName: clientName, title: title, version: version))
        try await sendNotification(.initialized)
        isInitialized = true
    }

    public func call(_ method: AppServerMethod) async throws -> JSONValue {
        guard isConnected else {
            throw hasConnected ? AppServerClientError.notConnected : AppServerClientError.notInitialized
        }
        guard isInitialized else {
            throw AppServerClientError.notInitialized
        }
        return try await request(method)
    }

    public func close() async {
        let reader = readerTask
        readerTask = nil
        reader?.cancel()
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests { request.sendTask?.cancel() }
        isConnected = false
        isInitialized = false
        await transport.close()
        await reader?.value
        notificationContinuation.finish()
        for request in requests {
            request.continuation.resume(throwing: AppServerClientError.disconnected)
        }
    }

    private static func translate(_ error: UnixSocketTransportError) -> AppServerClientError {
        switch error {
        case .alreadyConnected, .pathTooLong:
            .configuration
        case .notConnected, .systemCall:
            .notConnected
        case .socketChanged:
            .endpointSafety
        case .handshakeTooLarge:
            .malformedFrame
        }
    }

    private func startReader() {
        guard readerTask == nil else { return }
        let frames = transport.frames()

        readerTask = Task { [weak self] in
            do {
                for try await frame in frames {
                    let message: JSONRPCMessage
                    do {
                        message = try JSONDecoder().decode(JSONRPCMessage.self, from: frame)
                    } catch {
                        await self?.finishConnection(with: .malformedFrame)
                        return
                    }
                    await self?.receive(message)
                }
                await self?.finishConnection(with: .disconnected)
            } catch is WebSocketCodecError {
                await self?.finishConnection(with: .malformedFrame)
            } catch {
                await self?.finishConnection(with: .disconnected)
            }
        }
    }

    private func request(_ method: AppServerMethod) async throws -> JSONValue {
        let id = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1
        let message = JSONRPCMessage.request(JSONRPCRequest(id: id, method: method))
        let frame: Data

        do {
            frame = try JSONEncoder().encode(message)
        } catch {
            throw AppServerClientError.malformedFrame
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(continuation: continuation, sendTask: nil)
                let sendTask = Task { [weak self, transport] in
                    do {
                        try await transport.send(frame)
                    } catch {
                        await self?.failPendingRequest(id: id)
                    }
                }
                pending[id]?.sendTask = sendTask
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(id: id) }
        }
    }

    private func sendNotification(_ method: AppServerMethod) async throws {
        let message = JSONRPCMessage.notification(JSONRPCNotification(method: method))
        let frame: Data

        do {
            frame = try JSONEncoder().encode(message)
            try await transport.send(frame)
        } catch let error as AppServerClientError {
            throw error
        } catch {
            throw AppServerClientError.disconnected
        }
    }

    private func receive(_ message: JSONRPCMessage) {
        switch message {
        case let .response(response):
            pending.removeValue(forKey: response.id)?.continuation.resume(returning: response.result)
        case let .errorResponse(response):
            pending.removeValue(forKey: response.id)?.continuation.resume(
                throwing: AppServerClientError.server(
                    code: response.error.code,
                    message: response.error.message
                )
            )
        case let .notification(notification):
            notificationContinuation.yield(notification)
        case .request:
            break
        }
    }

    private func failPendingRequest(id: JSONRPCID) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: AppServerClientError.disconnected)
    }

    private func cancelPendingRequest(id: JSONRPCID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.sendTask?.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func finishConnection(with error: AppServerClientError) {
        let continuations = Array(pending.values)
        pending.removeAll()
        for request in continuations { request.sendTask?.cancel() }
        isConnected = false
        isInitialized = false
        readerTask = nil
        notificationContinuation.finish()

        for request in continuations {
            request.continuation.resume(throwing: error)
        }
    }
}
