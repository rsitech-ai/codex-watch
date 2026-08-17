@testable import CodexBridgeService
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct BridgeServiceInstallerTests {
    @Test func productionPathsAreExactAndFixturePathsNeverUseTheRealLaunchAgentsDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "bridge-installer-home-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let paths = try BridgeInstallPaths.production(home: home)

        #expect(paths.application.path == home.path + "/Library/Application Support/VoiceInboxBridge/Service/VoiceInboxBridge.app")
        #expect(paths.state.path == home.path + "/Library/Application Support/VoiceInboxBridge/State")
        #expect(paths.launchAgent.path == home.path + "/Library/LaunchAgents/ai.rsitech.voiceinbox.bridge.plist")
        #expect(paths.launchAgent.path != FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/ai.rsitech.voiceinbox.bridge.plist")
    }

    @Test func firstInstallCreatesPrivateDirectoriesAndExactLaunchAgentMetadata() async throws {
        let fixture = try InstallerFixture()
        let bundle = try fixture.makeBundle(version: "one")

        try await fixture.installer.install(
            bundle: bundle,
            codexExecutable: fixture.codexExecutable,
            bindHost: "127.0.0.1",
            advertisedHost: "bridge.local"
        )

        #expect(try mode(of: fixture.paths.application.deletingLastPathComponent()) == 0o700)
        #expect(try mode(of: fixture.paths.state) == 0o700)
        #expect(try mode(of: fixture.paths.launchAgent.deletingLastPathComponent()) == 0o700)
        #expect(try mode(of: fixture.paths.launchAgent) == 0o600)
        let manifest = try fixture.launchAgentDictionary()
        #expect(manifest["Label"] as? String == "ai.rsitech.voiceinbox.bridge")
        #expect(manifest["RunAtLoad"] as? Bool == true)
        #expect((manifest["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(manifest["ThrottleInterval"] as? Int == 10)
        #expect(manifest["ProcessType"] as? String == "Background")
        #expect(manifest["AssociatedBundleIdentifiers"] as? [String] == ["ai.rsitech.voiceinbox.bridge"])
        #expect(manifest["ProgramArguments"] as? [String] == [
            fixture.paths.application.appending(path: "Contents/MacOS/codex-watch-bridge").path,
            "run", "--state-root", fixture.paths.state.path,
            "--codex", fixture.codexExecutable.path,
            "--bind-host", "127.0.0.1",
            "--advertised-host", "bridge.local",
        ])
        let verified = await fixture.signatureVerifier.verifiedBundles()
        #expect(verified.count == 1)
        #expect(verified.first?.deletingLastPathComponent() == fixture.paths.application.deletingLastPathComponent())
        #expect(verified.first?.lastPathComponent.hasPrefix(".VoiceInboxBridge.app.staged-") == true)
        #expect(await fixture.launchctl.events() == [
            "print:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootstrap:gui/\(getuid()):\(fixture.paths.launchAgent.path)",
        ])
    }

    @Test func installPreservesExistingSharedLaunchAgentsPermissions() async throws {
        let fixture = try InstallerFixture()
        let launchAgents = fixture.paths.launchAgent.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: launchAgents.path
        )

        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))

        #expect(try mode(of: launchAgents) == 0o755)
        #expect(try mode(of: fixture.paths.application.deletingLastPathComponent()) == 0o700)
        #expect(try mode(of: fixture.paths.state) == 0o700)
    }

    @Test func installRejectsGroupOrWorldWritableSharedLaunchAgentsDirectory() async throws {
        let fixture = try InstallerFixture()
        let launchAgents = fixture.paths.launchAgent.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: launchAgents.path
        )

        await #expect(throws: BridgeServiceInstallerError.unsafeExistingObject) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        }

        #expect(try mode(of: launchAgents) == 0o777)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
    }

    @Test func statusRejectsGroupOrWorldWritableSharedLaunchAgentsDirectory() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.launchctl.clearEvents()
        try fixture.makeLaunchAgentsGroupOrWorldWritable()

        await #expect(throws: BridgeServiceInstallerError.unsafeExistingObject) {
            _ = try await fixture.installer.status()
        }

        #expect(await fixture.launchctl.events().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
    }

    @Test func uninstallRejectsGroupOrWorldWritableSharedLaunchAgentsDirectory() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.launchctl.clearEvents()
        try fixture.makeLaunchAgentsGroupOrWorldWritable()

        await #expect(throws: BridgeServiceInstallerError.unsafeExistingObject) {
            try await fixture.installer.uninstall(purgeData: false)
        }

        #expect(await fixture.launchctl.events().isEmpty)
        #expect(await fixture.launchctl.isLoaded())
        #expect(FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
    }

    @Test func rotationRejectsGroupOrWorldWritableSharedLaunchAgentsDirectory() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let fingerprint = try #require(await fixture.identityLifecycle.existingFingerprint())
        await fixture.launchctl.clearEvents()
        try fixture.makeLaunchAgentsGroupOrWorldWritable()

        await #expect(throws: BridgeServiceInstallerError.unsafeExistingObject) {
            _ = try await fixture.installer.rotateIdentity()
        }

        #expect(await fixture.launchctl.events().isEmpty)
        #expect(await fixture.launchctl.isLoaded())
        #expect(await fixture.identityLifecycle.existingFingerprint() == fingerprint)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
    }

    @Test func lifecycleLeaseRejectsConcurrentInstallerAndExternalProcess() async throws {
        let fixture = try InstallerFixture()
        let root = fixture.paths.state.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = BridgeInstallerLifecycleLease(root: root)
        let contender = BridgeInstallerLifecycleLease(root: root)
        try first.acquire()
        #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            try contender.acquire()
        }
        first.release()
        try contender.acquire()
        contender.release()

        let lock = root.appending(path: ".codex-watch-bridge.lifecycle.lock")
        let ready = fixture.root.appending(path: "external-lock-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "open(my $f, '+<', $ARGV[0]) or die; flock($f, 2) or die; open(my $r, '>', $ARGV[1]) or die; close($r); select(undef,undef,undef,0.4);",
            lock.path,
            ready.path,
        ]
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        let externalContender = BridgeInstallerLifecycleLease(root: root)
        #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            try externalContender.acquire()
        }
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if process.isRunning { process.terminate() }
        #expect(!process.isRunning)
        try externalContender.acquire()
        externalContender.release()
    }

    @Test func twoInstallerInstancesCannotOverlapOneLifecycleTransaction() async throws {
        let gate = BlockingInstallerHealth()
        let fixture = try InstallerFixture(healthCheck: { await gate.probe() })
        let contender = BridgeServiceInstaller(
            paths: fixture.paths,
            launchctl: fixture.launchctl,
            signatureVerifier: fixture.signatureVerifier,
            identityLifecycle: fixture.identityLifecycle,
            healthCheck: { true },
            healthTimeout: .milliseconds(100),
            healthPollInterval: .milliseconds(5),
            revokePairing: {}
        )
        let install = Task {
            try await fixture.install(bundle: fixture.makeBundle(version: "one"))
        }
        await gate.waitUntilEntered()

        await #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            _ = try await contender.status()
        }
        await gate.release()
        try await install.value
    }

    @Test func firstInstallSerializesStatusUninstallAndRotationBeforeBridgeRootExists() async throws {
        let gate = BlockingLifecycleHook()
        let fixture = try InstallerFixture(afterLifecycleLeaseAcquired: { await gate.enter() })
        let bridgeRoot = fixture.paths.state.deletingLastPathComponent()
        let bundle = try fixture.makeBundle(version: "one")
        let contender = BridgeServiceInstaller(
            paths: fixture.paths,
            launchctl: fixture.launchctl,
            signatureVerifier: fixture.signatureVerifier,
            identityLifecycle: fixture.identityLifecycle,
            healthCheck: { true },
            healthTimeout: .milliseconds(100),
            healthPollInterval: .milliseconds(5),
            revokePairing: {}
        )
        #expect(!FileManager.default.fileExists(atPath: bridgeRoot.path))
        let install = Task { try await fixture.install(bundle: bundle) }
        await gate.waitUntilEntered()
        #expect(!FileManager.default.fileExists(atPath: bridgeRoot.path))

        await #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            _ = try await contender.status()
        }
        await #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            try await contender.uninstall(purgeData: false)
        }
        await #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            _ = try await contender.rotateIdentity()
        }

        await gate.release()
        try await install.value
    }

    @Test func installRejectsWrongBundleIdentifierBeforeSignatureOrSwap() async throws {
        let fixture = try InstallerFixture()
        let bundle = try fixture.makeBundle(version: "wrong-id", identifier: "example.invalid")

        await #expect(throws: BridgeServiceInstallerError.self) {
            try await fixture.installer.install(
                bundle: bundle,
                codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
                bindHost: "127.0.0.1",
                advertisedHost: "bridge.local"
            )
        }
        #expect(!(await fixture.signatureVerifier.wasCalled()))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
    }

    @Test func installRejectsMissingExpectedExecutable() async throws {
        let fixture = try InstallerFixture()
        let missingExecutable = try fixture.makeBundle(version: "missing", executable: "different")
        await #expect(throws: BridgeServiceInstallerError.self) {
            try await fixture.install(bundle: missingExecutable)
        }
        #expect(!(await fixture.signatureVerifier.wasCalled()))
    }

    @Test func strictSignatureFailureLeavesInstallDestinationsUntouched() async throws {
        let fixture = try InstallerFixture()
        let bundle = try fixture.makeBundle(version: "unsigned")
        await fixture.signatureVerifier.failNextVerification()

        await #expect(throws: BridgeServiceInstallerError.self) {
            try await fixture.install(bundle: bundle)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
        #expect(await fixture.launchctl.events().isEmpty)
    }

    @Test func updatePreservesStateAndIdentityWhileReplacingTheBundle() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let marker = fixture.paths.state.appending(path: "preserve-me")
        try Data("state".utf8).write(to: marker)
        let firstIdentity = await fixture.identityLifecycle.ensureFingerprint()

        try await fixture.install(bundle: try fixture.makeBundle(version: "two"))

        #expect(try Data(contentsOf: marker) == Data("state".utf8))
        #expect(try fixture.installedExecutableContents() == "two")
        #expect(await fixture.identityLifecycle.ensureFingerprint() == firstIdentity)
        #expect(await fixture.identityLifecycle.creationCount == 1)
    }

    @Test func reinstallReusesPersistedFingerprintWhenKeychainIdentityIsUnreadable() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let firstIdentity = try #require(await fixture.identityLifecycle.existingFingerprint())
        let service = fixture.paths.state.appending(path: "service", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: service,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let p12 = service.appending(path: PersistedTLSIdentity.p12FileName)
        let password = service.appending(path: PersistedTLSIdentity.passwordFileName)
        try Data("p12".utf8).write(to: p12)
        try Data("password".utf8).write(to: password)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: p12.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: password.path
        )
        await fixture.identityLifecycle.loseKeychainAccess()

        try await fixture.install(bundle: try fixture.makeBundle(version: "two"))

        #expect(try fixture.installedExecutableContents() == "two")
        #expect(try String(contentsOf: fixture.fingerprint, encoding: .utf8) == firstIdentity)
        #expect(await fixture.identityLifecycle.creationCount == 1)
        #expect(await fixture.identityLifecycle.existingFingerprint() == nil)
    }

    @Test func failedBootstrapRestoresAndRebootstrapsThePriorInstall() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let oldManifest = try Data(contentsOf: fixture.paths.launchAgent)
        try Data(String(repeating: "b", count: 64).utf8).write(to: fixture.fingerprint)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fixture.fingerprint.path
        )
        let oldFingerprint = try Data(contentsOf: fixture.fingerprint)
        await fixture.launchctl.failNextBootstrap()

        await #expect(throws: BridgeServiceInstallerError.self) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "two"))
        }

        #expect(try fixture.installedExecutableContents() == "one")
        #expect(try Data(contentsOf: fixture.paths.launchAgent) == oldManifest)
        #expect(try Data(contentsOf: fixture.fingerprint) == oldFingerprint)
        #expect(await fixture.launchctl.isLoaded())
        let events = await fixture.launchctl.events()
        #expect(events.suffix(4) == [
            "bootout:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootstrap:gui/\(getuid()):\(fixture.paths.launchAgent.path)",
            "bootout:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootstrap:gui/\(getuid()):\(fixture.paths.launchAgent.path)",
        ])
    }

    @Test func bootoutNotLoadedRaceIsIdempotentForUpdateUninstallAndRotation() async throws {
        let update = try InstallerFixture()
        try await update.install(bundle: try update.makeBundle(version: "one"))
        await update.launchctl.raceNextBootoutToNotLoaded()
        try await update.install(bundle: try update.makeBundle(version: "two"))
        #expect(try update.installedExecutableContents() == "two")

        let uninstall = try InstallerFixture()
        try await uninstall.install(bundle: try uninstall.makeBundle(version: "one"))
        await uninstall.launchctl.raceNextBootoutToNotLoaded()
        try await uninstall.installer.uninstall(purgeData: false)
        #expect(!FileManager.default.fileExists(atPath: uninstall.paths.application.path))

        let rotation = try InstallerFixture()
        try await rotation.install(bundle: try rotation.makeBundle(version: "one"))
        let before = await rotation.identityLifecycle.existingFingerprint()
        await rotation.launchctl.raceNextBootoutToNotLoaded()
        let after = try await rotation.installer.rotateIdentity()
        #expect(after != before)
        #expect(await rotation.launchctl.isLoaded())
    }

    @Test func uninstallOfInstalledButUnloadedServiceSkipsBootout() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.launchctl.setLoaded(false)
        await fixture.launchctl.clearEvents()

        try await fixture.installer.uninstall(purgeData: false)

        #expect(await fixture.launchctl.events() == [
            "print:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
        ])
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
    }

    @Test func realLaunchctlProbeFailureIsNotMisreportedAsUnloaded() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.launchctl.failNextPrint(with: .launchFailed)

        await #expect(throws: BridgeServiceInstallerError.launchctlFailed) {
            _ = try await fixture.installer.status()
        }
    }

    @Test func exactChildSurvivorDiagnosticIsPreservedAcrossProbeAndBootout() async throws {
        let probe = try InstallerFixture()
        try await probe.install(bundle: try probe.makeBundle(version: "one"))
        await probe.launchctl.failNextPrint(with: .childStillRunning(pid: 4321, killResult: EPERM))
        do {
            _ = try await probe.installer.status()
            Issue.record("expected exact probe survivor")
        } catch let BridgeServiceInstallerError.childStillRunning(pid, killResult) {
            #expect(pid == 4321)
            #expect(killResult == EPERM)
        }

        let bootout = try InstallerFixture()
        try await bootout.install(bundle: try bootout.makeBundle(version: "one"))
        await bootout.launchctl.failNextBootout(
            with: .childStillRunning(pid: 5678, killResult: EBUSY)
        )
        do {
            try await bootout.installer.uninstall(purgeData: false)
            Issue.record("expected exact bootout survivor")
        } catch let BridgeServiceInstallerError.childStillRunning(pid, killResult) {
            #expect(pid == 5678)
            #expect(killResult == EBUSY)
        }
    }

    @Test func statusRejectsMalformedInstalledBundleAndIdentityBearingManifest() async throws {
        let malformedBundle = try InstallerFixture()
        try await malformedBundle.install(bundle: try malformedBundle.makeBundle(version: "one"))
        let infoURL = malformedBundle.paths.application.appending(path: "Contents/Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil
        ) as? [String: Any])
        info["CFBundleIdentifier"] = "invalid.example"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: infoURL)
        await #expect(throws: BridgeServiceInstallerError.invalidBundle) {
            _ = try await malformedBundle.installer.status()
        }

        let malformedManifest = try InstallerFixture()
        try await malformedManifest.install(bundle: try malformedManifest.makeBundle(version: "one"))
        var manifest = try malformedManifest.launchAgentDictionary()
        var arguments = try #require(manifest["ProgramArguments"] as? [String])
        arguments.append(contentsOf: ["--tls-pkcs12", "/tmp/identity.p12"])
        manifest["ProgramArguments"] = arguments
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: malformedManifest.paths.launchAgent)
        await #expect(throws: BridgeServiceInstallerError.invalidConfiguration) {
            _ = try await malformedManifest.installer.status()
        }
    }

    @Test func statusRejectsInstalledManifestWithoutRequiredThrottleAndProcessType() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        var manifest = try fixture.launchAgentDictionary()
        manifest["ThrottleInterval"] = 9
        manifest["ProcessType"] = "Interactive"
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: fixture.paths.launchAgent)

        await #expect(throws: BridgeServiceInstallerError.invalidConfiguration) {
            _ = try await fixture.installer.status()
        }
    }

    @Test func statusRejectsInstalledManifestUnlessModeIsExactlyOwnerOnly() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fixture.paths.launchAgent.path
        )

        await #expect(throws: BridgeServiceInstallerError.unsafeExistingObject) {
            _ = try await fixture.installer.status()
        }
    }

    @Test func statusRejectsCodexArgumentThatIsNotOwnedRegularAndSingleLink() async throws {
        let wrongOwner = try InstallerFixture()
        try await wrongOwner.install(bundle: try wrongOwner.makeBundle(version: "one"))
        var wrongOwnerManifest = try wrongOwner.launchAgentDictionary()
        var wrongOwnerArguments = try #require(
            wrongOwnerManifest["ProgramArguments"] as? [String]
        )
        wrongOwnerArguments[5] = "/usr/bin/true"
        wrongOwnerManifest["ProgramArguments"] = wrongOwnerArguments
        try PropertyListSerialization.data(
            fromPropertyList: wrongOwnerManifest, format: .xml, options: 0
        ).write(to: wrongOwner.paths.launchAgent)
        await #expect(throws: BridgeServiceInstallerError.invalidConfiguration) {
            _ = try await wrongOwner.installer.status()
        }

        let multiplyLinked = try InstallerFixture()
        try await multiplyLinked.install(bundle: try multiplyLinked.makeBundle(version: "one"))
        let secondLink = multiplyLinked.codexExecutable
            .deletingLastPathComponent().appending(path: "codex-second-link")
        try FileManager.default.linkItem(at: multiplyLinked.codexExecutable, to: secondLink)

        await #expect(throws: BridgeServiceInstallerError.invalidConfiguration) {
            _ = try await multiplyLinked.installer.status()
        }
    }

    @Test func uninstallRepairsAValidatedPartialPriorUninstall() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        try FileManager.default.removeItem(at: fixture.paths.launchAgent)

        try await fixture.installer.uninstall(purgeData: false)

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
    }

    @Test func rollbackFailsClosedWhenNewServiceCannotBeBootedOut() async throws {
        let fixture = try InstallerFixture(healthTimeout: .milliseconds(200))
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.health.setHealthy(false)
        await fixture.launchctl.failBootout(onCall: 2)

        await #expect(throws: BridgeServiceInstallerError.rollbackFailed) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "two"))
        }

        #expect(await fixture.launchctl.isLoaded())
        #expect(try fixture.installedExecutableContents() == "two")
    }

    @Test func failedBoundedHealthCheckRestoresPriorAppAndManifest() async throws {
        let fixture = try InstallerFixture(healthTimeout: .milliseconds(200))
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let oldManifest = try Data(contentsOf: fixture.paths.launchAgent)
        await fixture.health.setPredicate {
            (try? fixture.installedExecutableContents()) == "one"
        }

        let started = ContinuousClock.now
        await #expect(throws: BridgeServiceInstallerError.healthCheckFailed) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "two"))
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(try fixture.installedExecutableContents() == "one")
        #expect(try Data(contentsOf: fixture.paths.launchAgent) == oldManifest)
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func installBootstrapSurvivorPreservesTypedDiagnosticWithoutCompensation() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.launchctl.clearEvents()
        await fixture.launchctl.failNextBootstrap(
            with: .childStillRunning(pid: 6123, killResult: EPERM)
        )

        do {
            try await fixture.install(bundle: try fixture.makeBundle(version: "two"))
            Issue.record("expected exact bootstrap survivor")
        } catch let BridgeServiceInstallerError.childStillRunning(pid, killResult) {
            #expect(pid == 6123)
            #expect(killResult == EPERM)
        } catch {
            Issue.record("expected exact bootstrap survivor, got \(error)")
        }

        #expect(try fixture.installedExecutableContents() == "two")
        #expect(try fixture.backupExecutableContents() == ["one"])
        #expect(try fixture.installerBackupManifestCount() == 1)
        #expect(try fixture.installerBackupFingerprintCount() == 1)
        #expect(!(await fixture.launchctl.isLoaded()))
        #expect(await fixture.launchctl.events() == [
            "print:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootout:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootstrap:gui/\(getuid()):\(fixture.paths.launchAgent.path)",
        ])
    }

    @Test func rollbackRestorationHealthFailureSurfacesRollbackFailed() async throws {
        let fixture = try InstallerFixture(healthTimeout: .milliseconds(200))
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.health.setHealthy(false)

        await #expect(throws: BridgeServiceInstallerError.rollbackFailed) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "two"))
        }

        #expect(try fixture.installedExecutableContents() == "one")
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func postHealthBackupCleanupFailureKeepsTheHealthyNewInstallCommitted() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let serviceDirectory = fixture.paths.application.deletingLastPathComponent()
        await fixture.health.runOnNextProbe {
            guard chmod(serviceDirectory.path, 0o500) == 0 else {
                throw InstallerFakeError.injected
            }
        }
        defer { _ = chmod(serviceDirectory.path, 0o700) }

        try await fixture.install(bundle: try fixture.makeBundle(version: "two"))

        #expect(try fixture.installedExecutableContents() == "two")
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func injectedPostHealthCleanupFailureCannotRollBackCommittedInstall() async throws {
        let fileSystem = FailingRemoveFileSystem(fragment: ".backup-")
        let fixture = try InstallerFixture(fileSystem: fileSystem)
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))

        try await fixture.install(bundle: try fixture.makeBundle(version: "two"))

        #expect(try fixture.installedExecutableContents() == "two")
        #expect(fileSystem.failureCount > 0)
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func oneSlowHealthProbeCannotExceedTheInstallerHealthDeadline() async throws {
        let fixture = try InstallerFixture(
            healthTimeout: .milliseconds(100),
            healthCheck: {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
        )
        let started = ContinuousClock.now

        await #expect(throws: BridgeServiceInstallerError.healthCheckFailed) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "slow-health"))
        }

        #expect(ContinuousClock.now - started < .milliseconds(1_500))
    }

    @Test func statusHealthProbeIsBoundedByTheInstallerDeadline() async throws {
        let fixture = try InstallerFixture(healthTimeout: .milliseconds(100))
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        await fixture.health.delayNextProbe(.seconds(2))
        let started = ContinuousClock.now

        let status = try await fixture.installer.status()

        #expect(!status.healthy)
        #expect(ContinuousClock.now - started < .milliseconds(1_500))
    }

    @Test func uninstallBootsOutBeforeRemovalAndPreservesStateByDefault() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let marker = fixture.paths.state.appending(path: "memo-state")
        try Data("keep".utf8).write(to: marker)
        await fixture.launchctl.observeBootout {
            #expect(FileManager.default.fileExists(atPath: fixture.paths.application.path))
            #expect(FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
        }

        try await fixture.installer.uninstall(purgeData: false)

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test func uninstallStagingFailureRestoresExactArtifactsAndPriorService() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let originalManifest = try Data(contentsOf: fixture.paths.launchAgent)
        let launchAgents = fixture.paths.launchAgent.deletingLastPathComponent()
        await fixture.launchctl.observeBootout {
            _ = chmod(launchAgents.path, 0o500)
        }
        defer { _ = chmod(launchAgents.path, 0o755) }

        await #expect(throws: BridgeServiceInstallerError.transactionFailed) {
            try await fixture.installer.uninstall(purgeData: false)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(try Data(contentsOf: fixture.paths.launchAgent) == originalManifest)
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func uninstallCleanupFailureLeavesExactPathsAbsentAndRepairIsIdempotent() async throws {
        let fileSystem = FailingRemoveFileSystem(fragment: ".uninstall-")
        let fixture = try InstallerFixture(fileSystem: fileSystem)
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))

        try await fixture.installer.uninstall(purgeData: false)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
        #expect(fileSystem.failureCount > 0)

        try await fixture.installer.uninstall(purgeData: false)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.application.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.launchAgent.path))
    }

    @Test func explicitPurgeRemovesOnlyOwnedStateRootAfterBootout() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let sibling = fixture.paths.state.deletingLastPathComponent().appending(path: "not-owned")
        try Data("keep".utf8).write(to: sibling)
        await fixture.launchctl.observeBootout {
            #expect(FileManager.default.fileExists(atPath: fixture.paths.state.path))
        }

        try await fixture.installer.uninstall(purgeData: true)

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.state.path))
        #expect(try Data(contentsOf: sibling) == Data("keep".utf8))
    }

    @Test func symlinkEscapeAndUnexpectedExistingObjectFailClosed() async throws {
        let fixture = try InstallerFixture()
        let escapedRoot = fixture.root.appending(path: "escaped", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        let link = fixture.home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: escapedRoot)

        await #expect(throws: BridgeServiceInstallerError.self) {
            try await fixture.install(bundle: try fixture.makeBundle(version: "escape"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: escapedRoot.path).isEmpty)

        let other = try InstallerFixture()
        try FileManager.default.createDirectory(
            at: other.paths.application.deletingLastPathComponent().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unexpected".utf8).write(
            to: other.paths.application.deletingLastPathComponent()
        )
        await #expect(throws: BridgeServiceInstallerError.self) {
            try await other.install(bundle: try other.makeBundle(version: "unexpected"))
        }
    }

    @Test func statusIsContentFreeAndRotateStopsRevokesRotatesThenRestarts() async throws {
        let events = LockedInstallerEvents()
        let fixture = try InstallerFixture(sharedEvents: events)
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let before = await fixture.identityLifecycle.ensureFingerprint()
        await events.clear()

        let status = try await fixture.installer.status()
        #expect(status.installed)
        #expect(status.serviceLoaded)
        #expect(status.healthy)
        #expect(status.publicKeySHA256 == before)

        await fixture.health.resetCallCount()
        let serviceState = fixture.paths.state.appending(path: "service", directoryHint: .isDirectory)
        await fixture.launchctl.observeBootstrap {
            #expect(!BridgeServiceLease.isLive(stateDirectory: serviceState))
        }
        let rotated = try await fixture.installer.rotateIdentity()
        #expect(rotated != before)
        #expect(await events.snapshot() == ["bootout", "revoke", "rotate", "bootstrap"])
        #expect(await fixture.launchctl.isLoaded())
        #expect(await fixture.health.callCount() > 0)
    }

    @Test func failedRotatedServiceBootstrapRestoresExactPriorIdentityAndService() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let before = try #require(await fixture.identityLifecycle.existingFingerprint())
        await fixture.launchctl.failNextBootstrap()

        await #expect(throws: BridgeServiceInstallerError.launchctlFailed) {
            _ = try await fixture.installer.rotateIdentity()
        }

        #expect(await fixture.identityLifecycle.existingFingerprint() == before)
        #expect(await fixture.launchctl.isLoaded())
    }

    @Test func rotationBootstrapSurvivorPreservesTypedDiagnosticWithoutCompensation() async throws {
        let fixture = try InstallerFixture()
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let priorFingerprint = try #require(await fixture.identityLifecycle.existingFingerprint())
        let priorApplication = try Data(contentsOf: fixture.paths.application
            .appending(path: "Contents/MacOS/codex-watch-bridge"))
        let priorManifest = try Data(contentsOf: fixture.paths.launchAgent)
        await fixture.launchctl.clearEvents()
        await fixture.launchctl.failNextBootstrap(
            with: .childStillRunning(pid: 6456, killResult: EBUSY)
        )

        do {
            _ = try await fixture.installer.rotateIdentity()
            Issue.record("expected exact rotation bootstrap survivor")
        } catch let BridgeServiceInstallerError.childStillRunning(pid, killResult) {
            #expect(pid == 6456)
            #expect(killResult == EBUSY)
        } catch {
            Issue.record("expected exact rotation bootstrap survivor, got \(error)")
        }

        let activeFingerprint = try #require(
            await fixture.identityLifecycle.existingFingerprint()
        )
        #expect(activeFingerprint != priorFingerprint)
        #expect(try String(contentsOf: fixture.fingerprint, encoding: .utf8) == activeFingerprint)
        #expect(try Data(contentsOf: fixture.paths.application
            .appending(path: "Contents/MacOS/codex-watch-bridge")) == priorApplication)
        #expect(try Data(contentsOf: fixture.paths.launchAgent) == priorManifest)
        #expect(!(await fixture.launchctl.isLoaded()))
        #expect(await fixture.launchctl.events() == [
            "print:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootout:gui/\(getuid())/ai.rsitech.voiceinbox.bridge",
            "bootstrap:gui/\(getuid()):\(fixture.paths.launchAgent.path)",
        ])
    }

    @Test func failedRotatedServiceHealthRestoresPriorIdentityThenProvesRecoveryHealth() async throws {
        let fixture = try InstallerFixture(healthTimeout: .milliseconds(500))
        try await fixture.install(bundle: try fixture.makeBundle(version: "one"))
        let before = try #require(await fixture.identityLifecycle.existingFingerprint())
        await fixture.health.setPredicate {
            await fixture.identityLifecycle.existingFingerprint() == before
        }

        await #expect(throws: BridgeServiceInstallerError.healthCheckFailed) {
            _ = try await fixture.installer.rotateIdentity()
        }

        #expect(await fixture.identityLifecycle.existingFingerprint() == before)
        #expect(await fixture.launchctl.isLoaded())
    }
}

private final class InstallerFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let paths: BridgeInstallPaths
    let codexExecutable: URL
    let launchctl: FakeInstallerLaunchctl
    let signatureVerifier = FakeBundleSignatureVerifier()
    let health = FakeInstallerHealth()
    let identityLifecycle: DeterministicInstallerIdentityLifecycle
    let installer: BridgeServiceInstaller
    var fingerprint: URL { paths.state.appending(path: ".identity-public-key-sha256") }
    private var bundleCounter = 0

    init(
        healthTimeout: Duration = .milliseconds(100),
        sharedEvents: LockedInstallerEvents = LockedInstallerEvents(),
        healthCheck: (@Sendable () async throws -> Bool)? = nil,
        fileSystem: any BridgeInstallerFileSystemOperations = SystemBridgeInstallerFileSystem(),
        afterLifecycleLeaseAcquired: @escaping @Sendable () async -> Void = {}
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-installer-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = try BridgeInstallPaths.production(home: home)
        codexExecutable = root.appending(path: "bin/codex")
        try FileManager.default.createDirectory(
            at: codexExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture-codex".utf8).write(to: codexExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: codexExecutable.path
        )
        launchctl = FakeInstallerLaunchctl(events: sharedEvents)
        identityLifecycle = DeterministicInstallerIdentityLifecycle(events: sharedEvents)
        let serviceState = paths.state.appending(path: "service", directoryHint: .isDirectory)
        let installedHealthCheck = healthCheck ?? { [health] in try await health.isHealthy() }
        installer = BridgeServiceInstaller(
            paths: paths,
            launchctl: launchctl,
            signatureVerifier: signatureVerifier,
            identityLifecycle: identityLifecycle,
            healthCheck: installedHealthCheck,
            healthTimeout: healthTimeout,
            healthPollInterval: .milliseconds(5),
            revokePairing: {
                #expect(BridgeServiceLease.isLive(stateDirectory: serviceState))
                await sharedEvents.record("revoke")
            },
            fileSystem: fileSystem,
            afterLifecycleLeaseAcquired: afterLifecycleLeaseAcquired
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeBundle(
        version: String,
        identifier: String = "ai.rsitech.voiceinbox.bridge",
        executable: String = "codex-watch-bridge",
        backgroundOnly: Bool = true
    ) throws -> URL {
        bundleCounter += 1
        let bundle = root.appending(
            path: "bundles/\(bundleCounter)-VoiceInboxBridge.app",
            directoryHint: .isDirectory
        )
        let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "LSBackgroundOnly": backgroundOnly,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        let executableURL = macOS.appending(path: executable)
        try Data(version.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executableURL.path
        )
        return bundle
    }

    func install(bundle: URL) async throws {
        try await installer.install(
            bundle: bundle,
            codexExecutable: codexExecutable,
            bindHost: "127.0.0.1",
            advertisedHost: "bridge.local"
        )
    }

    func launchAgentDictionary() throws -> [String: Any] {
        let data = try Data(contentsOf: paths.launchAgent)
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
    }

    func makeLaunchAgentsGroupOrWorldWritable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: paths.launchAgent.deletingLastPathComponent().path
        )
    }

    func installedExecutableContents() throws -> String {
        let executable = paths.application.appending(path: "Contents/MacOS/codex-watch-bridge")
        return String(decoding: try Data(contentsOf: executable), as: UTF8.self)
    }

    func backupExecutableContents() throws -> [String] {
        let service = paths.application.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(at: service, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".VoiceInboxBridge.app.backup-") }
            .map { backup in
                String(decoding: try Data(contentsOf: backup
                    .appending(path: "Contents/MacOS/codex-watch-bridge")), as: UTF8.self)
            }
            .sorted()
    }

    func installerBackupManifestCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: paths.launchAgent.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).count { $0.lastPathComponent.hasPrefix(
            ".ai.rsitech.voiceinbox.bridge.plist.backup-"
        ) }
    }

    func installerBackupFingerprintCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: paths.state,
            includingPropertiesForKeys: nil
        ).count { $0.lastPathComponent.hasPrefix(
            ".identity-public-key-sha256.backup-"
        ) }
    }
}

private enum InstallerFakeError: Error { case injected, notLoaded }

private actor FakeInstallerLaunchctl: LaunchctlControlling {
    private var loaded = false
    private var failBootstrap = false
    private var bootstrapFailure: LaunchctlClientError?
    private var recorded: [String] = []
    private var onBootout: (@Sendable () -> Void)?
    private var onBootstrap: (@Sendable () -> Void)?
    private var bootoutCalls = 0
    private var failBootoutCall: Int?
    private var raceBootoutToNotLoaded = false
    private var bootoutFailure: LaunchctlClientError?
    private var printFailure: LaunchctlClientError?
    private let sharedEvents: LockedInstallerEvents

    init(events: LockedInstallerEvents) { sharedEvents = events }

    func bootstrap(domain: String, plist: URL) async throws {
        recorded.append("bootstrap:\(domain):\(plist.path)")
        if let bootstrapFailure {
            self.bootstrapFailure = nil
            throw bootstrapFailure
        }
        if failBootstrap {
            failBootstrap = false
            throw InstallerFakeError.injected
        }
        onBootstrap?()
        loaded = true
        await sharedEvents.record("bootstrap")
    }

    func bootout(domain: String, label: String) async throws {
        recorded.append("bootout:\(domain)/\(label)")
        if let bootoutFailure {
            self.bootoutFailure = nil
            throw bootoutFailure
        }
        if raceBootoutToNotLoaded {
            raceBootoutToNotLoaded = false
            loaded = false
            throw LaunchctlClientError.serviceNotLoaded
        }
        bootoutCalls += 1
        if failBootoutCall == bootoutCalls { throw InstallerFakeError.injected }
        guard loaded else { throw LaunchctlClientError.serviceNotLoaded }
        onBootout?()
        loaded = false
        await sharedEvents.record("bootout")
    }

    func printService(domain: String, label: String) async throws -> String {
        recorded.append("print:\(domain)/\(label)")
        if let printFailure {
            self.printFailure = nil
            throw printFailure
        }
        guard loaded else { throw LaunchctlClientError.serviceNotLoaded }
        return "loaded"
    }

    func failNextBootstrap() { failBootstrap = true }
    func failNextBootstrap(with error: LaunchctlClientError) { bootstrapFailure = error }
    func events() -> [String] { recorded }
    func isLoaded() -> Bool { loaded }
    func observeBootout(_ operation: @escaping @Sendable () -> Void) { onBootout = operation }
    func observeBootstrap(_ operation: @escaping @Sendable () -> Void) { onBootstrap = operation }
    func setLoaded(_ value: Bool) { loaded = value }
    func clearEvents() { recorded.removeAll() }
    func failBootout(onCall call: Int) { failBootoutCall = call }
    func raceNextBootoutToNotLoaded() { raceBootoutToNotLoaded = true }
    func failNextBootout(with error: LaunchctlClientError) { bootoutFailure = error }
    func failNextPrint(with error: LaunchctlClientError) { printFailure = error }
}

private actor FakeBundleSignatureVerifier: BridgeBundleSignatureVerifying {
    private var verified: [URL] = []
    private var failNext = false

    func verifyStrictDeepSignature(of bundle: URL) async throws {
        verified.append(bundle.standardizedFileURL)
        if failNext {
            failNext = false
            throw InstallerFakeError.injected
        }
    }

    func failNextVerification() { failNext = true }
    func verifiedBundles() -> [URL] { verified }
    func wasCalled() -> Bool { !verified.isEmpty }
}

private actor FakeInstallerHealth {
    private var healthy = true
    private var calls = 0
    private var nextProbe: (@Sendable () throws -> Void)?
    private var nextDelay: Duration?
    private var queued: [Bool] = []
    private var predicate: (@Sendable () async -> Bool)?
    func setHealthy(_ value: Bool) { healthy = value }
    func runOnNextProbe(_ operation: @escaping @Sendable () throws -> Void) {
        nextProbe = operation
    }
    func delayNextProbe(_ delay: Duration) { nextDelay = delay }
    func enqueue(_ values: [Bool]) { queued.append(contentsOf: values) }
    func setPredicate(_ predicate: @escaping @Sendable () async -> Bool) {
        self.predicate = predicate
    }
    func isHealthy() async throws -> Bool {
        calls += 1
        let delay = nextDelay
        nextDelay = nil
        if let delay { try await Task.sleep(for: delay) }
        let operation = nextProbe
        nextProbe = nil
        try operation?()
        if !queued.isEmpty { return queued.removeFirst() }
        return await predicate?() ?? healthy
    }
    func resetCallCount() { calls = 0 }
    func callCount() -> Int { calls }
}

private actor BlockingInstallerHealth {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func probe() async -> Bool {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        while !released { await Task.yield() }
        return true
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
    }
}

private actor BlockingLifecycleHook {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        while !released { await Task.yield() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { released = true }
}

private final class LockedInstallerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) async { lock.withLock { values.append(value) } }
    func snapshot() async -> [String] { lock.withLock { values } }
    func clear() async { lock.withLock { values.removeAll() } }
}

private actor DeterministicInstallerIdentityLifecycle: BridgeInstallerIdentityLifecycle {
    private let events: LockedInstallerEvents
    private var fingerprint: String?
    private var created = 0
    private var rotations = 0

    init(events: LockedInstallerEvents) {
        self.events = events
    }

    var creationCount: Int { created }

    func ensureFingerprint() -> String {
        if let fingerprint { return fingerprint }
        created += 1
        let generated = String(repeating: created == 1 ? "a" : "c", count: 64)
        fingerprint = generated
        return generated
    }

    func existingFingerprint() -> String? { fingerprint }

    func loseKeychainAccess() {
        fingerprint = nil
    }

    func beginRotation() async throws -> BridgeInstallerIdentityRotationReceipt {
        guard let previous = fingerprint else { throw InstallerFakeError.injected }
        rotations += 1
        let digit = String(rotations % 10)
        let rotated = String(repeating: digit, count: 64)
        fingerprint = rotated
        await events.record("rotate")
        return BridgeInstallerIdentityRotationReceipt(
            rotatedFingerprint: rotated,
            rollback: { [self] in try await rollback(expected: rotated, to: previous) }
        )
    }

    private func rollback(expected: String, to previous: String) throws {
        guard fingerprint == expected else { throw InstallerFakeError.injected }
        fingerprint = previous
    }
}

private final class FailingRemoveFileSystem: BridgeInstallerFileSystemOperations,
    @unchecked Sendable
{
    private let fragment: String
    private let lock = NSLock()
    private var failures = 0
    var failureCount: Int { lock.withLock { failures } }

    init(fragment: String) { self.fragment = fragment }

    func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw BridgeServiceInstallerError.transactionFailed
        }
    }

    func remove(_ url: URL) throws {
        if url.lastPathComponent.contains(fragment) {
            lock.withLock { failures += 1 }
            throw BridgeServiceInstallerError.transactionFailed
        }
        try FileManager.default.removeItem(at: url)
    }
}

private func mode(of url: URL) throws -> mode_t {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { throw InstallerFakeError.injected }
    return metadata.st_mode & 0o777
}
