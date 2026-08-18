import CodexWatchCore
import Foundation
import Security

protocol WatchBridgeCredentialStore: Sendable {
    func load() async throws -> WatchBridgeCredential?
    func save(_ credential: WatchBridgeCredential) async throws
    func remove() async throws
}

enum BridgeKeychainError: Error, Sendable {
    case encodingFailed
    case unexpectedStatus(OSStatus)
}

actor BridgeKeychainStore: WatchBridgeCredentialStore {
    private let service: String
    private let account: String

    init(
        service: String = "ai.rsitech.codexwatch.bridge",
        account: String = "primary-watch-bridge"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> WatchBridgeCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BridgeKeychainError.unexpectedStatus(status)
        }
        do {
            return try JSONDecoder().decode(WatchBridgeCredential.self, from: data)
        } catch {
            throw BridgeKeychainError.encodingFailed
        }
    }

    func save(_ credential: WatchBridgeCredential) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw BridgeKeychainError.encodingFailed
        }

        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BridgeKeychainError.unexpectedStatus(updateStatus)
        }

        var addition = baseQuery
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BridgeKeychainError.unexpectedStatus(addStatus)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeKeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
