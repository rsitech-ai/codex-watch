@testable import CodexBridgeService
import Darwin
import Foundation
import Testing

@Test func bridgeDiagnosticLogWritesExactContentFreeJSONLine() throws {
    let directory = try makeDiagnosticDirectory()
    let log = try BridgeDiagnosticLog(
        directory: directory,
        clock: { Date(timeIntervalSince1970: 1_725_000_123.9) }
    )

    #expect(log.append(.serviceRunning))

    let data = try Data(contentsOf: directory.appending(path: "bridge.log"))
    #expect(String(decoding: data, as: UTF8.self) == "{\"timestamp\":1725000123,\"event\":\"service-running\"}\n")
}

@Test func bridgeDiagnosticLogRotatesAtConfiguredBoundAndDeletesOlderGeneration() throws {
    let directory = try makeDiagnosticDirectory()
    let log = try BridgeDiagnosticLog(
        directory: directory,
        maximumFileBytes: 80,
        retainedFileCount: 3,
        clock: { Date(timeIntervalSince1970: 7) }
    )

    #expect(log.append(.serviceStarting))
    #expect(log.append(.serviceRunning))
    #expect(log.append(.retryScheduled))
    #expect(log.append(.servicePaused))
    #expect(log.append(.retentionMaintenanceFailed))

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(names == ["bridge.log", "bridge.log.1", "bridge.log.2", "bridge.log.3"])
    #expect(try String(decoding: Data(contentsOf: directory.appending(path: "bridge.log")), as: UTF8.self) == "{\"timestamp\":7,\"event\":\"retention-maintenance-failed\"}\n")
    #expect(try String(decoding: Data(contentsOf: directory.appending(path: "bridge.log.1")), as: UTF8.self) == "{\"timestamp\":7,\"event\":\"service-paused\"}\n")
    for name in names {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? .max <= 80)
    }
}

@Test func bridgeDiagnosticLogRejectsInvalidBounds() throws {
    let directory = try makeDiagnosticDirectory()
    #expect(throws: (any Error).self) {
        _ = try BridgeDiagnosticLog(directory: directory, maximumFileBytes: 0)
    }
    #expect(throws: (any Error).self) {
        _ = try BridgeDiagnosticLog(directory: directory, retainedFileCount: 0)
    }
}

@Test func bridgeDiagnosticLogRejectsSymlinkAndHardLinkedExistingEntries() throws {
    let symlinkDirectory = try makeDiagnosticDirectory()
    let target = symlinkDirectory.appending(path: "target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(
        atPath: symlinkDirectory.appending(path: "bridge.log").path,
        withDestinationPath: target.path
    )
    #expect(throws: (any Error).self) {
        _ = try BridgeDiagnosticLog(directory: symlinkDirectory)
    }

    let hardLinkDirectory = try makeDiagnosticDirectory()
    let hardLinkTarget = hardLinkDirectory.appending(path: "target")
    try Data().write(to: hardLinkTarget)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: hardLinkTarget.path
    )
    #expect(link(hardLinkTarget.path, hardLinkDirectory.appending(path: "bridge.log").path) == 0)
    #expect(throws: (any Error).self) {
        _ = try BridgeDiagnosticLog(directory: hardLinkDirectory)
    }
}

@Test func bridgeDiagnosticLogRemovesValidatedGenerationsAboveRetentionCap() throws {
    let directory = try makeDiagnosticDirectory()
    let obsolete = directory.appending(path: "bridge.log.4")
    try Data("obsolete".utf8).write(to: obsolete)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: obsolete.path
    )

    let log = try BridgeDiagnosticLog(directory: directory)
    #expect(log.append(.serviceRunning))

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(names == ["bridge.log"])
}

@Test func bridgeDiagnosticLogRollsBackAPartialFailedWrite() throws {
    let directory = try makeDiagnosticDirectory()
    let initial = try BridgeDiagnosticLog(directory: directory, clock: { Date(timeIntervalSince1970: 1) })
    #expect(initial.append(.serviceRunning))
    let original = try Data(contentsOf: directory.appending(path: "bridge.log"))
    let writer = ShortThenFailWriter()
    let log = try BridgeDiagnosticLog(
        directory: directory,
        clock: { Date(timeIntervalSince1970: 2) },
        writer: { descriptor, data in writer.write(descriptor: descriptor, data: data) }
    )

    #expect(!log.append(.serviceStopped))
    #expect(try Data(contentsOf: directory.appending(path: "bridge.log")) == original)
}

@Test func bridgeDiagnosticLogRollsBackNewActiveFileAfterRotationWriteFailure() throws {
    let directory = try makeDiagnosticDirectory()
    let initial = try BridgeDiagnosticLog(
        directory: directory,
        maximumFileBytes: 80,
        clock: { Date(timeIntervalSince1970: 1) }
    )
    #expect(initial.append(.serviceRunning))
    let writer = ShortThenFailWriter()
    let log = try BridgeDiagnosticLog(
        directory: directory,
        maximumFileBytes: 80,
        clock: { Date(timeIntervalSince1970: 2) },
        writer: { descriptor, data in writer.write(descriptor: descriptor, data: data) }
    )

    #expect(!log.append(.retentionMaintenanceFailed))
    #expect(try Data(contentsOf: directory.appending(path: "bridge.log")).isEmpty)
    #expect(try Data(contentsOf: directory.appending(path: "bridge.log.1")).isEmpty == false)
}

private func makeDiagnosticDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "bridge-diagnostic-log-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    return directory
}

private final class ShortThenFailWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func write(descriptor: Int32, data: Data) -> Int {
        lock.withLock {
            callCount += 1
            guard callCount == 1 else { return -1 }
            return data.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress,
                    min(1, buffer.count)
                )
            }
        }
    }
}
