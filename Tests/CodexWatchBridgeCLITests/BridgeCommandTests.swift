@testable import CodexWatchBridgeCLI
import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import Darwin
import Foundation
import Security
import Testing

@Test func lifecycleCommandParsingKeepsPurgeExplicitAndInstallArgumentsExact() throws {
    #expect(try BridgeCommand.parseLifecycle(arguments: ["status"]) == .status)
    #expect(try BridgeCommand.parseLifecycle(arguments: ["uninstall"]) == .uninstall(purgeData: false))
    #expect(try BridgeCommand.parseLifecycle(arguments: ["uninstall", "--purge-data"]) == .uninstall(purgeData: true))
    #expect(try BridgeCommand.parseLifecycle(arguments: ["rotate-identity"]) == .rotateIdentity)
    #expect(try BridgeCommand.parseLifecycle(arguments: [
        "install",
        "--bundle", "/private/tmp/VoiceInboxBridge.app",
        "--codex", "/usr/bin/true",
        "--bind-host", "192.168.1.42",
        "--advertised-host", "192.168.1.42",
    ]) == .install(
        bundle: URL(fileURLWithPath: "/private/tmp/VoiceInboxBridge.app"),
        codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
        bindHost: "192.168.1.42",
        advertisedHost: "192.168.1.42"
    ))
    #expect(throws: BridgeCommandError.usage) {
        _ = try BridgeCommand.parseLifecycle(arguments: ["uninstall", "--purge-data", "true"])
    }
    #expect(throws: BridgeCommandError.usage) {
        _ = try BridgeCommand.parseLifecycle(arguments: ["install", "--bundle", "relative.app"])
    }
    #expect(throws: BridgeCommandError.usage) {
        _ = try BridgeCommand.parseLifecycle(arguments: [
            "install",
            "--bundle", "/private/tmp/VoiceInboxBridge.app",
            "--codex", "/usr/bin/true",
            "--bind-host", "127.0.0.1",
            "--advertised-host", "bridge.local",
        ])
    }
}

@Test func lifecycleRoutingDisablesLegacyStateRootIdentityRotationBypass() throws {
    #expect(try BridgeCommand.lifecycleActionIfPresent(arguments: ["rotate-identity"])
        == .rotateIdentity)
    #expect(throws: BridgeCommandError.usage) {
        _ = try BridgeCommand.lifecycleActionIfPresent(arguments: [
            "rotate-identity", "--state-root", "/private/tmp/legacy-state",
        ])
    }
    #expect(try BridgeCommand.lifecycleActionIfPresent(arguments: [
        "status", "--state-root", "/private/tmp/legacy-state",
    ]) == nil)
}

@Test func lifecycleOutputIsContentFreeAndExposesOnlyHealthAndPublicFingerprint() {
    let fingerprint = String(repeating: "a", count: 64)
    let output = BridgeCommand.installationStatusDescription(BridgeInstallationStatus(
        installed: true,
        serviceLoaded: true,
        healthy: false,
        publicKeySHA256: fingerprint
    ))

    #expect(output == "bridge-version=0.1.0; installed=true; service-loaded=true; healthy=false; public-key-sha256=\(fingerprint)")
    for forbidden in ["keychain", "token", "nonce", "transcript", "audio", "/Users/", "bridge.local"] {
        #expect(!output.lowercased().contains(forbidden.lowercased()))
    }
}

@Test func pairingInstructionsExposeTheExactWatchPhraseAndOneTimeCode() throws {
    let fingerprint = "0123456789abcdef" + String(repeating: "0", count: 48)

    let instructions = try BridgeCommand.pairingInstructions(
        code: "482913",
        publicKeySHA256: fingerprint
    )

    #expect(instructions == """
    Certificate phrase: amber-birch coral-dune ember-fern glacier-harbor iris-juniper kelp-lunar maple-nova opal-pine
    Pairing code: 482913
    """)
    #expect(!instructions.contains(fingerprint))
}

@Test func productionPairingChallengeRemainsValidForTheSpecifiedTenMinutes() {
    #expect(BridgeCommand.pairingChallengeLifetime == 10 * 60)
}

@Test func identityProviderSelectionUsesInjectedKeychainWhenIdentityFlagsAreAbsent() throws {
    let keychain = CLIReadOnlyTLSIdentityKeychain()
    let provider = try BridgeCommand.tlsIdentityProvider(options: [:], keychain: keychain)

    #expect(provider is KeychainTLSIdentityProvider)
    #expect(keychain.loadCount == 0)
}

@Test func identityProviderSelectionUsesPKCS12OnlyWhenBothCompatibilityFlagsAreExplicit() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-provider-selection-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appending(path: "fixture.p12")
    let password = root.appending(path: "password")
    try Data("not-loaded".utf8).write(to: archive, options: .atomic)
    try Data("fixture-password".utf8).write(to: password, options: .atomic)
    for url in [archive, password] {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    let provider = try BridgeCommand.tlsIdentityProvider(
        options: [
            "identity-p12": archive.path,
            "identity-password-file": password.path,
        ],
        keychain: CLIReadOnlyTLSIdentityKeychain()
    )

    #expect(provider is PKCS12TLSIdentityProvider)
}

@Test func productionStartupReconcilesLegacyCommittedIntakeBeforeAdmission() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-capacity-reconciliation-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let intake = try IntakeStore(rootURL: root.appending(path: "intake", directoryHint: .isDirectory))
    let finalStatuses = try FinalDeliveryStatusStore(
        rootURL: root.appending(path: "final-status", directoryHint: .isDirectory),
        capacity: 1
    )
    let memoID = try MemoID("92929292-9292-9292-9292-929292929292")
    let body = Data("legacy-accepted-audio".utf8)
    _ = try await intake.commit(
        request: IntakeRequest(
            memoID: memoID,
            audioSHA256: AudioDigest.hex(body),
            byteCount: body.count,
            revision: 1,
            capturedAt: Date(timeIntervalSinceReferenceDate: 123),
            localeHint: "en-US"
        ),
        body: body
    )

    try await BridgeCommand.reconcileFinalDeliveryCapacity(
        intake: intake,
        finalStatuses: finalStatuses
    )

    #expect(try await finalStatuses.occupiedCount() == 1)
    #expect(try await finalStatuses.receipt(for: memoID) == nil)
}

@Test func rotateIdentityMaintenanceRejectsHeldServiceLeaseBeforeRevocation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-rotate-held-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lease = BridgeServiceLease(stateDirectory: root)
    try lease.acquire()
    defer { lease.release() }
    let events = CLIIdentityMaintenanceEvents()

    await #expect(throws: BridgeCommandError.invalidConfiguration) {
        try await BridgeCommand.rotateIdentityWhileServiceStopped(
            stateDirectory: root,
            revokePairing: { await events.record("revoke") },
            rotateIdentity: { await events.record("rotate") }
        )
    }
    #expect(await events.snapshot().isEmpty)
}

@Test func rotateIdentityMaintenanceRevokesBeforeRotationWhileLeaseIsHeld() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-rotate-order-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let events = CLIIdentityMaintenanceEvents()

    try await BridgeCommand.rotateIdentityWhileServiceStopped(
        stateDirectory: root,
        revokePairing: { await events.record("revoke") },
        rotateIdentity: {
            #expect(BridgeServiceLease.isLive(stateDirectory: root))
            await events.record("rotate")
        }
    )

    #expect(await events.snapshot() == ["revoke", "rotate"])
}

@Test func rotateIdentityMaintenanceDoesNotRotateWhenRevocationFails() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-rotate-revoke-failure-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let events = CLIIdentityMaintenanceEvents()

    await #expect(throws: CLIIdentityMaintenanceFailure.revokeFailed) {
        try await BridgeCommand.rotateIdentityWhileServiceStopped(
            stateDirectory: root,
            revokePairing: {
                await events.record("revoke")
                throw CLIIdentityMaintenanceFailure.revokeFailed
            },
            rotateIdentity: { await events.record("rotate") }
        )
    }
    #expect(await events.snapshot() == ["revoke"])
}

@Test func speechStatusExplainsTheOperatorActionWithoutRequestingPermission() {
    #expect(
        BridgeCommand.speechAuthorizationInstructions(for: .notDetermined)
            == "Speech authorization: not determined. Run authorize-speech to show the macOS permission prompt."
    )
    #expect(
        BridgeCommand.speechAuthorizationInstructions(for: .authorized)
            == "Speech authorization: authorized. On-device recognition availability is checked per locale and memo."
    )
    #expect(
        BridgeCommand.speechAuthorizationInstructions(for: .denied)
            == "Speech authorization: denied. Enable Speech Recognition for Voice Inbox Bridge in System Settings."
    )
    #expect(
        BridgeCommand.speechAuthorizationInstructions(for: .restricted)
            == "Speech authorization: restricted by macOS policy."
    )
}

@Test func authorizeSpeechAwaitsTheSystemAuthorizationResult() async {
    let result = await BridgeCommand.requestSpeechAuthorization { completion in
        completion(.authorized)
    }

    #expect(result == .authorized)
}

@Test func speechStatusCommandPrintsAndExits() async throws {
    let executable = try #require(builtBridgeExecutable())
    let process = Process()
    let standardOutput = Pipe()
    process.executableURL = executable
    process.arguments = [
        "speech-status",
        "--state-root", "/private/tmp/codex-watch-speech-status-test",
    ]
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    try process.run()

    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while process.isRunning, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        Issue.record("speech-status printed but did not exit")
        return
    }

    let output = try standardOutput.fileHandleForReading.readToEnd() ?? Data()
    #expect(process.terminationStatus == 0)
    #expect(String(decoding: output, as: UTF8.self).hasPrefix("Speech authorization: "))
}

@Test func operationalStatusIsReadOnlyContentFreeAndCountsDurableQueues() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-status-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try BridgeRuntimePaths(root: root)
    try paths.prepareRoot()
    let store = try IntakeStore(rootURL: paths.intake, retentionRootURL: paths.retained)
    let memoID = try MemoID("72727272-7272-7272-7272-727272727272")
    let audio = Data("status-count-audio".utf8)
    _ = try await store.commit(
        request: IntakeRequest(
            memoID: memoID,
            audioSHA256: AudioDigest.hex(audio),
            byteCount: audio.count,
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        body: audio
    )

    let status = try BridgeCommand.operationalStatusDescription(
        paths: paths,
        speechStatus: .notDetermined
    )

    #expect(status == "bridge-version=0.1.0; protocol-version=1; state=stopped; listener=offline; speech=not-determined; committed=1; retained=0")
    #expect(!status.contains(root.path))
    #expect(!status.contains(memoID.rawValue))
}

@Test func purgeDeliveredCommandRemovesOnlyVerifiedDeliveredMaterial() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-purge-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try BridgeRuntimePaths(root: root)
    try paths.prepareRoot()
    let store = try IntakeStore(
        rootURL: paths.intake,
        retentionRootURL: paths.retained
    )
    let journal = try DeliveryJournal(root: paths.delivery)
    let memoID = try MemoID("61616161-6161-6161-6161-616161616161")
    let audio = Data("purge-command-audio".utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await store.commit(
        request: IntakeRequest(
            memoID: memoID,
            audioSHA256: AudioDigest.hex(audio),
            byteCount: audio.count,
            revision: 1,
            capturedAt: capturedAt
        ),
        body: audio
    )
    try journal.create(.received(
        memoID: memoID,
        capturedAt: capturedAt,
        localeHint: nil,
        audioSHA256: AudioDigest.hex(audio)
    ))
    _ = try journal.transition(memoID: memoID, to: .transcribing)
    _ = try journal.transition(memoID: memoID, to: .readyForCodex, transcript: "Purge me")
    _ = try journal.transition(memoID: memoID, to: .inserting)
    _ = try journal.transition(memoID: memoID, to: .reconciling)
    _ = try journal.transition(memoID: memoID, to: .delivered)

    try await BridgeCommand.run(arguments: [
        "purge-delivered",
        "--state-root", root.path,
    ])

    #expect(try await store.committedRecord(for: memoID) == nil)
    #expect(try await store.retainedRecord(for: memoID) == nil)
    #expect(throws: DeliveryJournalError.notFound) {
        _ = try journal.load(memoID: memoID)
    }
}

@Test func purgeDeliveredCommandRefusesToRaceTheResidentBridge() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-purge-live-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try BridgeRuntimePaths(root: root)
    try paths.prepareRoot()
    try FileManager.default.createDirectory(
        at: paths.service,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let lease = BridgeServiceLease(stateDirectory: paths.service)
    try lease.acquire()

    do {
        try await BridgeCommand.run(arguments: [
            "purge-delivered",
            "--state-root", root.path,
        ])
        Issue.record("purge-delivered raced a live bridge")
    } catch BridgeCommandError.invalidConfiguration {
        // Expected: stop the resident bridge before destructive maintenance.
    } catch {
        Issue.record("unexpected purge-delivered error: \(error)")
    }
}

@Test func purgeExclusiveLeasePreventsBridgeStartUntilCleanupCompletes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-purge-exclusive-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let stateDirectory = root.appending(path: "service", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let gate = PurgeLeaseGate()
    let purge = Task {
        try await BridgeCommand.withExclusiveServiceLease(stateDirectory: stateDirectory) {
            await gate.markBegan()
            await gate.waitForRelease()
        }
    }
    await gate.waitUntilBegan()

    let contender = BridgeServiceLease(stateDirectory: stateDirectory)
    #expect(throws: BridgeSupervisorError.alreadyRunning) {
        try contender.acquire()
    }

    await gate.release()
    try await purge.value
    try contender.acquire()
    contender.release()
}

@Test func retentionLeaseSerializesStartupDeliveryAndExplicitPurgeMaintenance() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "bridge-cli-retention-exclusive-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let stateDirectory = root.appending(path: "service", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: stateDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    let gate = PurgeLeaseGate()
    let first = Task {
        try await BridgeCommand.withExclusiveRetentionLease(stateDirectory: stateDirectory) {
            await gate.markBegan()
            await gate.waitForRelease()
        }
    }
    await gate.waitUntilBegan()

    do {
        try await BridgeCommand.withExclusiveRetentionLease(stateDirectory: stateDirectory) {}
        Issue.record("concurrent retention maintenance acquired the same lease")
    } catch BridgeCommandError.invalidConfiguration {
        // Expected: every automatic and explicit retention path shares this lease.
    } catch {
        Issue.record("unexpected retention lease error: \(error)")
    }

    await gate.release()
    try await first.value
    try await BridgeCommand.withExclusiveRetentionLease(stateDirectory: stateDirectory) {}
}

@Test func deliveredRetentionFailureEmitsClosedDiagnosticAndRethrowsOriginalError() async {
    let diagnostics = DiagnosticEventRecorder()

    await #expect(throws: DeliveryFailure.failed) {
        try await BridgeCommand.runDeliveredRetentionMaintenance(
            diagnosticSink: { diagnostics.record($0) },
            maintenance: { throw DeliveryFailure.failed }
        )
    }

    #expect(diagnostics.snapshot() == [.retentionMaintenanceFailed])
}

@Test func runCommandExitsCleanlyAfterSIGTERM() async throws {
    let executable = try #require(builtBridgeExecutable())
    let fixture = try BridgeRunProcessFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let process = Process()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = [
        "run",
        "--state-root", fixture.state.path,
        "--identity-p12", fixture.identity.path,
        "--identity-password-file", fixture.passwordFile.path,
        "--codex", "/usr/bin/true",
        "--bind-host", "127.0.0.1",
        "--advertised-host", "127.0.0.1",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = standardError
    try process.run()

    let startupDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while process.isRunning,
          !FileManager.default.fileExists(atPath: fixture.serviceLock.path),
          ContinuousClock.now < startupDeadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard process.isRunning,
          FileManager.default.fileExists(atPath: fixture.serviceLock.path)
    else {
        // ponytail: bounded join; unbounded waitUntilExit hung monolithic runs
        if process.isRunning {
            process.terminate()
            let failDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning, ContinuousClock.now < failDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning, ContinuousClock.now < killDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        let output = try standardError.fileHandleForReading.readToEnd() ?? Data()
        Issue.record("bridge did not reach its resident runtime: \(String(decoding: output, as: UTF8.self))")
        return
    }

    #expect(kill(process.processIdentifier, SIGTERM) == 0)
    let shutdownDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while process.isRunning, ContinuousClock.now < shutdownDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning, ContinuousClock.now < killDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("bridge ignored SIGTERM")
        return
    }

    let output = try standardError.fileHandleForReading.readToEnd() ?? Data()
    let message = String(decoding: output, as: UTF8.self)
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 0)
    #expect(!message.contains("Signal "))
    #expect(!message.contains("Backtrace"))
}

private struct BridgeRunProcessFixture {
    let root: URL
    let state: URL
    let identity: URL
    let passwordFile: URL
    let serviceLock: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "bridge-signal-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        state = root.appending(path: "state", directoryHint: .isDirectory)
        let tls = root.appending(path: "tls", directoryHint: .isDirectory)
        identity = tls.appending(path: "identity.p12")
        passwordFile = tls.appending(path: "password")
        serviceLock = state.appending(path: "service/service.lock")
        let key = tls.appending(path: "key.pem")
        let certificate = tls.appending(path: "certificate.pem")
        let password = UUID().uuidString

        try FileManager.default.createDirectory(
            at: tls,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try Self.runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-keyout", key.path,
            "-out", certificate.path,
            "-days", "1",
            "-subj", "/CN=codex-watch-signal-test",
        ])
        try Self.runOpenSSL([
            "pkcs12", "-export",
            "-out", identity.path,
            "-inkey", key.path,
            "-in", certificate.path,
            "-passout", "pass:\(password)",
        ])
        try Data(password.utf8).write(to: passwordFile, options: .atomic)
        for url in [key, certificate, identity, passwordFile] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        }
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = standardError.fileHandleForReading.readDataToEndOfFile()
            throw BridgeRunProcessFixtureError.opensslFailed(String(decoding: output, as: UTF8.self))
        }
    }
}

private enum BridgeRunProcessFixtureError: Error {
    case opensslFailed(String)
}

private final class CLIReadOnlyTLSIdentityKeychain: TLSIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    var loadCount: Int { lock.withLock { loads } }

    func load(label: String) throws -> SecIdentity? {
        lock.withLock { loads += 1 }
        return nil
    }

    func insert(privateKey: SecKey, certificate: SecCertificate, label: String) throws -> SecIdentity {
        throw TLSIdentityProvisionerError.keychainUnavailable
    }

    func remove(label: String) throws {
        throw TLSIdentityProvisionerError.keychainUnavailable
    }
}

private actor CLIIdentityMaintenanceEvents {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private enum CLIIdentityMaintenanceFailure: Error { case revokeFailed }

private func builtBridgeExecutable() -> URL? {
    for argument in CommandLine.arguments where argument.hasPrefix("/") {
        var directory = URL(fileURLWithPath: argument).standardizedFileURL
            .deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let candidate = directory.appendingPathComponent("codex-watch-bridge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }
    }
    return nil
}

private actor PurgeLeaseGate {
    private var began = false
    private var released = false
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markBegan() {
        began = true
        let pending = beginWaiters
        beginWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilBegan() async {
        guard !began else { return }
        await withCheckedContinuation { beginWaiters.append($0) }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private enum DeliveryFailure: Error {
    case failed
}

private final class DiagnosticEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BridgeDiagnosticEvent] = []

    func record(_ event: BridgeDiagnosticEvent) {
        lock.withLock { values.append(event) }
    }

    func snapshot() -> [BridgeDiagnosticEvent] {
        lock.withLock { values }
    }
}
