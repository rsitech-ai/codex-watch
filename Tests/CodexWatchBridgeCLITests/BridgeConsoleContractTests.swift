@testable import CodexWatchBridgeCLI
import CodexBridgeDelivery
import CodexBridgeService
import CodexBridgeShared
import Foundation
import Testing

@Test func macConsoleContractKeepsInboxPairingSpeechAndRetryAligned() async throws {
    let pairing = try PairingStore(secretStore: InMemorySecretStore())
    let challenge = try await pairing.beginPairing(validFor: BridgeCommand.pairingChallengeLifetime)
    let fingerprint = "0123456789abcdef" + String(repeating: "0", count: 48)
    let instructions = try BridgeCommand.pairingInstructions(
        code: challenge.code,
        publicKeySHA256: fingerprint
    )
    #expect(instructions.contains("Certificate phrase:"))
    #expect(instructions.contains("Pairing code: \(challenge.code)"))
    #expect(challenge.code.count == 6)

    let root = FileManager.default.temporaryDirectory.appending(
        path: "codexwatch-console-contract-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let memoID = try MemoID("12121212-1212-1212-1212-121212121212")
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_001)
    let audio = Data("console-contract-audio".utf8)
    let digest = AudioDigest.hex(audio)
    let audioURL = root.appending(path: "audio.m4a")
    try audio.write(to: audioURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: audioURL.path
    )
    let committedAudio = try CommittedAudioAsset(url: audioURL, expectedSHA256: digest)
    let receipt = try BridgeReceipt(
        memoID: memoID,
        audioSHA256: digest,
        acknowledgedRevision: 1,
        capturedAt: capturedAt,
        receivedAt: capturedAt
    )
    let journal = DeliveryRecord(
        memoID: memoID,
        capturedAt: capturedAt,
        localeHint: nil,
        audioSHA256: digest,
        state: .needsAttention,
        revision: 1,
        updatedAt: capturedAt,
        transcript: nil
    )
    let items = MacInboxSnapshot.items(
        intake: [
            CommittedIntakeRecord(
                memoID: memoID,
                receipt: receipt,
                committedAudio: committedAudio
            ),
        ],
        journals: [memoID: journal],
        retained: []
    )
    #expect(items.map(\.id) == [memoID])
    #expect(items[0].state == .needsAttention)
    #expect(items[0].transcript == nil)

    let presentation = MacInboxItemPresentation.make(item: items[0], speech: .notDetermined)
    #expect(presentation.retryEnabled == true)
    #expect(presentation.speechCTA == true)
    #expect(presentation.detail.contains("Speech Recognition"))
    #expect(!presentation.detail.contains("Voice Inbox"))

    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: items[0]
    )
    #expect(header.primaryTitle == "Allow Speech Recognition")
    #expect(header.spine.mac == .attention)
    #expect(header.spine.codex == .pending)
    #expect(CodexWatchBrand.productName == "Codex Watch")

    let mailbox = OperatorRetryMailbox(stateDirectory: root)
    try mailbox.enqueue(memoID)
    #expect(try mailbox.takeAll() == [memoID])
}

@Test func operatorResetSourceNeverRevokesWatchOrRotatesTLS() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/CodexWatchBridgeCLI/BridgeAppModel.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("guard BridgeResetGate.allow(confirmed) else { return }"))
    #expect(source.contains("clearDisplayedChallenge()"))
    #expect(source.contains("forgetDisplayedPairing"))
    #expect(!source.contains("revokeCredential()"))
    #expect(!source.contains("rotateIdentity()"))
}

@Test func settingsResetUsesTheSameConfirmationGateAsTheConsole() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/CodexWatchBridgeCLI/BridgeConsoleView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("func bridgeResetConfirmation(model: BridgeAppModel)"))
    #expect(source.contains(".bridgeResetConfirmation(model: model)"))
    #expect(source.contains("struct BridgeSettingsView"))
    #expect(source.contains("minHeight: 560"))
}

@Test @MainActor func macConsolePreviewHierarchyKeepsPairingOnWristAndSpecSaveObvious() {
    let model = BridgeAppModel(pollsRuntime: false)

    model.seedPreview(.delivered)
    #expect(model.canSaveSelectedSpec)
    #expect(model.watchPaired)
    #expect(model.statusHierarchy.chromeHeadline == "Saved to local Inbox")
    #expect(model.statusHierarchy.inspectorTitle == "Saved to local Inbox")
    #expect(model.statusHierarchy.repeatCount(of: "Saved to local Inbox") == 3)
    #expect(MemoSpecCopy.provenanceLabel(model.selectedItem?.specProvenance) == "Unverified local wrapper")
    #expect(model.header.primaryTitle == nil)
    #expect(
        BridgeConsoleToolbarPresentation.make(
            header: model.header,
            canSaveSelectedSpec: model.canSaveSelectedSpec
        ).showsSaveSpec
    )

    model.seedPreview(.needsAttention)
    #expect(model.watchPaired)
    #expect(model.header.primaryTitle == "Allow Speech Recognition")
    #expect(model.header.spine.codex == .pending)
    #expect(!model.canSaveSelectedSpec)
    #expect(
        BridgeConsoleToolbarPresentation.make(
            header: model.header,
            canSaveSelectedSpec: model.canSaveSelectedSpec
        ).showsHeaderPrimary
    )

    model.seedPreview(.unpaired)
    #expect(!model.watchPaired)
    #expect(model.pairingSheetPresented)
    #expect(model.pairing?.phrase == "cedar-orbit-quartz")
    #expect(model.pairing?.code == "482917")
    #expect(model.header.detail == BridgePairingCopy.onWristInstruction)

    model.seedPreview(.empty)
    #expect(model.watchPaired)
    #expect(model.items.isEmpty)
    #expect(model.header.spine.codex == .pending)
    #expect(!model.pairingSheetPresented)
}
