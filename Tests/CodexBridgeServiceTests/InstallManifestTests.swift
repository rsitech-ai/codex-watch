import Foundation
import Testing

@Suite(.serialized)
struct InstallManifestTests {
@Test func launchAgentTemplateAndThinWrappersContainNoLifecycleImplementation() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifest = try String(
        contentsOf: repositoryRoot.appending(path: "Bridge/ai.rsitech.codexwatch.bridge.plist"),
        encoding: .utf8
    )
    let installer = try String(
        contentsOf: repositoryRoot.appending(path: "Scripts/install-bridge.sh"),
        encoding: .utf8
    )
    let uninstaller = try String(
        contentsOf: repositoryRoot.appending(path: "Scripts/uninstall-bridge.sh"),
        encoding: .utf8
    )

    for forbidden in ["identity-p12", "identity-password-file", "__IDENTITY_P12__", "__IDENTITY_PASSWORD_FILE__"] {
        #expect(!manifest.contains(forbidden))
        #expect(!installer.contains(forbidden))
        #expect(!uninstaller.contains(forbidden))
    }
    for forbidden in ["launchctl", "PlistBuddy", "ditto", "cp ", "sed ", "rm -rf"] {
        #expect(!installer.contains(forbidden))
        #expect(!uninstaller.contains(forbidden))
    }
    #expect(installer.contains("exec"))
    #expect(installer.contains("install"))
    #expect(uninstaller.contains("exec"))
    #expect(uninstaller.contains("uninstall"))
}

@Test func sourceMetadataDeclaresLocalNetworkBonjourAndExactLaunchAgentPolicy() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let info = try #require(NSDictionary(
        contentsOf: repositoryRoot.appending(path: "Bridge/Info.plist")
    ) as? [String: Any])
    let manifest = try #require(NSDictionary(
        contentsOf: repositoryRoot.appending(path: "Bridge/ai.rsitech.codexwatch.bridge.plist")
    ) as? [String: Any])

    #expect(info["NSLocalNetworkUsageDescription"] as? String == "Codex Watch receives voice ideas from your paired Apple Watch on your local network.")
    #expect(info["NSBonjourServices"] as? [String] == ["_codexwatch._tcp"])
    #expect(info["LSBackgroundOnly"] as? Bool == false)
    #expect(info["LSMinimumSystemVersion"] as? String == "15.0")
    #expect(info["NSMainNibFile"] == nil)
    #expect(info["NSMainStoryboardFile"] == nil)
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(FileManager.default.fileExists(
        atPath: repositoryRoot.appending(path: "Bridge/AppIcon.icns").path
    ))
    #expect(manifest["RunAtLoad"] as? Bool == true)
    #expect((manifest["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
    #expect(manifest["ThrottleInterval"] as? Int == 10)
    #expect(manifest["ProcessType"] as? String == "Background")
    #expect(manifest["AssociatedBundleIdentifiers"] as? [String] == ["ai.rsitech.codexwatch.bridge"])
}

@Test func buildProducesInteractiveBundleWithoutNibOrStoryboardSurfaces() throws {
    let fixture = try InstallFixture()
    try fixture.run("Scripts/build-bridge-app.sh", "--output", fixture.buildRoot.path)

    let app = fixture.buildRoot.appending(path: "CodexWatch.app", directoryHint: .isDirectory)
    let infoURL = app.appending(path: "Contents/Info.plist")
    let info = try #require(NSDictionary(contentsOf: infoURL) as? [String: Any])

    #expect(info["LSBackgroundOnly"] as? Bool == false)
    #expect(!(info["NSSpeechRecognitionUsageDescription"] as? String ?? "").isEmpty)
    #expect(info["NSMainNibFile"] == nil)
    #expect(info["NSMainStoryboardFile"] == nil)
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/MacOS/codex-watch-bridge").path))
    #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path))
}

@Test func buildProducesStrictlyVerifiableAdHocSignedBundle() throws {
    let fixture = try InstallFixture()
    try fixture.run("Scripts/build-bridge-app.sh", "--output", fixture.buildRoot.path)

    let app = fixture.buildRoot.appending(path: "CodexWatch.app", directoryHint: .isDirectory)
    try fixture.runExecutable("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
}

@Test func installFixtureRemovesItsOwnedTemporaryRootOnDeinit() throws {
    let root: URL
    do {
        let fixture = try InstallFixture()
        root = fixture.root
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
}
}

private final class InstallFixture {
    let repositoryRoot: URL
    let root: URL
    let buildRoot: URL

    init() throws {
        repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-install-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        buildRoot = root.appending(path: "build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(_ relativeScript: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [repositoryRoot.appending(path: relativeScript).path] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallTestError.commandFailed(output)
        }
    }

    func runExecutable(_ executable: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallTestError.commandFailed(output)
        }
    }

}

private enum InstallTestError: Error {
    case commandFailed(String)
}
