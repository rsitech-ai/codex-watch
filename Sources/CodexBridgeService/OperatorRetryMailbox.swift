import CodexBridgeShared
import Darwin
import Foundation

public enum OperatorRetryMailboxError: Error, Equatable, Sendable {
    case unavailable
}

/// File-backed operator retry requests for the running LaunchAgent listener.
/// ponytail: 1s poll in BoundedIntakeMemoProcessor; replace with a kevent if retry latency matters.
public struct OperatorRetryMailbox: Sendable {
    private let url: URL

    public init(stateDirectory: URL) {
        url = stateDirectory.standardizedFileURL.appendingPathComponent("retry-requested.json")
    }

    public func enqueue(_ memoID: MemoID) throws {
        try withLockedIDs { ids in
            if !ids.contains(memoID) {
                ids.append(memoID)
            }
        }
    }

    public func takeAll() throws -> [MemoID] {
        var taken: [MemoID] = []
        try withLockedIDs { ids in
            taken = ids
            ids = []
        }
        return taken
    }

    private func withLockedIDs(_ body: (inout [MemoID]) throws -> Void) throws {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw OperatorRetryMailboxError.unavailable }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX) == 0
        else { throw OperatorRetryMailboxError.unavailable }
        defer { _ = flock(descriptor, LOCK_UN) }

        var ids = try readIDs(from: descriptor)
        try body(&ids)
        try writeIDs(ids, to: descriptor)
    }

    private func readIDs(from descriptor: Int32) throws -> [MemoID] {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw OperatorRetryMailboxError.unavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { break }
            guard count > 0 else { throw OperatorRetryMailboxError.unavailable }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 64 * 1_024 { throw OperatorRetryMailboxError.unavailable }
        }
        if data.isEmpty { return [] }
        do {
            return try JSONDecoder().decode([MemoID].self, from: data)
        } catch {
            throw OperatorRetryMailboxError.unavailable
        }
    }

    private func writeIDs(_ ids: [MemoID], to descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ids)
        } catch {
            throw OperatorRetryMailboxError.unavailable
        }
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw OperatorRetryMailboxError.unavailable
        }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            return Darwin.write(descriptor, base, raw.count) == raw.count
        }
        guard wrote, fsync(descriptor) == 0 else {
            throw OperatorRetryMailboxError.unavailable
        }
    }
}
