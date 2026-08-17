import AppKit
import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import CodexWatchCore
import Foundation
import Speech
import SwiftUI
import os

@MainActor
final class BridgeAppModel: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var listenerOnline = false
    @Published private(set) var listenerPaused = false
    @Published private(set) var watchPaired = false
    @Published private(set) var speech: BridgeSpeechAuthorizationStatus = .notDetermined
    @Published private(set) var advertisedName = "Voice Inbox Bridge"
    @Published private(set) var advertisedHost = "—"
    @Published private(set) var bindHost = "—"
    @Published private(set) var stateRootPath = "—"
    @Published private(set) var items: [MacInboxItem] = []
    @Published private(set) var pairing: PairingChallengePresentation?
    @Published var selectedMemoID: MemoID?
    @Published private(set) var statusMessage: String?
    @Published private(set) var speechBusy = false
    @Published private(set) var pairingBusy = false

    private let logger = Logger(
        subsystem: "ai.rsitech.voiceinbox.bridge",
        category: "app"
    )
    private var refreshTask: Task<Void, Never>?

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
            advertisedName = "Voice Inbox Bridge"
            advertisedHost = runtime?.advertisedHost ?? "—"
            bindHost = runtime?.bindHost ?? "—"
            installed = FileManager.default.fileExists(atPath: install.application.path)
                && FileManager.default.fileExists(atPath: install.launchAgent.path)
            let paths = try BridgeRuntimePaths(root: install.state)
            let supervisor = try BridgeSupervisor.persistedStatus(stateDirectory: paths.service)
            listenerPaused = supervisor.state == .paused
            listenerOnline = supervisor.state == .running
            watchPaired = await isWatchPaired()
            items = await loadInbox(paths: paths)
            if selectedMemoID == nil {
                selectedMemoID = items.first?.id
            } else if let selectedMemoID, !items.contains(where: { $0.id == selectedMemoID }) {
                self.selectedMemoID = items.first?.id
            }
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
            let identity = try KeychainTLSIdentityProvider(
                keychain: SystemTLSIdentityKeychain()
            ).loadIdentity()
            let store = try PairingStore(secretStore: KeychainSecretStore())
            let challenge = try await store.beginPairing(
                validFor: BridgeCommand.pairingChallengeLifetime
            )
            let pin = try CertificatePin(identity.publicKeySHA256)
            pairing = PairingChallengePresentation(
                phrase: pin.comparisonPhrase,
                code: challenge.code,
                expiresAt: challenge.expiresAt
            )
            statusMessage = nil
            logger.info("pairing challenge generated")
        } catch {
            statusMessage = "Couldn’t generate a pairing code. Install the bridge and try again."
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
        guard let item = selectedItem, item.transcript == nil else { return }
        do {
            let install = try BridgeInstallPaths.production(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            let paths = try BridgeRuntimePaths(root: install.state)
            try OperatorRetryMailbox(stateDirectory: paths.service).enqueue(item.id)
            statusMessage = listenerOnline
                ? "Retry queued for the running bridge."
                : "Retry queued. It runs when the Mac listener is online."
            logger.info("operator retry queued")
        } catch {
            statusMessage = "Couldn’t queue a retry for this memo."
            logger.error("operator retry failed")
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
        return MacInboxSnapshot.items(intake: intake, journals: journals, retained: retained)
    }
}
