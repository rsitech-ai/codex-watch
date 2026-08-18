import Darwin
import Foundation

public enum BridgeDiagnosticEvent: String, CaseIterable, Sendable {
    case serviceStarting = "service-starting"
    case serviceRunning = "service-running"
    case retryScheduled = "retry-scheduled"
    case servicePaused = "service-paused"
    case retentionMaintenanceFailed = "retention-maintenance-failed"
    case serviceFailed = "service-failed"
    case serviceStopped = "service-stopped"
}

public enum BridgeDiagnosticLogError: Error, Equatable, Sendable {
    case invalidConfiguration
    case unsafeDirectory
    case unsafeEntry
}

/// A closed-event local diagnostic sink. It deliberately has no API that can
/// accept user content, identifiers, paths, or errors.
public final class BridgeDiagnosticLog: @unchecked Sendable {
    private static let activeName = "bridge.log"
    private let directoryDescriptor: Int32
    private let maximumFileBytes: Int
    private let retainedFileCount: Int
    private let clock: @Sendable () -> Date
    private let writer: @Sendable (Int32, Data) -> Int
    private let lock = NSLock()

    public convenience init(
        directory: URL,
        maximumFileBytes: Int = 256 * 1_024,
        retainedFileCount: Int = 3,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        try self.init(
            directory: directory,
            maximumFileBytes: maximumFileBytes,
            retainedFileCount: retainedFileCount,
            clock: clock,
            writer: Self.darwinWrite
        )
    }

    init(
        directory: URL,
        maximumFileBytes: Int = 256 * 1_024,
        retainedFileCount: Int = 3,
        clock: @escaping @Sendable () -> Date = Date.init,
        writer: @escaping @Sendable (Int32, Data) -> Int
    ) throws {
        guard maximumFileBytes > 0, (1 ... 3).contains(retainedFileCount) else {
            throw BridgeDiagnosticLogError.invalidConfiguration
        }
        let descriptor = open(directory.standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BridgeDiagnosticLogError.unsafeDirectory }
        do {
            try Self.validateDirectory(descriptor)
            for name in Self.entryNames(retainedFileCount: retainedFileCount) {
                try Self.validateExistingEntry(named: name, directoryDescriptor: descriptor, maximumFileBytes: maximumFileBytes)
            }
            try Self.removeExcessGenerations(
                directoryDescriptor: descriptor,
                retainedFileCount: retainedFileCount,
                maximumFileBytes: maximumFileBytes
            )
        } catch {
            close(descriptor)
            throw error
        }
        directoryDescriptor = descriptor
        self.maximumFileBytes = maximumFileBytes
        self.retainedFileCount = retainedFileCount
        self.clock = clock
        self.writer = writer
    }

    deinit { close(directoryDescriptor) }

    @discardableResult
    public func append(_ event: BridgeDiagnosticEvent) -> Bool {
        lock.withLock {
            let timestamp = Int64(clock().timeIntervalSince1970)
            let line = Data("{\"timestamp\":\(timestamp),\"event\":\"\(event.rawValue)\"}\n".utf8)
            guard line.count <= maximumFileBytes else { return false }
            do {
                try Self.validateDirectory(directoryDescriptor)
                var descriptor = try Self.openActiveEntry(directoryDescriptor: directoryDescriptor, maximumFileBytes: maximumFileBytes)
                var metadata = stat()
                guard fstat(descriptor, &metadata) == 0 else {
                    close(descriptor)
                    return false
                }
                let originalLength: off_t
                if metadata.st_size > maximumFileBytes - line.count {
                    close(descriptor)
                    try rotate()
                    descriptor = try Self.openActiveEntry(directoryDescriptor: directoryDescriptor, maximumFileBytes: maximumFileBytes)
                    guard fstat(descriptor, &metadata) == 0 else {
                        close(descriptor)
                        return false
                    }
                    originalLength = metadata.st_size
                } else {
                    originalLength = metadata.st_size
                }
                defer { close(descriptor) }
                guard writeAll(line, to: descriptor), fsync(descriptor) == 0 else {
                    _ = ftruncate(descriptor, originalLength)
                    _ = fsync(descriptor)
                    return false
                }
                return true
            } catch {
                return false
            }
        }
    }

    private func rotate() throws {
        try Self.validateDirectory(directoryDescriptor)
        for name in Self.entryNames(retainedFileCount: retainedFileCount) {
            try Self.validateExistingEntry(named: name, directoryDescriptor: directoryDescriptor, maximumFileBytes: maximumFileBytes)
        }
        let oldest = Self.generationName(retainedFileCount)
        if Self.entryExists(oldest, directoryDescriptor: directoryDescriptor) {
            guard Self.unlink(oldest, directoryDescriptor: directoryDescriptor) == 0 else { throw BridgeDiagnosticLogError.unsafeEntry }
        }
        if retainedFileCount > 1 {
            for generation in stride(from: retainedFileCount - 1, through: 1, by: -1) {
                let source = Self.generationName(generation)
                guard !Self.entryExists(source, directoryDescriptor: directoryDescriptor)
                    || Self.rename(source, to: Self.generationName(generation + 1), directoryDescriptor: directoryDescriptor) == 0
                else { throw BridgeDiagnosticLogError.unsafeEntry }
            }
        }
        if Self.entryExists(Self.activeName, directoryDescriptor: directoryDescriptor) {
            guard Self.rename(Self.activeName, to: Self.generationName(1), directoryDescriptor: directoryDescriptor) == 0 else { throw BridgeDiagnosticLogError.unsafeEntry }
        }
        guard fsync(directoryDescriptor) == 0 else { throw BridgeDiagnosticLogError.unsafeDirectory }
    }

    private static func openActiveEntry(directoryDescriptor: Int32, maximumFileBytes: Int) throws -> Int32 {
        let descriptor = activeName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw BridgeDiagnosticLogError.unsafeEntry }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              isOwnerOnlyRegularSingleLink(metadata),
              metadata.st_size <= maximumFileBytes,
              fchmod(descriptor, 0o600) == 0
        else {
            close(descriptor)
            throw BridgeDiagnosticLogError.unsafeEntry
        }
        return descriptor
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o700
        else { throw BridgeDiagnosticLogError.unsafeDirectory }
    }

    private static func removeExcessGenerations(
        directoryDescriptor: Int32,
        retainedFileCount: Int,
        maximumFileBytes: Int
    ) throws {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw BridgeDiagnosticLogError.unsafeDirectory
        }
        defer { closedir(directory) }
        var removedAny = false
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name.hasPrefix("\(activeName).") else { continue }
            let suffix = String(name.dropFirst(activeName.count + 1))
            guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { continue }
            guard let generation = Int(suffix) else { throw BridgeDiagnosticLogError.unsafeEntry }
            guard generation < 1 || generation > retainedFileCount else { continue }
            try validateExistingEntry(
                named: name,
                directoryDescriptor: directoryDescriptor,
                maximumFileBytes: maximumFileBytes
            )
            guard unlink(name, directoryDescriptor: directoryDescriptor) == 0 else {
                throw BridgeDiagnosticLogError.unsafeEntry
            }
            removedAny = true
        }
        if removedAny, fsync(directoryDescriptor) != 0 { throw BridgeDiagnosticLogError.unsafeDirectory }
    }

    private static func validateExistingEntry(named name: String, directoryDescriptor: Int32, maximumFileBytes: Int) throws {
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if descriptor < 0 {
            guard errno == ENOENT else { throw BridgeDiagnosticLogError.unsafeEntry }
            return
        }
        defer { close(descriptor) }
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
              name.withCString({ fstatat(directoryDescriptor, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
              isOwnerOnlyRegularSingleLink(opened),
              opened.st_size <= maximumFileBytes,
              opened.st_dev == linked.st_dev,
              opened.st_ino == linked.st_ino
        else { throw BridgeDiagnosticLogError.unsafeEntry }
    }

    private static func isOwnerOnlyRegularSingleLink(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && (metadata.st_mode & 0o777) == 0o600
    }

    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let chunk = Data(data[offset...])
            let written = writer(descriptor, chunk)
            guard written > 0, written <= chunk.count else { return false }
            offset += written
        }
        return true
    }

    private static func darwinWrite(_ descriptor: Int32, _ data: Data) -> Int {
        data.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    private static func entryNames(retainedFileCount: Int) -> [String] {
        [activeName] + (1 ... retainedFileCount).map(generationName)
    }

    private static func generationName(_ generation: Int) -> String { "\(activeName).\(generation)" }

    private static func entryExists(_ name: String, directoryDescriptor: Int32) -> Bool {
        var metadata = stat()
        return name.withCString { fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW) == 0 }
    }

    private static func rename(_ source: String, to destination: String, directoryDescriptor: Int32) -> Int32 {
        source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameat(directoryDescriptor, sourcePointer, directoryDescriptor, destinationPointer)
            }
        }
    }

    private static func unlink(_ name: String, directoryDescriptor: Int32) -> Int32 {
        name.withCString { unlinkat(directoryDescriptor, $0, 0) }
    }

    public static func lastEvent(in directory: URL) -> BridgeDiagnosticEvent? {
        let url = directory.standardizedFileURL.appendingPathComponent(activeName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).last.map(String.init),
              let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(EventLine.self, from: data)
        else { return nil }
        return BridgeDiagnosticEvent(rawValue: parsed.event)
    }

    private struct EventLine: Decodable {
        let event: String
    }
}
