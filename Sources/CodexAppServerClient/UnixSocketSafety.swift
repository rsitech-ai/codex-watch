import Darwin

public struct UnixSocketMetadata: Equatable, Sendable {
    public let path: String
    public let ownerUID: uid_t
    public let permissions: mode_t
    public let device: dev_t
    public let inode: ino_t
}

public enum UnixSocketSafetyError: Error, Equatable {
    case systemCall(operation: String, code: Int32)
    case symlink
    case notSocket
    case wrongOwner(actual: uid_t)
    case permissions(actual: mode_t)
}

struct UnixSocketRawMetadata: Sendable {
    let mode: mode_t
    let ownerUID: uid_t
    let device: dev_t
    let inode: ino_t
}

public enum UnixSocketValidator {
    public static func validate(path: String, expectedUID: uid_t) throws -> UnixSocketMetadata {
        try validate(path: path, expectedUID: expectedUID, metadataProvider: readMetadata)
    }

    static func validate(
        path: String,
        expectedUID: uid_t,
        metadataProvider: (String) throws -> UnixSocketRawMetadata
    ) throws -> UnixSocketMetadata {
        let info = try metadataProvider(path)
        guard (info.mode & S_IFMT) != S_IFLNK else { throw UnixSocketSafetyError.symlink }
        guard (info.mode & S_IFMT) == S_IFSOCK else { throw UnixSocketSafetyError.notSocket }
        guard info.ownerUID == expectedUID else {
            throw UnixSocketSafetyError.wrongOwner(actual: info.ownerUID)
        }
        let permissions = info.mode & 0o777
        guard (info.mode & 0o077) == 0 else {
            throw UnixSocketSafetyError.permissions(actual: permissions)
        }
        return UnixSocketMetadata(
            path: path,
            ownerUID: info.ownerUID,
            permissions: permissions,
            device: info.device,
            inode: info.inode
        )
    }

    private static func readMetadata(path: String) throws -> UnixSocketRawMetadata {
        var info: stat = .init()
        guard lstat(path, &info) == 0 else {
            throw UnixSocketSafetyError.systemCall(operation: "lstat", code: errno)
        }
        return UnixSocketRawMetadata(
            mode: info.st_mode,
            ownerUID: info.st_uid,
            device: info.st_dev,
            inode: info.st_ino
        )
    }
}
