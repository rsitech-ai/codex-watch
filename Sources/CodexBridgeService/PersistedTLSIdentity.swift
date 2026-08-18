import Darwin
import Foundation
import Security

/// PKCS#12 copy of the listener TLS identity under the state root.
/// Survives ad-hoc/Developer ID signature changes that partition the login Keychain.
public enum PersistedTLSIdentity {
    public static let p12FileName = "tls-identity.p12"
    public static let passwordFileName = "tls-identity.password"

    public static func exists(stateDirectory: URL) -> Bool {
        let p12 = stateDirectory.appendingPathComponent(p12FileName)
        let password = stateDirectory.appendingPathComponent(passwordFileName)
        return FileManager.default.isReadableFile(atPath: p12.path)
            && FileManager.default.isReadableFile(atPath: password.path)
    }

    public static func provider(stateDirectory: URL) throws -> PKCS12TLSIdentityProvider? {
        guard exists(stateDirectory: stateDirectory) else { return nil }
        let password = try SecureLocalFile.readUTF8PrivateFile(
            at: stateDirectory.appendingPathComponent(passwordFileName)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return nil }
        return PKCS12TLSIdentityProvider(
            p12URL: stateDirectory.appendingPathComponent(p12FileName),
            password: password
        )
    }

    public static func persist(identity: SecIdentity, stateDirectory: URL) throws {
        if exists(stateDirectory: stateDirectory) { return }
        let password = randomPassword()
        let data = try exportPKCS12(identity: identity, password: password)
        try writePrivate(data, to: stateDirectory.appendingPathComponent(p12FileName))
        try writePrivate(
            Data(password.utf8),
            to: stateDirectory.appendingPathComponent(passwordFileName)
        )
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func exportPKCS12(identity: SecIdentity, password: String) throws -> Data {
        var parameters = SecItemImportExportKeyParameters()
        parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        parameters.passphrase = Unmanaged.passRetained(password as CFString)
        defer { parameters.passphrase?.release() }
        var exported: CFData?
        let status = SecItemExport(
            identity,
            .formatPKCS12,
            [],
            &parameters,
            &exported
        )
        guard status == errSecSuccess, let exported, CFDataGetLength(exported) > 0 else {
            throw TLSIdentityProvisionerError.keychainUnavailable
        }
        return exported as Data
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).staged-\(UUID().uuidString)")
        do {
            try data.write(to: staged, options: .withoutOverwriting)
        } catch {
            throw TLSIdentityProvisionerError.keychainUnavailable
        }
        guard chmod(staged.path, 0o600) == 0, Darwin.rename(staged.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw TLSIdentityProvisionerError.keychainUnavailable
        }
    }
}
