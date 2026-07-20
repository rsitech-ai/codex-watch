import Darwin
import Foundation

struct SecureAdvisoryLockFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

enum SecureAdvisoryLockFile {
    static func descriptorIdentity(
        _ descriptor: Int32,
        normalizeMode: Bool
    ) -> SecureAdvisoryLockFileIdentity? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1
        else { return nil }
        if normalizeMode, fchmod(descriptor, 0o600) != 0 { return nil }
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600
        else { return nil }
        return SecureAdvisoryLockFileIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    static func path(
        _ url: URL,
        matches identity: SecureAdvisoryLockFileIdentity
    ) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600
            && metadata.st_dev == identity.device
            && metadata.st_ino == identity.inode
    }
}
