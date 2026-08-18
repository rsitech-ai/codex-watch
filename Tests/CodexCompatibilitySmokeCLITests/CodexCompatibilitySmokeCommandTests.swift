import Foundation
import Testing
@testable import CodexCompatibilitySmokeCLI

@Test func compatibilitySmokeRequiresEveryExplicitBoundary() throws {
    let fixture = try SmokeCommandFixture()
    defer { fixture.close() }
    let arguments = [
        "--codex", fixture.executable.path,
        "--evidence-directory", fixture.evidence.path,
        "--source-commit", "0123456789abcdef0123456789abcdef01234567",
        "--timeout-seconds", "20",
    ]

    let options = try CodexCompatibilitySmokeCommand.parse(arguments)

    #expect(options.codex.url == fixture.executable.resolvingSymlinksInPath())
    #expect(options.evidenceDirectory == fixture.evidence)
    #expect(options.sourceCommit == "0123456789abcdef0123456789abcdef01234567")
    #expect(options.timeoutSeconds == 20)
}

@Test(arguments: [
    [],
    ["--codex", "relative/codex"],
    ["--unknown", "value"],
    ["--timeout-seconds", "0"],
    ["--timeout-seconds", "61"],
    ["--source-commit", "0123456789ABCDEF0123456789ABCDEF01234567"],
])
func compatibilitySmokeRejectsMissingRelativeUnknownAndOutOfRangeArguments(arguments: [String]) {
    #expect(throws: CodexCompatibilitySmokeUsageError.self) {
        try CodexCompatibilitySmokeCommand.parse(arguments)
    }
}

@Test func compatibilitySmokeRejectsNormalCodexHomeAsEvidenceDirectory() throws {
    let fixture = try SmokeCommandFixture()
    defer { fixture.close() }
    let normalHome = fixture.root.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: normalHome, withIntermediateDirectories: false)

    #expect(throws: CodexCompatibilitySmokeUsageError.self) {
        try CodexCompatibilitySmokeCommand.parse([
            "--codex", fixture.executable.path,
            "--evidence-directory", normalHome.path,
            "--source-commit", "0123456789abcdef0123456789abcdef01234567",
        ], normalCodexHome: normalHome)
    }
}

private final class SmokeCommandFixture {
    let root: URL
    let executable: URL
    let evidence: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("compat-smoke-command-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("codex")
        evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func close() { try? FileManager.default.removeItem(at: root) }
}
