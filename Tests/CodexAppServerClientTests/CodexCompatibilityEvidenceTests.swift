import Foundation
import Testing
@testable import CodexAppServerClient

@Test func compatibilityEvidenceContainsOnlyAllowListedFields() throws {
    let evidence = CodexCompatibilityEvidence(
        schemaVersion: 1,
        observedAt: Date(timeIntervalSince1970: 1_786_572_000),
        sourceCommit: "0123456789abcdef0123456789abcdef01234567",
        codexVersion: "codex-cli 0.144.5",
        method: "thread/list",
        result: "PASS",
        label: "unverified"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any]
    )
    #expect(Set(object.keys) == [
        "schemaVersion", "observedAt", "sourceCommit", "codexVersion",
        "method", "result", "label",
    ])
}

@Test func compatibilityEvidenceWriterCreatesPrivateFileAndRefusesOverwrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("compat-evidence-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("existing.json")
    try Data("sentinel".utf8).write(to: target)
    let writer = CodexCompatibilityEvidenceWriter()
    let evidence = CodexCompatibilityEvidence(
        observedAt: Date(timeIntervalSince1970: 1_786_572_000),
        sourceCommit: "0123456789abcdef0123456789abcdef01234567",
        codexVersion: nil,
        result: "VERSION_UNAVAILABLE"
    )

    #expect(throws: CodexCompatibilityEvidenceWriteError.alreadyExists) {
        try writer.write(evidence, to: target)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")

    let created = try writer.writeUnique(evidence, to: root)
    let attributes = try FileManager.default.attributesOfItem(atPath: created.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
