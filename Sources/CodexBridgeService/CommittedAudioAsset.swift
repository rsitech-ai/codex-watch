import CodexBridgeShared
import Darwin
import Foundation

public enum CommittedAudioAssetError: Error, Equatable, Sendable {
    case invalidAsset
    case identityChanged
}

public struct CommittedAudioAsset: Equatable, Sendable {
    public let url: URL
    public let expectedSHA256: String
    public let byteCount: Int

    private let device: dev_t
    private let inode: ino_t

    public init(url: URL, expectedSHA256: String) throws {
        let normalizedURL = url.standardizedFileURL
        guard AudioDigest.isValidHex(expectedSHA256) else {
            throw CommittedAudioAssetError.invalidAsset
        }
        let snapshot = try Self.snapshot(normalizedURL)
        guard snapshot.digest == expectedSHA256.lowercased() else {
            throw CommittedAudioAssetError.invalidAsset
        }
        self.url = normalizedURL
        self.expectedSHA256 = expectedSHA256.lowercased()
        byteCount = snapshot.byteCount
        device = snapshot.device
        inode = snapshot.inode
    }

    public func validate() throws {
        let snapshot: Snapshot
        do {
            snapshot = try Self.snapshot(url)
        } catch {
            throw CommittedAudioAssetError.identityChanged
        }
        guard snapshot.device == device,
              snapshot.inode == inode,
              snapshot.byteCount == byteCount,
              snapshot.digest == expectedSHA256
        else { throw CommittedAudioAssetError.identityChanged }
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        guard url.isFileURL else { throw CommittedAudioAssetError.invalidAsset }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CommittedAudioAssetError.invalidAsset }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= 32 * 1_024 * 1_024
        else { throw CommittedAudioAssetError.invalidAsset }

        var data = Data(count: Int(before.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else { return -1 }
                offset += count
            }
            return offset
        }
        var after = stat()
        guard bytesRead == data.count,
              fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size
        else { throw CommittedAudioAssetError.invalidAsset }
        return Snapshot(
            device: before.st_dev,
            inode: before.st_ino,
            byteCount: data.count,
            digest: AudioDigest.hex(data)
        )
    }
}

private struct Snapshot {
    let device: dev_t
    let inode: ino_t
    let byteCount: Int
    let digest: String
}
