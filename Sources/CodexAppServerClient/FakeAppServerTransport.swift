import CodexAppServerProtocol
import Foundation

public actor FakeAppServerTransport: AppServerTransport {
    private struct SentWaiter {
        let index: Int
        let continuation: CheckedContinuation<JSONRPCMessage, Never>
    }

    public nonisolated let frameStream: AsyncThrowingStream<Data, Error>
    private let frameContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var messages: [JSONRPCMessage] = []
    private var sentWaiters: [SentWaiter] = []
    private var isConnected = false

    public init() {
        let frames = AsyncThrowingStream<Data, Error>.makeStream()
        frameStream = frames.stream
        frameContinuation = frames.continuation
    }

    public func connect() async throws {
        isConnected = true
    }

    public func send(_ frame: Data) async throws {
        guard isConnected else {
            throw AppServerClientError.notConnected
        }

        let message: JSONRPCMessage
        do {
            message = try JSONDecoder().decode(JSONRPCMessage.self, from: frame)
        } catch {
            throw AppServerClientError.malformedFrame
        }
        messages.append(message)
        resumeReadyWaiters()
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, Error> {
        frameStream
    }

    public func close() async {
        isConnected = false
        frameContinuation.finish()
    }

    public func enqueueResponse(id: Int, result: JSONValue) {
        enqueue(.response(JSONRPCResponse(id: .integer(id), result: result)))
    }

    public func enqueueResponse(id: JSONRPCID, result: JSONValue) {
        enqueue(.response(JSONRPCResponse(id: id, result: result)))
    }

    public func enqueueNotification(_ notification: JSONRPCNotification) {
        enqueue(.notification(notification))
    }

    public func finish() {
        isConnected = false
        frameContinuation.finish()
    }

    public func sentMessages() -> [JSONRPCMessage] {
        messages
    }

    public func resetSentMessages() {
        messages.removeAll()
    }

    public func waitForSentRequest(at index: Int) async -> JSONRPCMessage {
        if messages.indices.contains(index) {
            return messages[index]
        }

        return await withCheckedContinuation { continuation in
            sentWaiters.append(SentWaiter(index: index, continuation: continuation))
        }
    }

    public func replyToSentRequest(at index: Int, result: JSONValue) async {
        let message = await waitForSentRequest(at: index)
        guard case let .request(request) = message else { return }
        enqueue(.response(JSONRPCResponse(id: request.id, result: result)))
    }

    public func replyToSentRequest(at index: Int, errorCode: Int, message: String) async {
        let sent = await waitForSentRequest(at: index)
        guard case let .request(request) = sent else { return }
        enqueue(.errorResponse(JSONRPCErrorResponse(
            id: request.id,
            error: JSONRPCError(code: errorCode, message: message)
        )))
    }

    private func enqueue(_ message: JSONRPCMessage) {
        guard let frame = try? JSONEncoder().encode(message) else { return }
        frameContinuation.yield(frame)
    }

    private func resumeReadyWaiters() {
        let ready = sentWaiters.filter { messages.indices.contains($0.index) }
        sentWaiters.removeAll { messages.indices.contains($0.index) }
        for waiter in ready {
            waiter.continuation.resume(returning: messages[waiter.index])
        }
    }
}
