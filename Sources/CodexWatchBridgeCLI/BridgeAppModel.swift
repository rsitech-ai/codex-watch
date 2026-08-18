import AppKit
import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import CodexWatchCore
import Foundation
import Speech
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var listenerOnline = false
    @Published private(set) var listenerPaused = false
    @Published private(set) var watchPaired = false
    @Published private(set) var speech: BridgeSpeechAuthorizationStatus = .notDetermined
    @Published private(set) var advertisedName = CodexWatchBrand.productName
    @Published private(set) var advertisedHost = "—"
    @Published private(set) var bindHost = "—"
    @Published private(set) var currentHosts: [String] = []
    @Published private(set) var launchAgentPID: pid_t?
    @Published private(set) var tlsFingerprintShort = "unknown"
    @Published private(set) var lastDiagnostic: BridgeDiagnosticEvent?
    @Published private(set) var loaded = false
    @Published private(set) var healthy = false
    @Published private(set) var operatorStatus: BridgeOperatorStatusPresentation?
    @Published var resetConfirmationPresented = false
    @Published private(set) var rebindBusy = false
    @Published private(set) var resetBusy = false
    @Published private(set) var stateRootPath = "—"
    @Published private(set) var items: [MacInboxItem] = []
    @Published private(set) var pairing: PairingChallengePresentation?
    @Published var selectedMemoID: MemoID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var speechBusy = false
    @Published private(set) var pairingBusy = false
    @Published private(set) var specBusy = false
    @Published var pairingSheetPresented = false

    private let logger = Logger(
        subsystem: "ai.rsitech.codexwatch.bridge",
        category: "app"
    )
    private var refreshTask: Task<Void, Never>?
    private let pollsRuntime: Bool
    private var specImproveAttempted: Set<MemoID> = []

    init(pollsRuntime: Bool = true) {
        self.pollsRuntime = pollsRuntime
    }

    var selectedItem: MacInboxItem? {
        items.first { $0.id == selectedMemoID }
    }

    var selectedPresentation: MacInboxItemPresentation? {
        selectedItem.map { MacInboxItemPresentation.make(item: $0, speech: speech) }
    }

    var statusHierarchy: BridgeConsoleStatusHierarchy {
        BridgeConsoleStatusHierarchy.make(header: header, selected: selectedPresentation)
    }

    var canSaveSelectedSpec: Bool {
        selectedPresentation?.showsSpecDownload == true
    }

    var header: BridgeConsoleHeaderPresentation {
        BridgeConsoleHeaderPresentation.make(
            installed: installed,
            listenerOnline: listenerOnline,
            listenerPaused: listenerPaused,
            watchPaired: watchPaired,
            speech: speech,
            advertisedName: advertisedName,
            latest: items.first,
            bindHost: bindHost,
            currentHosts: currentHosts
        )
    }

    func start() {
        guard pollsRuntime else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        speech = BridgeSpeechAuthorizationStatus(SFSpeechRecognizer.authorizationStatus())
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            stateRootPath = install.state.path
            let runtime = LaunchAgentRuntimeConfiguration.load(plist: install.launchAgent)
            advertisedName = CodexWatchBrand.productName
            advertisedHost = runtime?.advertisedHost ?? "—"
            bindHost = runtime?.bindHost ?? "—"
            currentHosts = WatchReachableAddress.currentIPv4Hosts()
            installed = FileManager.default.fileExists(atPath: install.application.path)
                && FileManager.default.fileExists(atPath: install.launchAgent.path)
            let paths = try BridgeRuntimePaths(root: install.state)
            let supervisor = try BridgeSupervisor.persistedStatus(stateDirectory: paths.service)
            listenerPaused = supervisor.state == .paused
            listenerOnline = supervisor.state == .running
            loaded = BridgeServiceLease.isLive(stateDirectory: paths.service)
            healthy = BridgeSupervisor.isReady(stateDirectory: paths.service)
            launchAgentPID = Self.readinessPID(service: paths.service)
            tlsFingerprintShort = Self.shortFingerprint(
                try? String(
                    contentsOf: install.state.appending(path: ".identity-public-key-sha256"),
                    encoding: .utf8
                )
            )
            lastDiagnostic = BridgeDiagnosticLog.lastEvent(in: paths.service)
            items = await loadInbox(paths: paths)
            if selectedMemoID == nil {
                selectedMemoID = items.first?.id
            } else if let selectedMemoID, !items.contains(where: { $0.id == selectedMemoID }) {
                self.selectedMemoID = items.first?.id
            }
            // Keychain pairing can prompt a newly signed UI; don't hide the inbox behind it.
            watchPaired = await isWatchPaired()
            operatorStatus = BridgeOperatorStatusPresentation.make(
                loaded: loaded,
                healthy: healthy,
                bindHost: bindHost,
                advertisedHost: advertisedHost,
                currentHosts: currentHosts,
                fingerprint: try? String(
                    contentsOf: install.state.appending(path: ".identity-public-key-sha256"),
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines),
                launchAgentPID: launchAgentPID,
                lastEvent: lastDiagnostic,
                watchPaired: watchPaired,
                lastIntake: items.first?.capturedAt,
                speech: speech,
                foundationModels: FoundationModelsAvailability.current()
            )
            logger.info("bridge console refreshed")
        } catch {
            listenerOnline = false
            items = []
            operatorStatus = nil
            logger.error("bridge console refresh failed")
        }
    }

    func generatePairingCode() async {
        pairingBusy = true
        defer { pairingBusy = false }
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let fingerprint = try String(
                contentsOf: install.state.appending(path: ".identity-public-key-sha256"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let pin = try CertificatePin(fingerprint)
            let store = try PairingStore(secretStore: KeychainSecretStore())
            let challenge = try await store.beginPairing(
                validFor: BridgeCommand.pairingChallengeLifetime
            )
            pairing = PairingChallengePresentation(
                phrase: pin.comparisonPhrase,
                code: challenge.code,
                expiresAt: challenge.expiresAt
            )
            pairingSheetPresented = true
            statusMessage = nil
            logger.info("pairing challenge generated")
        } catch {
            statusMessage = listenerOnline
                ? "Couldn’t read the Mac certificate phrase from bridge state."
                : "Couldn’t generate a pairing code. Install the bridge and try again."
            logger.error("pairing challenge failed")
        }
    }

    func authorizeSpeech() async {
        speechBusy = true
        defer { speechBusy = false }
        let status = await BridgeCommand.requestSystemSpeechAuthorization()
        speech = status
        statusMessage = BridgeSpeechCopy.blockedDetail(for: status)
        logger.info("speech authorization finished")
    }

    func retrySelected() async {
        guard let item = selectedItem else { return }
        let needsTranscription = item.transcript == nil
        let needsCodexInsert = item.state == .readyForCodex && item.transcript != nil
        guard needsTranscription || needsCodexInsert else { return }
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let paths = try BridgeRuntimePaths(root: install.state)
            if let runtime = LaunchAgentRuntimeConfiguration.load(plist: install.launchAgent),
               !needsTranscription || speech == .authorized
            {
                statusMessage = needsTranscription
                    ? "Transcribing on this Mac…"
                    : "Submitting the local transcript to Codex…"
                try await BridgeCommand.retryMemoNow(
                    memoID: item.id,
                    stateRoot: install.state,
                    codexPath: runtime.codexExecutable.path
                )
                await refresh()
                if needsTranscription, selectedItem?.transcript == nil {
                    statusMessage = "Transcription still did not finish. Speech in this window is allowed; the local recognizer rejected the audio or locale."
                } else if selectedItem?.state == .readyForCodex {
                    statusMessage = "Codex did not confirm the Inbox item. The official Codex app and App Server must accept a local insert."
                } else {
                    statusMessage = nil
                }
                logger.info("operator retry finished in-process")
                return
            }
            try OperatorRetryMailbox(stateDirectory: paths.service).enqueue(item.id)
            statusMessage = listenerOnline
                ? "Retry queued for the running bridge."
                : "Retry queued. It runs when the Mac listener is online."
            logger.info("operator retry queued")
        } catch {
            statusMessage = "Couldn’t retry this memo from the Codex Watch window."
            logger.error("operator retry failed")
        }
    }

    func improveSelectedSpecIfNeeded() async {
        guard let item = selectedItem,
              let transcript = item.transcript,
              item.specProvenance != .appServer,
              item.specProvenance != .foundationModels,
              specImproveAttempted.insert(item.id).inserted
        else { return }
        specBusy = true
        defer { specBusy = false }
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let paths = try BridgeRuntimePaths(root: install.state)
            let specStore = MemoSpecStore(root: paths.delivery)
            if specStore.load(memoID: item.id) == nil {
                try specStore.save(
                    MemoSpecDocument.localFallback(
                        transcript: transcript,
                        capturedAt: item.capturedAt,
                        memoID: item.id
                    ),
                    memoID: item.id
                )
                await refresh()
            }
            guard let runtime = LaunchAgentRuntimeConfiguration.load(plist: install.launchAgent) else {
                return
            }
            let inbox = try AppServerInboxClient(
                codexExecutableURL: runtime.codexExecutable,
                neutralDirectory: paths.codexInbox
            )
            statusMessage = "Improving spec…"
            let spec = await MemoSpecImprover(
                foundationModels: FoundationModelsSpecImprover.liveIfAvailable(),
                appServer: inbox
            ).improve(
                transcript: transcript,
                capturedAt: item.capturedAt,
                memoID: item.id
            )
            try specStore.save(spec, memoID: item.id)
            statusMessage = spec.provenance == .localFallback
                ? "Spec stayed an unverified local wrapper."
                : nil
            await refresh()
        } catch {
            if statusMessage == "Improving spec…" {
                statusMessage = nil
            }
            logger.error("spec improvement fell back locally")
        }
    }

    func saveSelectedSpec(asHTML: Bool) {
        guard let item = selectedItem else { return }
        let markdown: String
        if let existing = item.specMarkdown, !existing.isEmpty {
            markdown = existing
        } else if let transcript = item.transcript {
            markdown = MemoSpecDocument.localFallback(
                transcript: transcript,
                capturedAt: item.capturedAt,
                memoID: item.id
            ).markdown
        } else {
            statusMessage = "This memo has no transcript to save as a spec."
            return
        }
        let spec = MemoSpec(
            markdown: markdown,
            provenance: item.specProvenance ?? .localFallback
        )
        let title = spec.title
        let contents = asHTML
            ? MemoSpecDocument.html(markdown: spec.markdown, title: title)
            : MemoSpecDocument.serialized(spec)
        presentSavePanel(
            asHTML: asHTML,
            filename: sanitizedFilename(title),
            contents: contents
        )
    }

    private func presentSavePanel(asHTML: Bool, filename: String, contents: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if asHTML {
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = "\(filename).html"
            panel.title = BridgeFileMenuCopy.saveHTML
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(filename).md"
            panel.title = BridgeFileMenuCopy.saveSpec
        }
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    self.writeSpec(contents, to: url)
                }
            }
        } else {
            guard panel.runModal() == .OK, let url = panel.url else { return }
            writeSpec(contents, to: url)
        }
    }

    private func writeSpec(_ contents: String, to url: URL) {
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            statusMessage = nil
        } catch {
            statusMessage = "Couldn’t save the spec to that location."
        }
    }

    func performHeaderAction() async {
        switch header.primaryTitle {
        case "Allow Speech Recognition":
            await authorizeSpeech()
        case "Open Speech Settings":
            openSpeechSettings()
        case "Generate pairing code":
            await generatePairingCode()
        case "Retry transcription":
            await retrySelected()
        case "Use current address":
            await rebindToCurrentAddress()
        default:
            break
        }
    }

    func presentResetConfirmation() {
        resetConfirmationPresented = true
    }

    func cancelReset() {
        resetConfirmationPresented = false
    }

    func performReset(confirmed: Bool, forgetDisplayedPairing: Bool) async {
        resetConfirmationPresented = false
        guard BridgeResetGate.allow(confirmed) else { return }
        resetBusy = true
        defer { resetBusy = false }
        guard pollsRuntime else {
            if forgetDisplayedPairing {
                pairing = nil
                pairingSheetPresented = false
            }
            return
        }
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let paths = try BridgeRuntimePaths(root: install.state)
            _ = try OperatorRetryMailbox(stateDirectory: paths.service).takeAll()
            let store = try PairingStore(secretStore: KeychainSecretStore())
            if forgetDisplayedPairing {
                try await store.clearDisplayedChallenge()
                pairing = nil
                pairingSheetPresented = false
            } else {
                await generatePairingCode()
            }
            statusMessage = forgetDisplayedPairing
                ? "Cleared the displayed pairing code and retry mailbox. Watch Keychain was not wiped."
                : "Regenerated the pairing code and cleared the retry mailbox."
            await refresh()
        } catch {
            statusMessage = "Couldn’t reset operator state on this Mac."
        }
    }

    func rebindToCurrentAddress() async {
        rebindBusy = true
        defer { rebindBusy = false }
        guard let host = WatchReachableAddress.preferredHost(),
              NetworkBridgeListener.isValidWatchReachableBindHost(host),
              NetworkBridgeListener.isValidWatchReachableAdvertisedHost(host)
        else {
            statusMessage = "Couldn’t find a Watch-reachable address on this Mac."
            return
        }
        do {
            try await Self.productionInstaller().rebind(bindHost: host, advertisedHost: host)
            statusMessage = "Listener rebound to \(host) without rotating TLS."
            await refresh()
        } catch {
            statusMessage = "Couldn’t rebind the listener to this Mac’s current address."
        }
    }

    func openSpeechSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func isWatchPaired() async -> Bool {
        do {
            let store = try PairingStore(secretStore: KeychainSecretStore())
            return try await store.currentCredential() != nil
        } catch {
            return false
        }
    }

    private func loadInbox(paths: BridgeRuntimePaths) async -> [MacInboxItem] {
        let intakeStore: IntakeStore
        do {
            intakeStore = try IntakeStore(
                rootURL: paths.intake,
                retentionRootURL: paths.retained
            )
        } catch {
            return []
        }
        var intake: [CommittedIntakeRecord] = []
        var intakeAfter: MemoID?
        do {
            repeat {
                let page = try await intakeStore.committedRecordPage(
                    maximumEntries: 64,
                    afterMemoID: intakeAfter
                )
                intake.append(contentsOf: page.records)
                guard page.hasMore, let last = page.records.last?.memoID, last != intakeAfter else {
                    break
                }
                intakeAfter = last
            } while intake.count < 256
        } catch {
            return []
        }

        var retained: [RetainedIntakeRecord] = []
        var retainedAfter: MemoID?
        do {
            repeat {
                let page = try await intakeStore.retainedRecordPage(
                    maximumEntries: 64,
                    afterMemoID: retainedAfter
                )
                retained.append(contentsOf: page.records)
                guard page.hasMore, let last = page.records.last?.memoID, last != retainedAfter else {
                    break
                }
                retainedAfter = last
            } while retained.count < 256
        } catch {
            retained = []
        }

        let journal: DeliveryJournal
        do {
            journal = try DeliveryJournal(root: paths.delivery)
        } catch {
            return MacInboxSnapshot.items(intake: intake, journals: [:], retained: retained)
        }
        var journals: [MemoID: DeliveryRecord] = [:]
        for id in intake.map(\.memoID) + retained.map(\.memoID) {
            if let record = try? journal.load(memoID: id) {
                journals[id] = record
            }
        }
        let specStore = MemoSpecStore(root: paths.delivery)
        var specs: [MemoID: MemoSpec] = [:]
        for id in intake.map(\.memoID) + retained.map(\.memoID) {
            let journalRecord = journals[id]
            if let existing = specStore.load(memoID: id) {
                specs[id] = existing
            } else if let transcript = journalRecord?.transcript {
                let spec = MemoSpecDocument.localFallback(
                    transcript: transcript,
                    capturedAt: journalRecord?.capturedAt ?? .distantPast,
                    memoID: id
                )
                try? specStore.save(spec, memoID: id)
                specs[id] = spec
            }
        }
        return MacInboxSnapshot.items(
            intake: intake,
            journals: journals,
            retained: retained,
            specs: specs
        )
    }

    private func sanitizedFilename(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = trimmed.replacingOccurrences(of: "/", with: "-")
        return collapsed.isEmpty ? "voice-memo" : collapsed
    }

    func seedPreview(_ kind: PreviewKind) {
        installed = true
        listenerOnline = true
        listenerPaused = false
        speech = .authorized
        advertisedName = CodexWatchBrand.productName
        advertisedHost = "192.168.1.10"
        bindHost = "192.168.1.10"
        currentHosts = ["192.168.1.10"]
        loaded = true
        healthy = true
        launchAgentPID = 4242
        tlsFingerprintShort = "01234567"
        lastDiagnostic = .serviceRunning
        stateRootPath = "~/Library/Application Support/CodexWatch/State"
        statusMessage = nil
        pairing = nil
        pairingSheetPresented = false
        switch kind {
        case .delivered:
            watchPaired = true
            items = [Self.previewItem(state: .delivered, spec: true)]
            selectedMemoID = items.first?.id
        case .needsAttention:
            watchPaired = true
            speech = .notDetermined
            items = [Self.previewItem(state: .needsAttention, spec: false)]
            selectedMemoID = items.first?.id
        case .unpaired:
            watchPaired = false
            items = []
            selectedMemoID = nil
            pairing = PairingChallengePresentation(
                phrase: "cedar-orbit-quartz",
                code: "482917",
                expiresAt: Date().addingTimeInterval(8 * 60)
            )
            pairingSheetPresented = true
        case .empty:
            watchPaired = true
            items = []
            selectedMemoID = nil
        }
        operatorStatus = BridgeOperatorStatusPresentation.make(
            loaded: loaded,
            healthy: healthy,
            bindHost: bindHost,
            advertisedHost: advertisedHost,
            currentHosts: currentHosts,
            fingerprint: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            launchAgentPID: launchAgentPID,
            lastEvent: lastDiagnostic,
            watchPaired: watchPaired,
            lastIntake: items.first?.capturedAt,
            speech: speech,
            foundationModels: .unavailable("Preview uses the local wrapper.")
        )
    }

    private static func productionInstaller() throws -> BridgeServiceInstaller {
        let paths = try BridgeInstallPaths.production(
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let serviceState = paths.state.appending(path: "service", directoryHint: .isDirectory)
        return BridgeServiceInstaller(
            paths: paths,
            launchctl: LaunchctlClient(),
            signatureVerifier: CodeSignBridgeBundleSignatureVerifier(),
            identityProvisioner: TLSIdentityProvisioner(keychain: SystemTLSIdentityKeychain()),
            healthCheck: { BridgeSupervisor.isReady(stateDirectory: serviceState) }
        )
    }

    private static func readinessPID(service: URL) -> pid_t? {
        struct Ready: Decodable { var pid: pid_t }
        let url = service.appending(path: "service.ready")
        guard let data = try? Data(contentsOf: url),
              let ready = try? JSONDecoder().decode(Ready.self, from: data),
              ready.pid > 0
        else { return nil }
        return ready.pid
    }

    private static func shortFingerprint(_ raw: String?) -> String {
        guard let raw else { return "unknown" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count >= 8 else { return "unknown" }
        return String(value.prefix(8))
    }

    private static func previewItem(state: MemoState, spec: Bool) -> MacInboxItem {
        let id = try! MemoID("060b86cc-1111-1111-1111-111111111111")
        let transcript = spec ? "Far far away from the watch, capture this thought." : nil
        let specMarkdown: String?
        if let transcript {
            specMarkdown = MemoSpecDocument.localFallback(
                transcript: transcript,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                memoID: id
            ).markdown
        } else {
            specMarkdown = nil
        }
        return MacInboxItem(
            id: id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: state,
            transcript: transcript,
            audioIsPresent: true,
            isRetained: state == .delivered,
            specMarkdown: specMarkdown,
            specProvenance: specMarkdown == nil ? nil : .localFallback
        )
    }

    enum PreviewKind {
        case delivered
        case needsAttention
        case unpaired
        case empty
    }
}
