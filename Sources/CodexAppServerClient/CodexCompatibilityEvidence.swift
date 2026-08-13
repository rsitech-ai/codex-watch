import Darwin
import Foundation

public struct CodexCompatibilityEvidence: Encodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let observedAt: Date
    public let sourceCommit: String
    public let codexVersion: String?
    public let method: String
    public let result: String
    public let label: String

    public init(
        schemaVersion: Int = 1,
        observedAt: Date,
        sourceCommit: String,
        codexVersion: String?,
        method: String = "thread/list",
        result: String,
        label: String = "unverified"
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.sourceCommit = sourceCommit
        self.codexVersion = codexVersion
        self.method = method
        self.result = result
        self.label = label
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, observedAt, sourceCommit, codexVersion, method, result, label
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(sourceCommit, forKey: .sourceCommit)
        try container.encode(codexVersion, forKey: .codexVersion)
        try container.encode(method, forKey: .method)
        try container.encode(result, forKey: .result)
        try container.encode(label, forKey: .label)
    }
}

public enum CodexCompatibilityEvidenceWriteError: Error, Equatable, Sendable {
    case invalidDirectory
    case invalidTarget
    case alreadyExists
    case encodingFailed
    case writeFailed
}

public struct CodexCompatibilityEvidenceWriter: Sendable {
    public init() {}

    @discardableResult
    public func writeUnique(
        _ evidence: CodexCompatibilityEvidence,
        to directory: URL
    ) throws -> URL {
        try validateDirectory(directory)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: evidence.observedAt)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        let target = directory.appendingPathComponent(
            "codex-compatibility-\(timestamp)-\(UUID().uuidString).json",
            isDirectory: false
        )
        try write(evidence, to: target)
        return target
    }

    public func write(_ evidence: CodexCompatibilityEvidence, to target: URL) throws {
        let directory = target.deletingLastPathComponent().standardizedFileURL
        try validateDirectory(directory)
        guard target.isFileURL,
              target.baseURL == nil,
              target.standardizedFileURL.deletingLastPathComponent() == directory,
              !target.lastPathComponent.isEmpty,
              target.lastPathComponent != ".",
              target.lastPathComponent != ".."
        else { throw CodexCompatibilityEvidenceWriteError.invalidTarget }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do {
            payload = try encoder.encode(evidence) + Data([0x0A])
        } catch {
            throw CodexCompatibilityEvidenceWriteError.encodingFailed
        }

        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw CodexCompatibilityEvidenceWriteError.alreadyExists }
            throw CodexCompatibilityEvidenceWriteError.writeFailed
        }
        var createdMetadata = stat()
        guard fstat(descriptor, &createdMetadata) == 0,
              createdMetadata.st_mode & S_IFMT == S_IFREG,
              createdMetadata.st_uid == geteuid()
        else {
            Darwin.close(descriptor)
            throw CodexCompatibilityEvidenceWriteError.writeFailed
        }

        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                var namedMetadata = stat()
                if lstat(target.path, &namedMetadata) == 0,
                   namedMetadata.st_mode & S_IFMT == S_IFREG,
                   namedMetadata.st_dev == createdMetadata.st_dev,
                   namedMetadata.st_ino == createdMetadata.st_ino
                {
                    unlink(target.path)
                }
            }
        }
        var offset = 0
        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < payload.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), payload.count - offset)
                guard count > 0 else { throw CodexCompatibilityEvidenceWriteError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw CodexCompatibilityEvidenceWriteError.writeFailed
        }
        completed = true
    }

    private func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL,
              directory.baseURL == nil,
              directory.path.hasPrefix("/")
        else { throw CodexCompatibilityEvidenceWriteError.invalidDirectory }
        var metadata = stat()
        guard lstat(directory.standardizedFileURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid()
        else { throw CodexCompatibilityEvidenceWriteError.invalidDirectory }
    }
}
