import Foundation

public actor ConnectionAdmissionGate {
    private let maximumConnections: Int
    private let maximumUploads: Int
    private var connectionTokens: Set<UUID> = []
    private var uploadTokens: Set<UUID> = []

    public init(maximumConnections: Int = 8, maximumUploads: Int = 2) throws {
        guard maximumConnections > 0, maximumUploads > 0 else {
            throw BridgeConfigurationError.invalidLimit
        }
        self.maximumConnections = maximumConnections
        self.maximumUploads = maximumUploads
    }

    public func acquireConnection() -> UUID? {
        guard connectionTokens.count < maximumConnections else { return nil }
        let token = UUID()
        connectionTokens.insert(token)
        return token
    }

    @discardableResult
    public func releaseConnection(_ token: UUID) -> Bool {
        connectionTokens.remove(token) != nil
    }

    public func acquireUpload() -> UUID? {
        guard uploadTokens.count < maximumUploads else { return nil }
        let token = UUID()
        uploadTokens.insert(token)
        return token
    }

    @discardableResult
    public func releaseUpload(_ token: UUID) -> Bool {
        uploadTokens.remove(token) != nil
    }
}
