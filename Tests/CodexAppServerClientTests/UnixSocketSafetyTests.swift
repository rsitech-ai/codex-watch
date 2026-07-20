import Darwin
import Foundation
import Testing
@testable import CodexAppServerClient

@Suite struct UnixSocketSafetyTests {
    @Test func acceptsOnlyPrivateOwnedSocket() throws {
        let fixture = try UnixListenerFixture(mode: 0o600)
        defer { fixture.close() }

        let metadata = try UnixSocketValidator.validate(path: fixture.path, expectedUID: getuid())

        #expect(metadata.ownerUID == getuid())
        #expect(metadata.permissions == 0o600)
    }

    @Test func rejectsSymlinkBeforeConnect() throws {
        let fixture = try UnixListenerFixture(mode: 0o600)
        defer { fixture.close() }
        let link = fixture.directory.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: fixture.path)
        )

        #expect(throws: UnixSocketSafetyError.symlink) {
            _ = try UnixSocketValidator.validate(path: link.path, expectedUID: getuid())
        }
    }

    @Test func rejectsRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-socket")
        try Data("x".utf8).write(to: file)

        #expect(throws: UnixSocketSafetyError.notSocket) {
            _ = try UnixSocketValidator.validate(path: file.path, expectedUID: getuid())
        }
    }

    @Test func rejectsGroupOrWorldPermissions() throws {
        let fixture = try UnixListenerFixture(mode: 0o660)
        defer { fixture.close() }

        #expect(throws: UnixSocketSafetyError.permissions(actual: 0o660)) {
            _ = try UnixSocketValidator.validate(path: fixture.path, expectedUID: getuid())
        }
    }

    @Test func rejectsUnexpectedOwnerFromInjectedMetadataProvider() throws {
        let fixture = try UnixListenerFixture(mode: 0o600)
        defer { fixture.close() }

        #expect(throws: UnixSocketSafetyError.wrongOwner(actual: getuid() &+ 1)) {
            _ = try UnixSocketValidator.validate(
                path: fixture.path,
                expectedUID: getuid(),
                metadataProvider: { path in
                    var info = stat()
                    guard lstat(path, &info) == 0 else {
                        throw UnixSocketSafetyError.systemCall(operation: "lstat", code: errno)
                    }
                    return UnixSocketRawMetadata(
                        mode: info.st_mode,
                        ownerUID: getuid() &+ 1,
                        device: info.st_dev,
                        inode: info.st_ino
                    )
                }
            )
        }
    }
}

final class UnixListenerFixture: @unchecked Sendable {
    let directory: URL
    let path: String
    let descriptor: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(mode: mode_t = 0o600) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("server.sock").path
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

        do {
            var address = try makeUnixAddress(path: path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard chmod(path, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Darwin.listen(descriptor, 4) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var listenerIsOpen: Bool {
        fcntl(descriptor, F_GETFD) != -1
    }
}

func makeUnixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    return address
}
