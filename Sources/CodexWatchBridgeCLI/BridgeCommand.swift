import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import CodexWatchCore
import Dispatch
import Foundation
import Speech

enum BridgeCommandError: Error {
    case usage
    case invalidConfiguration
    case speechAuthorizationDenied
}

enum BridgeSpeechAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorized: self = .authorized
        @unknown default: self = .restricted
        }
    }
}

enum BridgeLifecycleAction: Equatable, Sendable {
    case install(
        bundle: URL,
        codexExecutable: URL,
        bindHost: String,
        advertisedHost: String
    )
    case status
    case uninstall(purgeData: Bool)
    case rotateIdentity
}

private final class SignalLifetime: @unchecked Sendable {
    var sources: [DispatchSourceSignal] = []
}

enum BridgeCommand {
    static let bridgeVersion = "0.1.0"
    static let pairingChallengeLifetime: TimeInterval = 10 * 60

    static func run(arguments: [String]) async throws {
        guard let command = arguments.first else { throw BridgeCommandError.usage }
        if let lifecycleAction = try lifecycleActionIfPresent(arguments: arguments) {
            try await runLifecycle(lifecycleAction)
            return
        }
        var commandArguments = Array(arguments.dropFirst())
        let retryMemoID: MemoID?
        if command == "retry", let first = commandArguments.first, !first.hasPrefix("--") {
            retryMemoID = try? MemoID(first)
            guard retryMemoID != nil else { throw BridgeCommandError.usage }
            commandArguments.removeFirst()
        } else {
            retryMemoID = nil
        }
        let options = try parse(arguments: commandArguments)
        let paths = try BridgeRuntimePaths(root: requiredRoot(options))

        switch command {
        case "status":
            print(try operationalStatusDescription(
                paths: paths,
                speechStatus: BridgeSpeechAuthorizationStatus(
                    SFSpeechRecognizer.authorizationStatus()
                )
            ))
        case "pause":
            try BridgeSupervisor.setPersistedPause(true, stateDirectory: paths.service)
        case "resume":
            try BridgeSupervisor.setPersistedPause(false, stateDirectory: paths.service)
        case "rotate-identity":
            throw BridgeCommandError.usage
        case "pair":
            let identity = try tlsIdentityProvider(
                options: options,
                stateDirectory: paths.service
            ).loadIdentity()
            let pairing = try PairingStore(secretStore: KeychainSecretStore())
            let challenge = try await pairing.beginPairing(
                validFor: pairingChallengeLifetime
            )
            print(try pairingInstructions(
                code: challenge.code,
                publicKeySHA256: identity.publicKeySHA256
            ))
        case "speech-status":
            print(speechAuthorizationInstructions(
                for: BridgeSpeechAuthorizationStatus(SFSpeechRecognizer.authorizationStatus())
            ))
        case "authorize-speech":
            let status = await requestSystemSpeechAuthorization()
            print(speechAuthorizationInstructions(for: status))
            guard status == .authorized else {
                throw BridgeCommandError.speechAuthorizationDenied
            }
        case "revoke-watch":
            let pairing = try PairingStore(secretStore: KeychainSecretStore())
            try await pairing.revokeCredential()
        case "purge-delivered":
            try paths.prepareRoot()
            try preparePrivateServiceDirectory(paths.service)
            let purged = try await withExclusiveServiceLease(stateDirectory: paths.service) {
                try await withExclusiveRetentionLease(stateDirectory: paths.service) {
                    let intake = try IntakeStore(
                        rootURL: paths.intake,
                        retentionRootURL: paths.retained
                    )
                    let journal = try DeliveryJournal(root: paths.delivery)
                    let retention = try BridgeDeliveredRetentionController(
                        intakeStore: intake,
                        journal: journal
                    )
                    return try await retention.purgeAllDelivered()
                }
            }
            print("purged-delivered=\(purged.count)")
        case "run":
            try await runService(paths: paths, options: options, retryMemoID: nil)
        case "retry":
            guard let retryMemoID else { throw BridgeCommandError.usage }
            if BridgeServiceLease.isLive(stateDirectory: paths.service) {
                try OperatorRetryMailbox(stateDirectory: paths.service).enqueue(retryMemoID)
                print("retry-queued=ok")
                return
            }
            try await runService(paths: paths, options: options, retryMemoID: retryMemoID)
        default:
            throw BridgeCommandError.usage
        }
    }

    static func parseLifecycle(arguments: [String]) throws -> BridgeLifecycleAction {
        guard let command = arguments.first else { throw BridgeCommandError.usage }
        let remaining = Array(arguments.dropFirst())
        switch command {
        case "status":
            guard remaining.isEmpty else { throw BridgeCommandError.usage }
            return .status
        case "rotate-identity":
            guard remaining.isEmpty else { throw BridgeCommandError.usage }
            return .rotateIdentity
        case "uninstall":
            if remaining.isEmpty { return .uninstall(purgeData: false) }
            guard remaining == ["--purge-data"] else { throw BridgeCommandError.usage }
            return .uninstall(purgeData: true)
        case "install":
            let options = try parse(arguments: remaining)
            guard options.count == 4,
                  let bundle = options["bundle"], bundle.hasPrefix("/"),
                  let codex = options["codex"], codex.hasPrefix("/"),
                  let bindHost = options["bind-host"],
                  let advertisedHost = options["advertised-host"],
                  NetworkBridgeListener.isValidWatchReachableBindHost(bindHost),
                  NetworkBridgeListener.isValidWatchReachableAdvertisedHost(advertisedHost)
            else { throw BridgeCommandError.usage }
            return .install(
                bundle: URL(fileURLWithPath: bundle).standardizedFileURL,
                codexExecutable: URL(fileURLWithPath: codex).standardizedFileURL,
                bindHost: bindHost,
                advertisedHost: advertisedHost
            )
        default:
            throw BridgeCommandError.usage
        }
    }

    static func lifecycleActionIfPresent(
        arguments: [String]
    ) throws -> BridgeLifecycleAction? {
        guard let command = arguments.first else { throw BridgeCommandError.usage }
        switch command {
        case "install", "uninstall":
            return try parseLifecycle(arguments: arguments)
        case "status":
            return arguments.count == 1 ? try parseLifecycle(arguments: arguments) : nil
        case "rotate-identity":
            return try parseLifecycle(arguments: arguments)
        default:
            return nil
        }
    }

    static func installationStatusDescription(_ status: BridgeInstallationStatus) -> String {
        [
            "bridge-version=\(bridgeVersion)",
            "installed=\(status.installed)",
            "service-loaded=\(status.serviceLoaded)",
            "healthy=\(status.healthy)",
            "public-key-sha256=\(status.publicKeySHA256 ?? "none")",
        ].joined(separator: "; ")
    }

    private static func runLifecycle(_ action: BridgeLifecycleAction) async throws {
        let paths = try BridgeInstallPaths.production(
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let serviceState = paths.state.appending(path: "service", directoryHint: .isDirectory)
        let installer = BridgeServiceInstaller(
            paths: paths,
            launchctl: LaunchctlClient(),
            signatureVerifier: CodeSignBridgeBundleSignatureVerifier(),
            identityProvisioner: TLSIdentityProvisioner(keychain: SystemTLSIdentityKeychain()),
            healthCheck: { BridgeSupervisor.isReady(stateDirectory: serviceState) }
        )
        switch action {
        case let .install(bundle, codexExecutable, bindHost, advertisedHost):
            try await installer.install(
                bundle: bundle,
                codexExecutable: codexExecutable,
                bindHost: bindHost,
                advertisedHost: advertisedHost
            )
            print("bridge-version=\(bridgeVersion); install=ok")
        case .status:
            print(installationStatusDescription(try await installer.status()))
        case let .uninstall(purgeData):
            try await installer.uninstall(purgeData: purgeData)
            print("bridge-version=\(bridgeVersion); uninstall=ok; purged-data=\(purgeData)")
        case .rotateIdentity:
            let fingerprint = try await installer.rotateIdentity()
            print("bridge-version=\(bridgeVersion); rotate-identity=ok; public-key-sha256=\(fingerprint)")
        }
    }

    private static func runService(
        paths: BridgeRuntimePaths,
        options: [String: String],
        retryMemoID: MemoID?
    ) async throws {
        guard let codexPath = options["codex"] else {
            throw BridgeCommandError.invalidConfiguration
        }
        if retryMemoID == nil {
            guard options["bind-host"] != nil, options["advertised-host"] != nil else {
                throw BridgeCommandError.invalidConfiguration
            }
        }

        try paths.prepareRoot()
        try paths.prepareCodexInbox()
        try preparePrivateServiceDirectory(paths.service)
        let diagnostics = try BridgeDiagnosticLog(directory: paths.service)
        let intake = try IntakeStore(
            rootURL: paths.intake,
            retentionRootURL: paths.retained
        )
        let journal = try DeliveryJournal(root: paths.delivery)
        let finalStatuses = try FinalDeliveryStatusStore(
            rootURL: paths.root.appending(path: "final-status", directoryHint: .isDirectory)
        )
        try await reconcileFinalDeliveryCapacity(
            intake: intake,
            finalStatuses: finalStatuses
        )
        let retention = try BridgeDeliveredRetentionController(
            intakeStore: intake,
            journal: journal
        )
        if retryMemoID == nil {
            do {
                _ = try await withExclusiveRetentionLease(stateDirectory: paths.service) {
                    try await retention.performMaintenance()
                }
            } catch {
                _ = diagnostics.append(.retentionMaintenanceFailed)
                throw error
            }
        }
        let inbox = try AppServerInboxClient(
            codexExecutableURL: URL(fileURLWithPath: codexPath),
            neutralDirectory: paths.codexInbox
        )
        let processor = MemoProcessor(journal: journal, transcriber: AppleSpeechTranscriber(), inbox: inbox)
        let completionPublisher = DeliveryCompletionPublisher(
            intakeStore: intake,
            journal: journal,
            finalStatusStore: finalStatuses,
            retainDelivered: { memoID in
                try await runDeliveredRetentionMaintenance(
                    diagnosticSink: { event in _ = diagnostics.append(event) }
                ) {
                    try await withExclusiveRetentionLease(stateDirectory: paths.service) {
                        try await retention.retainDelivered(memoID)
                        _ = try await retention.performMaintenance()
                    }
                }
            }
        )
        let pendingProcessor = BoundedIntakeMemoProcessor(
            intakeStore: intake,
            processor: processor,
            retryMailbox: OperatorRetryMailbox(stateDirectory: paths.service),
            onDelivered: { memoID in
                try await completionPublisher.publishAndRetain(memoID)
            }
        )
        if let retryMemoID {
            // ponytail: operator retry does not take the listener lease; it
            // transcribes one durable memo in this process (GUI Speech TCC).
            try await pendingProcessor.retryCommitted(retryMemoID)
            return
        }
        guard let bindHost = options["bind-host"],
              let advertisedHost = options["advertised-host"]
        else { throw BridgeCommandError.invalidConfiguration }
        let identityProvider = try tlsIdentityProvider(
            options: options,
            stateDirectory: paths.service
        )
        let pairing = try PairingStore(secretStore: KeychainSecretStore())
        let configuration = try BridgeConfiguration()
        let replayStore = try DurableReplayNonceStore(
            rootURL: paths.service.appendingPathComponent("replay-nonces", isDirectory: true)
        )
        let router = try BridgeRequestRouter(
            pairingStore: pairing,
            intakeStore: intake,
            deliveryJournal: journal,
            finalStatusStore: finalStatuses,
            allowedClockSkew: configuration.allowedClockSkew,
            replayRetention: 10 * 60,
            replayStore: replayStore,
            onCommitted: { record in await pendingProcessor.admit(record) },
            minimumAvailableBytes: 128 * 1_024 * 1_024,
            availableBytes: { availableBytes(at: paths.root) }
        )
        let supervisor = try BridgeSupervisor(
            stateDirectory: paths.service,
            availableBytes: { availableBytes(at: paths.root) },
            recovery: IntakeStoreRecovery(rootURL: paths.intake),
            processor: pendingProcessor,
            listenerFactory: {
                let listener = try NetworkBridgeListener(
                    configuration: configuration,
                    router: router,
                    identityProvider: identityProvider,
                    serviceName: CodexWatchBrand.productName,
                    bindHost: bindHost,
                    advertisedHost: advertisedHost
                )
                return NetworkBridgeListenerController(listener: listener)
            },
            diagnosticSink: { event in _ = diagnostics.append(event) }
        )
        let signalLifetime = SignalLifetime()
        defer {
            signalLifetime.sources.forEach { $0.cancel() }
            withExtendedLifetime(signalLifetime) {}
        }
        let retentionTask = Task {
            await BridgeRetentionMaintenanceLoop.run(
                onFailure: {
                    _ = diagnostics.append(.retentionMaintenanceFailed)
                    FileHandle.standardError.write(Data(
                        "codex-watch-bridge: retention maintenance failed; will retry\n".utf8
                    ))
                },
                maintenance: {
                    _ = try await withExclusiveRetentionLease(stateDirectory: paths.service) {
                        try await retention.performMaintenance()
                    }
                }
            )
        }
        do {
            try await BridgeRuntimeBootstrap.start(supervisor: supervisor) {
                signal(SIGINT, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
                signalLifetime.sources = [SIGINT, SIGTERM].map { signalNumber in
                    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                    source.setEventHandler {
                        Task {
                            await supervisor.shutdown()
                        }
                    }
                    source.resume()
                    return source
                }
            }
        } catch {
            retentionTask.cancel()
            await retentionTask.value
            throw error
        }
        retentionTask.cancel()
        await retentionTask.value
    }

    private static func requiredRoot(_ options: [String: String]) throws -> URL {
        guard let root = options["state-root"], root.hasPrefix("/") else {
            throw BridgeCommandError.usage
        }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    }

    static func tlsIdentityProvider(
        options: [String: String],
        keychain: (any TLSIdentityKeychain)? = nil,
        stateDirectory: URL? = nil
    ) throws -> any BridgeTLSIdentityProvider {
        let p12Path = options["identity-p12"]
        let passwordPath = options["identity-password-file"]
        if p12Path == nil, passwordPath == nil {
            if let stateDirectory, let persisted = try PersistedTLSIdentity.provider(
                stateDirectory: stateDirectory
            ) {
                return persisted
            }
            let provider = KeychainTLSIdentityProvider(
                keychain: keychain ?? SystemTLSIdentityKeychain()
            )
            if let stateDirectory {
                persistKeychainIdentity(provider, to: stateDirectory)
            }
            return provider
        }
        guard let p12Path, let passwordPath else {
            throw BridgeCommandError.invalidConfiguration
        }
        let password = try SecureLocalFile.readUTF8PrivateFile(
            at: URL(fileURLWithPath: passwordPath)
        ).trimmingCharacters(in: .newlines)
        guard !password.isEmpty else { throw BridgeCommandError.invalidConfiguration }
        return PKCS12TLSIdentityProvider(
            p12URL: URL(fileURLWithPath: p12Path),
            password: password
        )
    }

    private static func persistKeychainIdentity(
        _ provider: KeychainTLSIdentityProvider,
        to stateDirectory: URL
    ) {
        try? provider.persistToStateDirectory(stateDirectory)
    }

    static func rotateIdentityWhileServiceStopped(
        stateDirectory: URL,
        revokePairing: @escaping @Sendable () async throws -> Void,
        rotateIdentity: @escaping @Sendable () async throws -> Void
    ) async throws {
        try preparePrivateServiceDirectory(stateDirectory)
        try await withExclusiveServiceLease(stateDirectory: stateDirectory) {
            try await revokePairing()
            try await rotateIdentity()
        }
    }

    static func runDeliveredRetentionMaintenance(
        diagnosticSink: @escaping @Sendable (BridgeDiagnosticEvent) -> Void,
        maintenance: @escaping @Sendable () async throws -> Void
    ) async throws {
        do {
            try await maintenance()
        } catch {
            diagnosticSink(.retentionMaintenanceFailed)
            throw error
        }
    }

    static func reconcileFinalDeliveryCapacity(
        intake: IntakeStore,
        finalStatuses: FinalDeliveryStatusStore
    ) async throws {
        var identities: [MemoID: String] = [:]
        var cursor: MemoID?
        repeat {
            let page = try await intake.committedRecordPage(
                maximumEntries: 256,
                afterMemoID: cursor
            )
            for record in page.records {
                guard identities.updateValue(
                    record.receipt.audioSHA256,
                    forKey: record.memoID
                ) == nil else {
                    throw BridgeCommandError.invalidConfiguration
                }
            }
            guard page.hasMore else { break }
            guard let next = page.records.last?.memoID, next != cursor else {
                throw BridgeCommandError.invalidConfiguration
            }
            cursor = next
        } while true
        try await finalStatuses.reconcileCapacityReservations(with: identities)
    }

    private static func parse(arguments: [String]) throws -> [String: String] {
        guard arguments.count.isMultiple(of: 2) else { throw BridgeCommandError.usage }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard key.hasPrefix("--"), options[key.dropFirst(2).description] == nil else {
                throw BridgeCommandError.usage
            }
            options[String(key.dropFirst(2))] = arguments[index + 1]
        }
        return options
    }

    static func withExclusiveServiceLease<T: Sendable>(
        stateDirectory: URL,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let lease = BridgeServiceLease(stateDirectory: stateDirectory)
        do {
            try lease.acquire()
        } catch {
            throw BridgeCommandError.invalidConfiguration
        }
        defer { lease.release() }
        return try await operation()
    }

    static func withExclusiveRetentionLease<T: Sendable>(
        stateDirectory: URL,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try preparePrivateServiceDirectory(stateDirectory)
        let lockURL = stateDirectory.standardizedFileURL.appendingPathComponent("retention.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw BridgeCommandError.invalidConfiguration }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { throw BridgeCommandError.invalidConfiguration }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await operation()
    }

    private static func preparePrivateServiceDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch CocoaError.fileWriteFileExists {
            // Validate the existing path below.
        } catch {
            throw BridgeCommandError.invalidConfiguration
        }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0
        else { throw BridgeCommandError.invalidConfiguration }
    }

    private static func availableBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static func pairingInstructions(
        code: String,
        publicKeySHA256: String
    ) throws -> String {
        guard PairingCode(rawValue: code) != nil else {
            throw BridgeCommandError.invalidConfiguration
        }
        let pin = try CertificatePin(publicKeySHA256)
        return """
        Certificate phrase: \(pin.comparisonPhrase)
        Pairing code: \(code)
        """
    }

    static func speechAuthorizationInstructions(
        for status: BridgeSpeechAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined:
            return "Speech authorization: not determined. Run authorize-speech to show the macOS permission prompt."
        case .authorized:
            return "Speech authorization: authorized. On-device recognition availability is checked per locale and memo."
        case .denied:
            return "Speech authorization: denied. Enable Speech Recognition for \(CodexWatchBrand.productName) in System Settings."
        case .restricted:
            return "Speech authorization: restricted by macOS policy."
        }
    }

    static func operationalStatusDescription(
        paths: BridgeRuntimePaths,
        speechStatus: BridgeSpeechAuthorizationStatus
    ) throws -> String {
        let supervisor = try BridgeSupervisor.persistedStatus(stateDirectory: paths.service)
        let listener = supervisor.state == .running ? "online" : "offline"
        let speech = switch speechStatus {
        case .notDetermined: "not-determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        }
        let committed = try durableMemoCount(at: paths.intake, permitsIncoming: true)
        let retained = try durableMemoCount(at: paths.retained, permitsIncoming: false)
        return [
            "bridge-version=\(bridgeVersion)",
            "protocol-version=\(BridgeProtocolVersion.current.major)",
            "state=\(supervisor.state.rawValue)",
            "listener=\(listener)",
            "speech=\(speech)",
            "committed=\(committed)",
            "retained=\(retained)",
        ].joined(separator: "; ")
    }

    private static func durableMemoCount(
        at directory: URL,
        permitsIncoming: Bool
    ) throws -> Int {
        var rootMetadata = stat()
        guard lstat(directory.path, &rootMetadata) == 0 else {
            if errno == ENOENT { return 0 }
            throw BridgeCommandError.invalidConfiguration
        }
        guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
              rootMetadata.st_uid == getuid(),
              rootMetadata.st_mode & 0o077 == 0
        else { throw BridgeCommandError.invalidConfiguration }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw BridgeCommandError.invalidConfiguration
        }
        var count = 0
        for child in children {
            if permitsIncoming, child.lastPathComponent.hasPrefix(".incoming-") {
                continue
            }
            guard (try? MemoID(child.lastPathComponent)) != nil else {
                throw BridgeCommandError.invalidConfiguration
            }
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & 0o077 == 0
            else { throw BridgeCommandError.invalidConfiguration }
            count += 1
        }
        return count
    }

    static func requestSpeechAuthorization(
        _ requester: (@escaping @Sendable (BridgeSpeechAuthorizationStatus) -> Void) -> Void
    ) async -> BridgeSpeechAuthorizationStatus {
        await withCheckedContinuation { continuation in
            requester { status in continuation.resume(returning: status) }
        }
    }

    static func retryMemoNow(
        memoID: MemoID,
        stateRoot: URL,
        codexPath: String
    ) async throws {
        let paths = try BridgeRuntimePaths(root: stateRoot)
        try await runService(
            paths: paths,
            options: ["codex": codexPath],
            retryMemoID: memoID
        )
    }

    static func requestSystemSpeechAuthorization() async -> BridgeSpeechAuthorizationStatus {
        await requestSpeechAuthorization { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(BridgeSpeechAuthorizationStatus(status))
            }
        }
    }

}

enum BridgeLaunchMode {
    static func isCommandLine(arguments: [String]) -> Bool {
        arguments.contains { argument in
            !argument.hasPrefix("-psn_") && argument != "-NSDocumentRevisionsDebugMode"
        }
    }
}

struct LaunchAgentRuntimeConfiguration: Equatable, Sendable {
    var bindHost: String
    var advertisedHost: String
    var stateRoot: URL
    var codexExecutable: URL

    static func parse(programArguments: [String]) -> Self? {
        let arguments: [String]
        if programArguments.first == "run" {
            arguments = Array(programArguments.dropFirst())
        } else if programArguments.count > 1, programArguments[1] == "run" {
            arguments = Array(programArguments.dropFirst(2))
        } else {
            return nil
        }
        guard arguments.count.isMultiple(of: 2) else { return nil }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard key.hasPrefix("--"), options[key] == nil else { return nil }
            options[key] = arguments[index + 1]
        }
        guard let stateRoot = options["--state-root"], stateRoot.hasPrefix("/"),
              let codex = options["--codex"], codex.hasPrefix("/"),
              let bindHost = options["--bind-host"], !bindHost.isEmpty,
              let advertisedHost = options["--advertised-host"], !advertisedHost.isEmpty
        else { return nil }
        return Self(
            bindHost: bindHost,
            advertisedHost: advertisedHost,
            stateRoot: URL(fileURLWithPath: stateRoot, isDirectory: true),
            codexExecutable: URL(fileURLWithPath: codex)
        )
    }

    static func load(plist url: URL) -> Self? {
        guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String]
        else { return nil }
        return parse(programArguments: arguments)
    }
}
