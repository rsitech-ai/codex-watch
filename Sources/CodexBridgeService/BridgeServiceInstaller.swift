import Darwin
import Foundation
import CodexAppServerClient

public struct BridgeInstallPaths: Equatable, Sendable {
    public let application: URL
    public let state: URL
    public let launchAgent: URL

    public init(application: URL, state: URL, launchAgent: URL) {
        self.application = application.standardizedFileURL
        self.state = state.standardizedFileURL
        self.launchAgent = launchAgent.standardizedFileURL
    }

    public static func production(home: URL) throws -> Self {
        guard home.isFileURL, home.path.hasPrefix("/") else {
            throw BridgeServiceInstallerError.invalidPath
        }
        let canonicalHome = home.standardizedFileURL
        let support = canonicalHome.appending(
            path: "Library/Application Support/VoiceInboxBridge",
            directoryHint: .isDirectory
        )
        return Self(
            application: support
                .appending(path: "Service", directoryHint: .isDirectory)
                .appending(path: "VoiceInboxBridge.app", directoryHint: .isDirectory),
            state: support.appending(path: "State", directoryHint: .isDirectory),
            launchAgent: canonicalHome
                .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
                .appending(path: "ai.rsitech.voiceinbox.bridge.plist")
        )
    }
}

public protocol BridgeBundleSignatureVerifying: Sendable {
    func verifyStrictDeepSignature(of bundle: URL) async throws
}

protocol BridgeInstallerFileSystemOperations: Sendable {
    func rename(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
}

struct SystemBridgeInstallerFileSystem: BridgeInstallerFileSystemOperations {
    func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw BridgeServiceInstallerError.transactionFailed
        }
    }

    func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch { throw BridgeServiceInstallerError.transactionFailed }
    }
}

public struct BridgeInstallationStatus: Equatable, Sendable {
    public let installed: Bool
    public let serviceLoaded: Bool
    public let healthy: Bool
    public let publicKeySHA256: String?

    public init(
        installed: Bool,
        serviceLoaded: Bool,
        healthy: Bool,
        publicKeySHA256: String?
    ) {
        self.installed = installed
        self.serviceLoaded = serviceLoaded
        self.healthy = healthy
        self.publicKeySHA256 = publicKeySHA256
    }
}

public enum BridgeServiceInstallerError: Error, Equatable, Sendable {
    case invalidPath
    case unsafeExistingObject
    case invalidBundle
    case invalidConfiguration
    case signatureInvalid
    case launchctlFailed
    case healthCheckFailed
    case transactionFailed
    case rollbackFailed
    case childStillRunning(pid: pid_t, killResult: Int32)
}

protocol BridgeInstallerIdentityLifecycle: Sendable {
    func ensureFingerprint() async throws -> String
    func existingFingerprint() async throws -> String?
    func beginRotation() async throws -> BridgeInstallerIdentityRotationReceipt
}

struct BridgeInstallerIdentityRotationReceipt: @unchecked Sendable {
    let rotatedFingerprint: String
    private let rollbackOperation: @Sendable () async throws -> Void

    init(
        rotatedFingerprint: String,
        rollback: @escaping @Sendable () async throws -> Void
    ) {
        self.rotatedFingerprint = rotatedFingerprint
        rollbackOperation = rollback
    }

    func rollback() async throws {
        try await rollbackOperation()
    }
}

private struct ProductionBridgeInstallerIdentityLifecycle: BridgeInstallerIdentityLifecycle {
    let provisioner: TLSIdentityProvisioner

    func ensureFingerprint() async throws -> String {
        try await provisioner.loadOrCreate().publicKeySHA256
    }

    func existingFingerprint() async throws -> String? {
        try await provisioner.loadExisting()?.publicKeySHA256
    }

    func beginRotation() async throws -> BridgeInstallerIdentityRotationReceipt {
        let receipt = try await provisioner.beginRotation()
        return BridgeInstallerIdentityRotationReceipt(
            rotatedFingerprint: receipt.rotated.publicKeySHA256,
            rollback: { try await provisioner.rollbackRotation(receipt) }
        )
    }
}

final class BridgeInstallerLifecycleLease: @unchecked Sendable {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    init(root: URL) {
        lockURL = root.standardizedFileURL.appending(path: ".codex-watch-bridge.lifecycle.lock")
    }

    deinit { release() }

    func acquire() throws {
        guard descriptor < 0 else { return }
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0,
              let identity = SecureAdvisoryLockFile.descriptorIdentity(fd, normalizeMode: true)
        else {
            if fd >= 0 { close(fd) }
            throw BridgeServiceInstallerError.transactionFailed
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0,
              SecureAdvisoryLockFile.path(lockURL, matches: identity)
        else {
            close(fd)
            throw BridgeServiceInstallerError.transactionFailed
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

public actor BridgeServiceInstaller {
    public static let label = "ai.rsitech.voiceinbox.bridge"
    private static let executableName = "codex-watch-bridge"
    private static let maximumHealthTimeout: Duration = .seconds(15)

    private let paths: BridgeInstallPaths
    private let launchctl: any LaunchctlControlling
    private let signatureVerifier: any BridgeBundleSignatureVerifying
    private let identityLifecycle: any BridgeInstallerIdentityLifecycle
    private let healthCheck: @Sendable () async throws -> Bool
    private let healthTimeout: Duration
    private let healthPollInterval: Duration
    private let revokePairing: @Sendable () async throws -> Void
    private let domain: String
    private let fileSystem: any BridgeInstallerFileSystemOperations
    private let afterLifecycleLeaseAcquired: @Sendable () async -> Void

    public init(
        paths: BridgeInstallPaths,
        launchctl: any LaunchctlControlling,
        signatureVerifier: any BridgeBundleSignatureVerifying,
        identityProvisioner: TLSIdentityProvisioner,
        healthCheck: @escaping @Sendable () async throws -> Bool
    ) {
        self.paths = paths
        self.launchctl = launchctl
        self.signatureVerifier = signatureVerifier
        identityLifecycle = ProductionBridgeInstallerIdentityLifecycle(
            provisioner: identityProvisioner
        )
        self.healthCheck = healthCheck
        healthTimeout = Self.maximumHealthTimeout
        healthPollInterval = .milliseconds(100)
        revokePairing = {
            let pairing = try PairingStore(secretStore: KeychainSecretStore())
            try await pairing.revokeCredential()
        }
        fileSystem = SystemBridgeInstallerFileSystem()
        afterLifecycleLeaseAcquired = {}
        domain = "gui/\(getuid())"
    }

    init(
        paths: BridgeInstallPaths,
        launchctl: any LaunchctlControlling,
        signatureVerifier: any BridgeBundleSignatureVerifying,
        identityLifecycle: any BridgeInstallerIdentityLifecycle,
        healthCheck: @escaping @Sendable () async throws -> Bool,
        healthTimeout: Duration,
        healthPollInterval: Duration,
        revokePairing: @escaping @Sendable () async throws -> Void,
        fileSystem: any BridgeInstallerFileSystemOperations = SystemBridgeInstallerFileSystem(),
        afterLifecycleLeaseAcquired: @escaping @Sendable () async -> Void = {}
    ) {
        self.paths = paths
        self.launchctl = launchctl
        self.signatureVerifier = signatureVerifier
        self.identityLifecycle = identityLifecycle
        self.healthCheck = healthCheck
        self.healthTimeout = min(max(healthTimeout, .milliseconds(1)), Self.maximumHealthTimeout)
        self.healthPollInterval = min(
            max(healthPollInterval, .milliseconds(1)),
            self.healthTimeout
        )
        self.revokePairing = revokePairing
        self.fileSystem = fileSystem
        self.afterLifecycleLeaseAcquired = afterLifecycleLeaseAcquired
        domain = "gui/\(getuid())"
    }

    public func install(
        bundle: URL,
        codexExecutable: URL,
        bindHost: String,
        advertisedHost: String
    ) async throws {
        try validatePathContract()
        let resolvedCodex = try resolvedOwnedCodexExecutable(codexExecutable)
        try validateConfiguration(
            codexExecutable: resolvedCodex,
            bindHost: bindHost,
            advertisedHost: advertisedHost
        )
        try validateBundle(at: bundle)
        let lifecycleLease = try acquireLifecycleLease()
        defer { lifecycleLease.release() }
        await afterLifecycleLeaseAcquired()
        try validateSharedLaunchAgentsDirectoryIfPresent()
        try prepareLayout()
        try await validateInstalledArtifacts(allowPartial: false)

        let priorInstalled = itemExists(paths.application) && itemExists(paths.launchAgent)
        var priorLoaded = false

        let token = UUID().uuidString
        let stagedApplication = paths.application.deletingLastPathComponent()
            .appending(path: ".VoiceInboxBridge.app.staged-\(token)", directoryHint: .isDirectory)
        let stagedManifest = paths.launchAgent.deletingLastPathComponent()
            .appending(path: ".ai.rsitech.voiceinbox.bridge.plist.staged-\(token)")
        let backupApplication = paths.application.deletingLastPathComponent()
            .appending(path: ".VoiceInboxBridge.app.backup-\(token)", directoryHint: .isDirectory)
        let backupManifest = paths.launchAgent.deletingLastPathComponent()
            .appending(path: ".ai.rsitech.voiceinbox.bridge.plist.backup-\(token)")
        let backupFingerprint = paths.state
            .appending(path: ".identity-public-key-sha256.backup-\(token)")

        var appBackedUp = false
        var manifestBackedUp = false
        var fingerprintBackedUp = false
        var appInstalled = false
        var manifestInstalled = false
        var fingerprintInstalled = false
        var newServiceBootstrapped = false
        do {
            try stageBundle(from: bundle, at: stagedApplication)
            do { try await signatureVerifier.verifyStrictDeepSignature(of: stagedApplication) }
            catch let error as BridgeServiceInstallerError {
                if case .childStillRunning = error { throw error }
                throw BridgeServiceInstallerError.signatureInvalid
            }
            catch { throw BridgeServiceInstallerError.signatureInvalid }
            try writeManifest(
                at: stagedManifest,
                codexExecutable: resolvedCodex,
                bindHost: bindHost,
                advertisedHost: advertisedHost
            )
            priorLoaded = try await serviceIsLoaded()
            let fingerprint: String
            do {
                fingerprint = try await reusedOrCreatedFingerprint()
            } catch {
                throw BridgeServiceInstallerError.transactionFailed
            }
            if itemExists(fingerprintURL) {
                guard try isOwnedRegularFile(fingerprintURL) else {
                    throw BridgeServiceInstallerError.unsafeExistingObject
                }
                try atomicRename(fingerprintURL, backupFingerprint)
                fingerprintBackedUp = true
            }
            try writeFingerprint(fingerprint)
            fingerprintInstalled = true

            if priorLoaded {
                try await bootoutIfPresent()
            }
            if priorInstalled {
                try atomicRename(paths.application, backupApplication)
                appBackedUp = true
                try atomicRename(paths.launchAgent, backupManifest)
                manifestBackedUp = true
            }
            try atomicRename(stagedApplication, paths.application)
            appInstalled = true
            try atomicRename(stagedManifest, paths.launchAgent)
            manifestInstalled = true
            try await bootstrapNewService()
            newServiceBootstrapped = true
            guard try await waitForHealth() else {
                throw BridgeServiceInstallerError.healthCheckFailed
            }
            // Readiness is the transaction commit point. Private backup
            // reclamation is best-effort and must never re-enter rollback.
            try? removeIfPresent(backupApplication)
            try? removeIfPresent(backupManifest)
            try? removeIfPresent(backupFingerprint)
        } catch {
            if let installerError = error as? BridgeServiceInstallerError,
               case .childStillRunning = installerError
            {
                throw installerError
            }
            do {
                try await rollbackInstall(
                    priorLoaded: priorLoaded,
                    stagedApplication: stagedApplication,
                    stagedManifest: stagedManifest,
                    backupApplication: backupApplication,
                    backupManifest: backupManifest,
                    backupFingerprint: backupFingerprint,
                    appBackedUp: appBackedUp,
                    manifestBackedUp: manifestBackedUp,
                    fingerprintBackedUp: fingerprintBackedUp,
                    appInstalled: appInstalled,
                    manifestInstalled: manifestInstalled,
                    fingerprintInstalled: fingerprintInstalled,
                    newServiceBootstrapped: newServiceBootstrapped
                )
            } catch {
                throw BridgeServiceInstallerError.rollbackFailed
            }
            if let installerError = error as? BridgeServiceInstallerError {
                throw installerError
            }
            throw BridgeServiceInstallerError.transactionFailed
        }
    }

    public func status() async throws -> BridgeInstallationStatus {
        try validatePathContract()
        let lifecycleLease = try acquireLifecycleLease()
        defer { lifecycleLease.release() }
        await afterLifecycleLeaseAcquired()
        try validateSharedLaunchAgentsDirectoryIfPresent()
        try await validateInstalledArtifacts(allowPartial: false)
        let installed = itemExists(paths.application) && itemExists(paths.launchAgent)
        let loaded = installed ? try await serviceIsLoaded() : false
        let healthy: Bool
        if loaded {
            let deadline = ContinuousClock.now.advanced(by: healthTimeout)
            healthy = (try? await boundedHealthProbe(until: deadline).healthy) == true
        } else { healthy = false }
        return BridgeInstallationStatus(
            installed: installed,
            serviceLoaded: loaded,
            healthy: healthy,
            publicKeySHA256: installed
                ? try await identityLifecycle.existingFingerprint()
                : nil
        )
    }

    public func uninstall(purgeData: Bool) async throws {
        try validatePathContract()
        let lifecycleLease = try acquireLifecycleLease()
        defer { lifecycleLease.release() }
        await afterLifecycleLeaseAcquired()
        try validateSharedLaunchAgentsDirectoryIfPresent()
        try await validateInstalledArtifacts(allowPartial: true)
        let loaded = try await serviceIsLoaded()
        if loaded {
            try await bootoutIfPresent()
        }
        let token = UUID().uuidString
        let stagedApplication = paths.application.deletingLastPathComponent()
            .appending(path: ".VoiceInboxBridge.app.uninstall-\(token)", directoryHint: .isDirectory)
        let stagedManifest = paths.launchAgent.deletingLastPathComponent()
            .appending(path: ".ai.rsitech.voiceinbox.bridge.plist.uninstall-\(token)")
        var applicationStaged = false
        do {
            if itemExists(paths.application) {
                try atomicRename(paths.application, stagedApplication)
                applicationStaged = true
            }
            if itemExists(paths.launchAgent) {
                try atomicRename(paths.launchAgent, stagedManifest)
            }
        } catch {
            do {
                if applicationStaged { try atomicRename(stagedApplication, paths.application) }
                if loaded { try await restorePriorServiceOrFail() }
            } catch {
                throw BridgeServiceInstallerError.rollbackFailed
            }
            throw BridgeServiceInstallerError.transactionFailed
        }
        // Exact installed paths are absent: uninstall is committed. Cleanup
        // failures may leave only private, validated sibling tombstones.
        try? removeIfPresent(stagedManifest)
        try? removeIfPresent(stagedApplication)
        if purgeData {
            try validateOwnedDirectoryIfPresent(paths.state)
            try removeIfPresent(paths.state)
        }
    }

    public func rotateIdentity() async throws -> String {
        try validatePathContract()
        let lifecycleLease = try acquireLifecycleLease()
        defer { lifecycleLease.release() }
        await afterLifecycleLeaseAcquired()
        try validateSharedLaunchAgentsDirectoryIfPresent()
        try await validateInstalledArtifacts(allowPartial: false)
        guard let priorFingerprint = try await identityLifecycle.existingFingerprint() else {
            throw BridgeServiceInstallerError.transactionFailed
        }
        let loaded = try await serviceIsLoaded()
        if loaded {
            try await bootoutIfPresent()
        }
        let serviceState = paths.state.appending(path: "service", directoryHint: .isDirectory)
        do { try preparePrivateDirectory(serviceState, createParents: true) }
        catch {
            if loaded { try await restorePriorServiceOrFail() }
            throw error
        }
        let lease = BridgeServiceLease(stateDirectory: serviceState)
        var receipt: BridgeInstallerIdentityRotationReceipt?
        do {
            try lease.acquire()
            try await revokePairing()
            let begun = try await identityLifecycle.beginRotation()
            receipt = begun
            try writeFingerprint(begun.rotatedFingerprint)
            lease.release()
            if loaded {
                try await bootstrapNewService()
                guard try await waitForHealth() else {
                    throw BridgeServiceInstallerError.healthCheckFailed
                }
            }
            return begun.rotatedFingerprint
        } catch {
            lease.release()
            if let installerError = error as? BridgeServiceInstallerError,
               case .childStillRunning = installerError
            {
                throw installerError
            }
            if let receipt {
                if loaded {
                    do { try await launchctl.bootout(domain: domain, label: Self.label) }
                    catch LaunchctlClientError.serviceNotLoaded {
                        // Failed bootstrap has no new service to stop.
                    } catch {
                        throw BridgeServiceInstallerError.rollbackFailed
                    }
                }
                do {
                    try await receipt.rollback()
                    try writeFingerprint(priorFingerprint)
                } catch {
                    throw BridgeServiceInstallerError.rollbackFailed
                }
            }
            if loaded { try await restorePriorServiceOrFail() }
            if let installerError = error as? BridgeServiceInstallerError { throw installerError }
            throw BridgeServiceInstallerError.transactionFailed
        }
    }

    private func restorePriorServiceOrFail() async throws {
        do { try await launchctl.bootstrap(domain: domain, plist: paths.launchAgent) }
        catch { throw BridgeServiceInstallerError.rollbackFailed }
        guard (try? await waitForHealth()) == true else {
            throw BridgeServiceInstallerError.rollbackFailed
        }
    }

    private func bootstrapNewService() async throws {
        do { try await launchctl.bootstrap(domain: domain, plist: paths.launchAgent) }
        catch let LaunchctlClientError.childStillRunning(pid, killResult) {
            throw BridgeServiceInstallerError.childStillRunning(
                pid: pid, killResult: killResult
            )
        } catch {
            throw BridgeServiceInstallerError.launchctlFailed
        }
    }

    private func bootoutIfPresent() async throws {
        do { try await launchctl.bootout(domain: domain, label: Self.label) }
        catch LaunchctlClientError.serviceNotLoaded {
            // The exact service may exit between the authoritative print and
            // bootout calls. Bootout remains idempotent in that race.
        } catch let LaunchctlClientError.childStillRunning(pid, killResult) {
            throw BridgeServiceInstallerError.childStillRunning(
                pid: pid, killResult: killResult
            )
        } catch {
            throw BridgeServiceInstallerError.launchctlFailed
        }
    }

    private func validatePathContract() throws {
        for url in [paths.application, paths.state, paths.launchAgent] {
            guard url.isFileURL,
                  url.path.hasPrefix("/"),
                  url.standardizedFileURL.path == url.path
            else { throw BridgeServiceInstallerError.invalidPath }
        }
        let service = paths.application.deletingLastPathComponent()
        let bridgeRoot = service.deletingLastPathComponent()
        let support = bridgeRoot.deletingLastPathComponent()
        let library = support.deletingLastPathComponent()
        let home = library.deletingLastPathComponent()
        guard paths.application == bridgeRoot
            .appending(path: "Service", directoryHint: .isDirectory)
            .appending(path: "VoiceInboxBridge.app", directoryHint: .isDirectory),
            paths.state == bridgeRoot.appending(path: "State", directoryHint: .isDirectory),
            paths.launchAgent == home
                .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
                .appending(path: "ai.rsitech.voiceinbox.bridge.plist"),
            library.lastPathComponent == "Library",
            support.lastPathComponent == "Application Support",
            bridgeRoot.lastPathComponent == "VoiceInboxBridge"
        else { throw BridgeServiceInstallerError.invalidPath }

        try requireDirectory(home)
        try rejectSymlinksOrUnexpectedObjects([
            library,
            support,
            bridgeRoot,
            service,
            paths.state,
            paths.launchAgent.deletingLastPathComponent(),
        ])
    }

    private var bridgeRoot: URL {
        paths.state.deletingLastPathComponent()
    }

    private func acquireLifecycleLease() throws -> BridgeInstallerLifecycleLease {
        let lease = BridgeInstallerLifecycleLease(root: lifecycleNamespace)
        try lease.acquire()
        return lease
    }

    private var lifecycleNamespace: URL {
        paths.launchAgent
            .deletingLastPathComponent() // LaunchAgents
            .deletingLastPathComponent() // Library
            .deletingLastPathComponent() // home
    }

    private func validateSharedLaunchAgentsDirectoryIfPresent() throws {
        let launchAgents = paths.launchAgent.deletingLastPathComponent()
        guard itemExists(launchAgents) else { return }
        var metadata = stat()
        guard lstat(launchAgents.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o022 == 0
        else { throw BridgeServiceInstallerError.unsafeExistingObject }
    }

    private func validateConfiguration(
        codexExecutable: URL,
        bindHost: String,
        advertisedHost: String
    ) throws {
        guard codexExecutable.isFileURL,
              codexExecutable.path.hasPrefix("/"),
              codexExecutable.standardizedFileURL.path == codexExecutable.path,
              try isOwnedRegularExecutable(codexExecutable),
              validManifestValue(bindHost),
              validManifestValue(advertisedHost)
        else { throw BridgeServiceInstallerError.invalidConfiguration }
    }

    private func resolvedOwnedCodexExecutable(_ codexExecutable: URL) throws -> URL {
        guard codexExecutable.isFileURL, codexExecutable.path.hasPrefix("/") else {
            throw BridgeServiceInstallerError.invalidConfiguration
        }
        // ponytail: Homebrew ships `codex` as a symlink; launchd needs a regular file.
        let resolved = codexExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard try isOwnedRegularExecutable(resolved) else {
            throw BridgeServiceInstallerError.invalidConfiguration
        }
        return resolved
    }

    private func validateBundle(at bundle: URL) throws {
        guard bundle.isFileURL,
              bundle.path.hasPrefix("/"),
              bundle.standardizedFileURL.path == bundle.path,
              try isOwnedDirectory(bundle)
        else { throw BridgeServiceInstallerError.invalidBundle }
        try rejectSymlinksRecursively(bundle)
        let infoURL = bundle.appending(path: "Contents/Info.plist")
        let executableURL = bundle.appending(path: "Contents/MacOS/\(Self.executableName)")
        guard try isOwnedRegularFile(infoURL),
              try isRegularExecutable(executableURL),
              let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoURL), options: [], format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Self.label,
              info["CFBundleExecutable"] as? String == Self.executableName,
              info["CFBundlePackageType"] as? String == "APPL"
        else { throw BridgeServiceInstallerError.invalidBundle }
    }

    private func prepareLayout() throws {
        let service = paths.application.deletingLastPathComponent()
        let bridgeRoot = service.deletingLastPathComponent()
        let support = bridgeRoot.deletingLastPathComponent()
        let library = support.deletingLastPathComponent()
        let launchAgents = paths.launchAgent.deletingLastPathComponent()
        try prepareDirectory(library, privateMode: false)
        try prepareDirectory(support, privateMode: false)
        try prepareDirectory(bridgeRoot, privateMode: true)
        try prepareDirectory(service, privateMode: true)
        try prepareDirectory(paths.state, privateMode: true)
        try prepareDirectory(launchAgents, privateMode: true, preserveExistingMode: true)
    }

    private func validateInstalledArtifacts(allowPartial: Bool) async throws {
        let appExists = itemExists(paths.application)
        let manifestExists = itemExists(paths.launchAgent)
        guard allowPartial || appExists == manifestExists else {
            throw BridgeServiceInstallerError.unsafeExistingObject
        }
        if appExists {
            guard try isOwnedPrivateDirectory(paths.application) else {
                throw BridgeServiceInstallerError.unsafeExistingObject
            }
            try validateBundle(at: paths.application)
            do { try await signatureVerifier.verifyStrictDeepSignature(of: paths.application) }
            catch let error as BridgeServiceInstallerError {
                if case .childStillRunning = error { throw error }
                throw BridgeServiceInstallerError.signatureInvalid
            }
            catch { throw BridgeServiceInstallerError.signatureInvalid }
        }
        if manifestExists {
            guard try isOwnedPrivateRegularFile(paths.launchAgent) else {
                throw BridgeServiceInstallerError.unsafeExistingObject
            }
            try validateInstalledManifest()
        }
        try validateOwnedDirectoryIfPresent(paths.state)
    }

    private func validateInstalledManifest() throws {
        let propertyList: [String: Any]
        do {
            guard let decoded = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: paths.launchAgent), options: [], format: nil
            ) as? [String: Any] else {
                throw BridgeServiceInstallerError.invalidConfiguration
            }
            propertyList = decoded
        } catch let error as BridgeServiceInstallerError {
            throw error
        } catch {
            throw BridgeServiceInstallerError.invalidConfiguration
        }
        guard propertyList["Label"] as? String == Self.label,
              propertyList["RunAtLoad"] as? Bool == true,
              (propertyList["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false,
              propertyList["ThrottleInterval"] as? Int == 10,
              propertyList["ProcessType"] as? String == "Background",
              propertyList["AssociatedBundleIdentifiers"] as? [String] == [Self.label],
              let arguments = propertyList["ProgramArguments"] as? [String],
              arguments.count == 10,
              arguments[0] == paths.application
                .appending(path: "Contents/MacOS/\(Self.executableName)").path,
              arguments[1] == "run",
              arguments[2] == "--state-root",
              arguments[3] == paths.state.path,
              arguments[4] == "--codex",
              URL(fileURLWithPath: arguments[5]).path == arguments[5],
              URL(fileURLWithPath: arguments[5]).standardizedFileURL.path == arguments[5],
              try isOwnedRegularExecutable(URL(fileURLWithPath: arguments[5])),
              arguments[6] == "--bind-host",
              validManifestValue(arguments[7]),
              arguments[8] == "--advertised-host",
              validManifestValue(arguments[9]),
              !arguments.contains(where: {
                  $0 == "--tls-pkcs12" || $0 == "--tls-password"
                      || $0 == "--identity" || $0 == "--identity-file"
              })
        else { throw BridgeServiceInstallerError.invalidConfiguration }
    }

    private func stageBundle(from source: URL, at destination: URL) throws {
        guard !itemExists(destination) else { throw BridgeServiceInstallerError.unsafeExistingObject }
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw BridgeServiceInstallerError.transactionFailed }
        guard chmod(destination.path, 0o700) == 0 else {
            throw BridgeServiceInstallerError.transactionFailed
        }
        try validateBundle(at: destination)
    }

    private func writeManifest(
        at url: URL,
        codexExecutable: URL,
        bindHost: String,
        advertisedHost: String
    ) throws {
        let manifest: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [
                paths.application.appending(path: "Contents/MacOS/\(Self.executableName)").path,
                "run", "--state-root", paths.state.path,
                "--codex", codexExecutable.path,
                "--bind-host", bindHost,
                "--advertised-host", advertisedHost,
            ],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "AssociatedBundleIdentifiers": [Self.label],
        ]
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: manifest,
                format: .xml,
                options: 0
            )
        } catch { throw BridgeServiceInstallerError.transactionFailed }
        try writePrivateFile(data, at: url)
    }

    private func rollbackInstall(
        priorLoaded: Bool,
        stagedApplication: URL,
        stagedManifest: URL,
        backupApplication: URL,
        backupManifest: URL,
        backupFingerprint: URL,
        appBackedUp: Bool,
        manifestBackedUp: Bool,
        fingerprintBackedUp: Bool,
        appInstalled: Bool,
        manifestInstalled: Bool,
        fingerprintInstalled: Bool,
        newServiceBootstrapped: Bool
    ) async throws {
        if appInstalled || manifestInstalled {
            do { try await launchctl.bootout(domain: domain, label: Self.label) }
            catch LaunchctlClientError.serviceNotLoaded where !newServiceBootstrapped {
                // A failed bootstrap may leave no service to boot out.
            } catch {
                throw BridgeServiceInstallerError.rollbackFailed
            }
        }
        if manifestInstalled { try removeIfPresent(paths.launchAgent) }
        if appInstalled { try removeIfPresent(paths.application) }
        if fingerprintInstalled { try removeIfPresent(fingerprintURL) }
        if appBackedUp { try atomicRename(backupApplication, paths.application) }
        if manifestBackedUp { try atomicRename(backupManifest, paths.launchAgent) }
        if fingerprintBackedUp { try atomicRename(backupFingerprint, fingerprintURL) }
        try removeIfPresent(stagedApplication)
        try removeIfPresent(stagedManifest)
        try removeIfPresent(backupApplication)
        try removeIfPresent(backupManifest)
        try removeIfPresent(backupFingerprint)
        if priorLoaded {
            do { try await launchctl.bootstrap(domain: domain, plist: paths.launchAgent) }
            catch { throw BridgeServiceInstallerError.rollbackFailed }
            guard (try? await waitForHealth()) == true else {
                throw BridgeServiceInstallerError.rollbackFailed
            }
        }
    }

    private func waitForHealth() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: healthTimeout)
        repeat {
            let probe = try await boundedHealthProbe(until: deadline)
            if probe.healthy { return true }
            if !probe.completed { return false }
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: min(
                healthPollInterval,
                ContinuousClock.now.duration(to: deadline)
            ))
        } while ContinuousClock.now < deadline
        return false
    }

    private func boundedHealthProbe(
        until deadline: ContinuousClock.Instant
    ) async throws -> (completed: Bool, healthy: Bool) {
        let result = BridgeHealthProbeResult()
        let operation = healthCheck
        let probe = Task.detached {
            result.complete(healthy: (try? await operation()) == true)
        }
        defer { probe.cancel() }
        repeat {
            if let healthy = result.value { return (true, healthy) }
            if ContinuousClock.now >= deadline { return (false, false) }
            try await Task.sleep(for: min(
                .milliseconds(5),
                ContinuousClock.now.duration(to: deadline)
            ))
        } while ContinuousClock.now < deadline
        return (false, false)
    }

    private func serviceIsLoaded() async throws -> Bool {
        do {
            _ = try await launchctl.printService(domain: domain, label: Self.label)
            return true
        } catch LaunchctlClientError.serviceNotLoaded {
            return false
        } catch let LaunchctlClientError.childStillRunning(pid, killResult) {
            throw BridgeServiceInstallerError.childStillRunning(
                pid: pid, killResult: killResult
            )
        } catch {
            throw BridgeServiceInstallerError.launchctlFailed
        }
    }

    private func reusedOrCreatedFingerprint() async throws -> String {
        if let existing = try await identityLifecycle.existingFingerprint() {
            return existing
        }
        if let persisted = readFingerprint() {
            let service = paths.state.appending(path: "service", directoryHint: .isDirectory)
            // Keychain ACL is per code signature. Reinstall must keep the pin
            // without minting; the listener loads PKCS#12 from this directory.
            guard PersistedTLSIdentity.exists(stateDirectory: service) else {
                throw BridgeServiceInstallerError.transactionFailed
            }
            return persisted
        }
        return try await identityLifecycle.ensureFingerprint()
    }

    private var fingerprintURL: URL {
        paths.state.appending(path: ".identity-public-key-sha256")
    }

    private func writeFingerprint(_ value: String) throws {
        guard Self.isFingerprint(value) else { throw BridgeServiceInstallerError.transactionFailed }
        let staged = paths.state.appending(path: ".identity-public-key-sha256.staged-\(UUID().uuidString)")
        try writePrivateFile(Data(value.utf8), at: staged)
        if itemExists(fingerprintURL) {
            guard try isOwnedRegularFile(fingerprintURL) else {
                throw BridgeServiceInstallerError.unsafeExistingObject
            }
            try removeIfPresent(fingerprintURL)
        }
        try atomicRename(staged, fingerprintURL)
    }

    private func readFingerprint() -> String? {
        guard (try? isOwnedRegularFile(fingerprintURL)) == true,
              let value = try? String(contentsOf: fingerprintURL, encoding: .utf8),
              Self.isFingerprint(value)
        else { return nil }
        return value
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a" ... "f").contains($0) }
    }

    private func validManifestValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024
            && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    private func preparePrivateDirectory(_ url: URL, createParents: Bool) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: createParents,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch CocoaError.fileWriteFileExists {
            // Validated below.
        } catch { throw BridgeServiceInstallerError.transactionFailed }
        guard try isOwnedDirectory(url), chmod(url.path, 0o700) == 0 else {
            throw BridgeServiceInstallerError.unsafeExistingObject
        }
    }

    private func prepareDirectory(
        _ url: URL,
        privateMode: Bool,
        preserveExistingMode: Bool = false
    ) throws {
        let existed = itemExists(url)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: privateMode
                    ? [.posixPermissions: NSNumber(value: 0o700)]
                    : nil
            )
        } catch CocoaError.fileWriteFileExists {
            // Validated below.
        } catch { throw BridgeServiceInstallerError.transactionFailed }
        guard try isOwnedDirectory(url) else {
            throw BridgeServiceInstallerError.unsafeExistingObject
        }
        if preserveExistingMode, existed {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  metadata.st_mode & 0o022 == 0
            else { throw BridgeServiceInstallerError.unsafeExistingObject }
        }
        if privateMode, !(preserveExistingMode && existed), chmod(url.path, 0o700) != 0 {
            throw BridgeServiceInstallerError.transactionFailed
        }
    }

    private func rejectSymlinksOrUnexpectedObjects(_ urls: [URL]) throws {
        for url in urls where itemExists(url) {
            guard try isOwnedDirectory(url) else {
                throw BridgeServiceInstallerError.unsafeExistingObject
            }
        }
    }

    private func rejectSymlinksRecursively(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw BridgeServiceInstallerError.invalidBundle }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw BridgeServiceInstallerError.invalidBundle
            }
        }
    }

    private func validateOwnedDirectoryIfPresent(_ url: URL) throws {
        if itemExists(url), try !isOwnedPrivateDirectory(url) {
            throw BridgeServiceInstallerError.unsafeExistingObject
        }
    }

    private func requireDirectory(_ url: URL) throws {
        guard try isOwnedDirectory(url) else { throw BridgeServiceInstallerError.invalidPath }
    }

    private func isOwnedDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR && metadata.st_uid == getuid()
    }

    private func isOwnedPrivateDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
            && metadata.st_uid == getuid()
            && metadata.st_mode & 0o7777 == 0o700
    }

    private func isOwnedRegularFile(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
    }

    private func isOwnedPrivateRegularFile(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o7777 == 0o600
    }

    private func isOwnedRegularExecutable(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_uid == getuid()
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o111 != 0
    }

    private func isRegularExecutable(_ url: URL) throws -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_mode & 0o111 != 0
    }

    private func itemExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    private func atomicRename(_ source: URL, _ destination: URL) throws {
        try fileSystem.rename(source, to: destination)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard itemExists(url) else { return }
        try fileSystem.remove(url)
    }

    private func writePrivateFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BridgeServiceInstallerError.transactionFailed }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        let result = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard result, fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else {
            throw BridgeServiceInstallerError.transactionFailed
        }
        succeeded = true
    }
}

private final class BridgeHealthProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    func complete(healthy: Bool) {
        lock.withLock { stored = healthy }
    }

    var value: Bool? { lock.withLock { stored } }
}

public struct CodeSignBridgeBundleSignatureVerifier: BridgeBundleSignatureVerifying, Sendable {
    private let executable: URL
    private let timeout: Duration
    private let shutdown: @Sendable (Process) async -> OwnedChildShutdownOutcome

    public init() {
        executable = URL(fileURLWithPath: "/usr/bin/codesign")
        timeout = .seconds(15)
        shutdown = Self.defaultShutdown
    }

    init(executable: URL, timeout: Duration) {
        self.executable = executable.standardizedFileURL
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(15))
        shutdown = Self.defaultShutdown
    }

    init(
        executable: URL,
        timeout: Duration,
        shutdown: @escaping @Sendable (Process) async -> OwnedChildShutdownOutcome
    ) {
        self.executable = executable.standardizedFileURL
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(15))
        self.shutdown = shutdown
    }

    public func verifyStrictDeepSignature(of bundle: URL) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw BridgeServiceInstallerError.signatureInvalid }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            if process.isRunning {
                let outcome = await shutdown(process)
                if case let .stillRunning(pid, killResult) = outcome {
                    throw BridgeServiceInstallerError.childStillRunning(
                        pid: pid, killResult: killResult
                    )
                }
            }
            throw error
        }
        if process.isRunning {
            let outcome = await shutdown(process)
            if case let .stillRunning(pid, killResult) = outcome {
                throw BridgeServiceInstallerError.childStillRunning(
                    pid: pid, killResult: killResult
                )
            }
            throw BridgeServiceInstallerError.signatureInvalid
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw BridgeServiceInstallerError.signatureInvalid
        }
    }

    private static func defaultShutdown(_ process: Process) async -> OwnedChildShutdownOutcome {
        await OwnedChildShutdown(policy: .init(
            gracefulTimeout: .zero,
            terminateTimeout: .milliseconds(100),
            killTimeout: .milliseconds(100)
        )).stop(process: process, stdin: nil)
    }
}
