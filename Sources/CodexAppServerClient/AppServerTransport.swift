import Foundation

public protocol AppServerTransport: Sendable {
    func connect() async throws
    func send(_ frame: Data) async throws
    func frames() -> AsyncThrowingStream<Data, Error>
    func close() async
}

public enum AppServerClientError: Error, Equatable {
    case notConnected
    case notInitialized
    case alreadyInitialized
    case disconnected
    case malformedFrame
    case endpointSafety
    case configuration
    case server(code: Int, message: String)
}
