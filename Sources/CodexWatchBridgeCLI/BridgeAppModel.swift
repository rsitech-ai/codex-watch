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
    @Published private(set) var stateRootPath = "—"
    @Published private(set) var items: [MacInboxItem] = []
    @Published private(set) var pairing: PairingChallengePresentation?
    @Published var selectedMemoID: MemoID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var speechBusy = false
    @Published private(set) var pairingBusy = false
    @Published private(set) var specBusy = false

    private let logger = Logger(
        subsystem: "ai.rsitech.voiceinbox.bridge",
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

    var header: BridgeConsoleHeaderPresentation {
        BridgeConsoleHeaderPresentation.make(
            installed: installed,
            listenerOnline: listenerOnline,
            listenerPaused: listenerPaused,
            watchPaired: watchPaired,
            speech: speech,
            advertisedName: advertisedName,
            latest: items.first
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
            installed = FileManager.default.fileExists(atPath: install.application.path)
                && FileManager.default.fileExists(atPath: install.launchAgent.path)
            let paths = try BridgeRuntimePaths(root: install.state)
            let supervisor = try BridgeSupervisor.persistedStatus(stateDirectory: paths.service)
            listenerPaused = supervisor.state == .paused
            listenerOnline = supervisor.state == .running
            items = await loadInbox(paths: paths)
            if selectedMemoID == nil {
                selectedMemoID = items.first?.id
            } else if let selectedMemoID, !items.contains(where: { $0.id == selectedMemoID }) {
                self.selectedMemoID = items.first?.id
            }
            // Keychain pairing can prompt a newly signed UI; don't hide the inbox behind it.
            watchPaired = await isWatchPaired()
            logger.info("bridge console refreshed")
        } catch {
            listenerOnline = false
            items = []
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
            let markdown = try await inbox.improveSpec(memoID: item.id, transcript: transcript)
            if let improved = MemoSpecDocument.acceptAppServerMarkdown(markdown) {
                try specStore.save(improved, memoID: item.id)
                statusMessage = nil
                await refresh()
            } else {
                statusMessage = "Spec stayed an unverified local wrapper. Codex App Server did not return markdown."
            }
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
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if asHTML {
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = "\(sanitizedFilename(title)).html"
            panel.title = "Save HTML"
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "\(sanitizedFilename(title)).md"
            panel.title = "Save spec"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let contents = asHTML
            ? MemoSpecDocument.html(markdown: spec.markdown, title: title)
            : MemoSpecDocument.serialized(spec)
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
        default:
            break
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
        stateRootPath = "~/Library/Application Support/VoiceInboxBridge/State"
        statusMessage = nil
        pairing = nil
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
        case .empty:
            watchPaired = true
            items = []
            selectedMemoID = nil
        }
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
