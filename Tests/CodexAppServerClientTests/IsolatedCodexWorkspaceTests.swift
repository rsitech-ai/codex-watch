import Darwin
import Foundation
import Testing
@testable import CodexAppServerClient

@Test func createsPrivateEmptyDirectoriesAndCleansOnlyOwnedRoot() throws {
    let fixture = try IsolatedWorkspaceFixture()
    defer { fixture.close() }

    let workspace = try IsolatedCodexWorkspace.create(baseDirectory: fixture.root)
    let capturedRoot = workspace.root

    #expect(workspace.codexHome != fixture.normalCodexHome)
    #expect(workspace.neutralDirectory != fixture.normalCodexHome)
    #expect(try posixMode(workspace.root) == 0o700)
    #expect(try posixMode(workspace.codexHome) == 0o700)
    #expect(try posixMode(workspace.neutralDirectory) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.codexHome.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.neutralDirectory.path).isEmpty)

    workspace.close()
    workspace.close()
    #expect(!FileManager.default.fileExists(atPath: capturedRoot.path))
}

@Test func cleanupRefusesAReplacedRoot() throws {
    let fixture = try IsolatedWorkspaceFixture()
    defer { fixture.close() }
    let workspace = try IsolatedCodexWorkspace.create(baseDirectory: fixture.root)
    let original = workspace.root.appendingPathExtension("original")
    try FileManager.default.moveItem(at: workspace.root, to: original)
    try FileManager.default.createDirectory(at: workspace.root, withIntermediateDirectories: false)

    workspace.close()

    #expect(FileManager.default.fileExists(atPath: workspace.root.path))
    #expect(FileManager.default.fileExists(atPath: original.path))
}

@Test func cleanupDoesNotFollowAReplacedChildSymlink() throws {
    let fixture = try IsolatedWorkspaceFixture()
    defer { fixture.close() }
    let workspace = try IsolatedCodexWorkspace.create(baseDirectory: fixture.root)
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.removeItem(at: workspace.codexHome)
    try FileManager.default.createSymbolicLink(at: workspace.codexHome, withDestinationURL: outside)

    workspace.close()

    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
}

@Test func validatesAbsoluteOwnedExecutableAndResolvesSymlink() throws {
    let fixture = try IsolatedWorkspaceFixture()
    defer { fixture.close() }
    let executable = try fixture.makeExecutable(named: "codex")
    let link = fixture.root.appendingPathComponent("codex-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

    let validated = try ValidatedCodexExecutable(link)

    #expect(validated.url == executable.resolvingSymlinksInPath().standardizedFileURL)
}

@Test func rejectsInvalidExecutableBoundaries() throws {
    let fixture = try IsolatedWorkspaceFixture()
    defer { fixture.close() }
    let directory = fixture.root.appendingPathComponent("directory", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let nonExecutable = fixture.root.appendingPathComponent("not-executable")
    try Data("x".utf8).write(to: nonExecutable)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nonExecutable.path)

    #expect(throws: CodexExecutableValidationError.notAbsolute) {
        try ValidatedCodexExecutable(URL(fileURLWithPath: "relative/codex", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    }
    #expect(throws: CodexExecutableValidationError.missing) {
        try ValidatedCodexExecutable(fixture.root.appendingPathComponent("missing"))
    }
    #expect(throws: CodexExecutableValidationError.notRegularFile) {
        try ValidatedCodexExecutable(directory)
    }
    #expect(throws: CodexExecutableValidationError.notExecutable) {
        try ValidatedCodexExecutable(nonExecutable)
    }
}

private final class IsolatedWorkspaceFixture {
    let root: URL
    let normalCodexHome: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("isolated-codex-tests-\(UUID().uuidString)", isDirectory: true)
        normalCodexHome = root.appendingPathComponent("normal-codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: normalCodexHome, withIntermediateDirectories: true)
    }

    func makeExecutable(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func posixMode(_ url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileReadUnknown) }
    return metadata.st_mode & 0o7777
}
