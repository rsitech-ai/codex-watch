import Darwin
import Foundation

public enum CodexExecutableValidationError: Error, Equatable, Sendable {
    case notAbsolute
    case missing
    case notRegularFile
    case wrongOwner
    case notExecutable
}

public struct ValidatedCodexExecutable: Sendable, Equatable {
    public let url: URL

    public init(_ candidate: URL) throws {
        guard candidate.isFileURL,
              candidate.baseURL == nil,
              candidate.path.hasPrefix("/")
        else {
            throw CodexExecutableValidationError.notAbsolute
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        var metadata = stat()
        guard lstat(resolved.path, &metadata) == 0 else {
            throw CodexExecutableValidationError.missing
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw CodexExecutableValidationError.notRegularFile
        }
        guard metadata.st_uid == geteuid() else {
            throw CodexExecutableValidationError.wrongOwner
        }
        guard metadata.st_mode & 0o111 != 0 else {
            throw CodexExecutableValidationError.notExecutable
        }
        url = resolved
    }
}

public enum IsolatedCodexWorkspaceError: Error, Equatable, Sendable {
    case invalidBaseDirectory
    case creationFailed
    case verificationFailed
}

public final class IsolatedCodexWorkspace: @unchecked Sendable {
    public let root: URL
    public let codexHome: URL
    public let neutralDirectory: URL

    private let identity: FileIdentity
    private let lock = NSLock()
    private var isClosed = false

    private init(root: URL, codexHome: URL, neutralDirectory: URL, identity: FileIdentity) {
        self.root = root
        self.codexHome = codexHome
        self.neutralDirectory = neutralDirectory
        self.identity = identity
    }

    public static func create(
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> IsolatedCodexWorkspace {
        let base = baseDirectory.standardizedFileURL
        var baseMetadata = stat()
        guard base.isFileURL,
              base.path.hasPrefix("/"),
              lstat(base.path, &baseMetadata) == 0,
              baseMetadata.st_mode & S_IFMT == S_IFDIR,
              baseMetadata.st_uid == geteuid()
        else {
            throw IsolatedCodexWorkspaceError.invalidBaseDirectory
        }

        let root = base.appendingPathComponent("codex-compatibility-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let cwd = root.appendingPathComponent("cwd", isDirectory: true)
        var createdRoot = false

        do {
            try createPrivateDirectory(root)
            createdRoot = true
            try createPrivateDirectory(home)
            try createPrivateDirectory(cwd)
            let identity = try verifiedPrivateDirectory(root)
            _ = try verifiedPrivateDirectory(home)
            _ = try verifiedPrivateDirectory(cwd)
            return IsolatedCodexWorkspace(root: root, codexHome: home, neutralDirectory: cwd, identity: identity)
        } catch {
            if createdRoot { try? FileManager.default.removeItem(at: root) }
            if error is IsolatedCodexWorkspaceError { throw error }
            throw IsolatedCodexWorkspaceError.creationFailed
        }
    }

    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        guard let current = try? Self.directoryIdentity(root), current == identity else { return }
        try? FileManager.default.removeItem(at: root)
    }

    deinit { close() }

    private static func createPrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else {
            throw IsolatedCodexWorkspaceError.creationFailed
        }
    }

    private static func verifiedPrivateDirectory(_ url: URL) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == 0o700
        else {
            throw IsolatedCodexWorkspaceError.verificationFailed
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func directoryIdentity(_ url: URL) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid()
        else {
            throw IsolatedCodexWorkspaceError.verificationFailed
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}

private struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}
