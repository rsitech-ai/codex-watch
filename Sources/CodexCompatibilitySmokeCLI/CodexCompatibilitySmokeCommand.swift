import CodexAppServerClient
import Darwin
import Foundation

public struct CodexCompatibilitySmokeOptions: Sendable {
    public let codex: ValidatedCodexExecutable
    public let evidenceDirectory: URL
    public let sourceCommit: String
    public let timeoutSeconds: Int
}

public enum CodexCompatibilitySmokeUsageError: Error, Equatable, Sendable {
    case invalidArguments
}

public enum CodexCompatibilitySmokeCommand {
    public static func parse(
        _ arguments: [String],
        normalCodexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) throws -> CodexCompatibilitySmokeOptions {
        var codexPath: String?
        var evidencePath: String?
        var sourceCommit: String?
        var timeoutSeconds = 20
        var didSetTimeout = false
        var index = 0

        while index < arguments.count {
            guard index + 1 < arguments.count else {
                throw CodexCompatibilitySmokeUsageError.invalidArguments
            }
            let option = arguments[index]
            let value = arguments[index + 1]
            switch option {
            case "--codex" where codexPath == nil:
                codexPath = value
            case "--evidence-directory" where evidencePath == nil:
                evidencePath = value
            case "--source-commit" where sourceCommit == nil:
                sourceCommit = value
            case "--timeout-seconds" where !didSetTimeout:
                guard let parsed = Int(value), (1...60).contains(parsed) else {
                    throw CodexCompatibilitySmokeUsageError.invalidArguments
                }
                timeoutSeconds = parsed
                didSetTimeout = true
            default:
                throw CodexCompatibilitySmokeUsageError.invalidArguments
            }
            index += 2
        }

        guard let codexPath, codexPath.hasPrefix("/"),
              let evidencePath, evidencePath.hasPrefix("/"),
              let sourceCommit, isCommit(sourceCommit)
        else { throw CodexCompatibilitySmokeUsageError.invalidArguments }

        let codex: ValidatedCodexExecutable
        do {
            codex = try ValidatedCodexExecutable(URL(fileURLWithPath: codexPath))
        } catch {
            throw CodexCompatibilitySmokeUsageError.invalidArguments
        }

        let evidenceDirectory = URL(fileURLWithPath: evidencePath, isDirectory: true).standardizedFileURL
        let normalHome = normalCodexHome.standardizedFileURL
        guard evidenceDirectory != normalHome,
              !evidenceDirectory.path.hasPrefix(normalHome.path + "/"),
              isOwnedDirectory(evidenceDirectory)
        else { throw CodexCompatibilitySmokeUsageError.invalidArguments }

        return CodexCompatibilitySmokeOptions(
            codex: codex,
            evidenceDirectory: evidenceDirectory,
            sourceCommit: sourceCommit,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func run(
        _ options: CodexCompatibilitySmokeOptions,
        now: Date = Date()
    ) async -> Int32 {
        let workspace: IsolatedCodexWorkspace
        do {
            workspace = try IsolatedCodexWorkspace.create()
        } catch {
            FileHandle.standardError.write(Data("failed to create isolated workspace\n".utf8))
            return 3
        }
        defer { workspace.close() }

        let result = await CodexCompatibilityProbe(
            executable: options.codex,
            workspace: workspace,
            timeout: .seconds(options.timeoutSeconds)
        ).run()
        let version: String?
        let resultCode: String
        let exitCode: Int32
        switch result {
        case let .passed(observedVersion):
            version = observedVersion
            resultCode = "PASS"
            exitCode = 0
        case let .failed(observedVersion, reason):
            version = observedVersion
            resultCode = reason.rawValue
            exitCode = 2
        }

        let evidence = CodexCompatibilityEvidence(
            observedAt: now,
            sourceCommit: options.sourceCommit,
            codexVersion: version,
            result: resultCode
        )
        let evidenceURL: URL
        do {
            evidenceURL = try CodexCompatibilityEvidenceWriter().writeUnique(
                evidence,
                to: options.evidenceDirectory
            )
        } catch {
            FileHandle.standardError.write(Data("failed to write compatibility evidence\n".utf8))
            return 3
        }

        print("label=unverified")
        print("code=\(resultCode)")
        if let version { print("version=\(sanitize(version))") }
        print("evidence=\(evidenceURL.lastPathComponent)")
        return exitCode
    }

    public static let usage = "usage: codex-compatibility-smoke --codex /absolute/path --evidence-directory /absolute/existing/directory --source-commit <40-lowercase-hex> [--timeout-seconds 1...60]"

    private static func isCommit(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == geteuid()
    }

    private static func sanitize(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "?" : String(scalar)
        }.joined()
    }
}
