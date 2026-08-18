@testable import CodexWatchBridgeCLI
import CodexBridgeService
import CodexBridgeShared
import Foundation
import SwiftUI
import Testing

@Test func finderLaunchArgumentsOpenTheMacUIInsteadOfTheCLI() {
    #expect(BridgeLaunchMode.isCommandLine(arguments: []) == false)
    #expect(BridgeLaunchMode.isCommandLine(arguments: ["-psn_0_12345"]) == false)
    #expect(BridgeLaunchMode.isCommandLine(arguments: ["-NSDocumentRevisionsDebugMode"]) == false)
    #expect(BridgeLaunchMode.isCommandLine(arguments: ["run", "--state-root", "/tmp/state"]) == true)
    #expect(BridgeLaunchMode.isCommandLine(arguments: ["pair", "--state-root", "/tmp/state"]) == true)
}

@Test func launchAgentRuntimeConfigurationParsesInstalledProgramArguments() {
    let parsed = LaunchAgentRuntimeConfiguration.parse(programArguments: [
        "/tmp/VoiceInboxBridge.app/Contents/MacOS/codex-watch-bridge",
        "run",
        "--state-root", "/tmp/VoiceInboxBridge/State",
        "--codex", "/opt/homebrew/bin/codex",
        "--bind-host", "192.168.1.42",
        "--advertised-host", "192.168.1.42",
    ])

    #expect(parsed?.bindHost == "192.168.1.42")
    #expect(parsed?.advertisedHost == "192.168.1.42")
    #expect(parsed?.stateRoot.path == "/tmp/VoiceInboxBridge/State")
    #expect(parsed?.codexExecutable.path == "/opt/homebrew/bin/codex")
}

@Test func pairingExpiryCopyUsesMinuteSecondCountdownThenExpired() {
    let expiresAt = Date(timeIntervalSince1970: 100)
    #expect(
        PairingExpiryCopy.text(expiresAt: expiresAt, now: Date(timeIntervalSince1970: 40))
            == "Expires in 1:00"
    )
    #expect(
        PairingExpiryCopy.text(expiresAt: expiresAt, now: Date(timeIntervalSince1970: 100))
            == "Code expired. Generate a new code."
    )
}

@Test func inboxPresentationAsksForSpeechWhenTranscriptionIsBlocked() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .needsAttention,
        transcript: nil,
        audioIsPresent: true,
        isRetained: false
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .notDetermined)

    #expect(presentation.speechCTA == true)
    #expect(presentation.retryEnabled == true)
    #expect(presentation.tone == .attention)
    #expect(presentation.spine.mac == .attention)
    #expect(presentation.spine.codex == .pending)
    #expect(presentation.detail.contains("Speech Recognition"))
}

@Test func consoleHeaderDoesNotInventCodexProgressWhenIdleAndPaired() {
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: nil
    )

    #expect(header.spine.watch == .confirmed)
    #expect(header.spine.mac == .confirmed)
    #expect(header.spine.codex == .pending)
    #expect(header.primaryTitle == nil)
}

@Test func consoleHeaderKeepsRetryOnTheMemoNotTheSystemChrome() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .needsAttention,
        transcript: nil,
        audioIsPresent: true,
        isRetained: false
    )
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)

    #expect(header.headline == "Transcription did not finish.")
    #expect(header.headline != presentation.status)
    #expect(header.primaryTitle == nil)
    #expect(presentation.retryEnabled == true)
    #expect(header.spine.codex == .pending)
}

@Test func deliveredPresentationShowsSpecDownloadWhenSpecExists() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "Far far away from the watch",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: """
        # Far far away from the watch

        ## Summary
        Capture the thought.
        """,
        specProvenance: .appServer
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)

    #expect(presentation.showsSpecDownload == true)
    #expect(presentation.status == "Saved to local Inbox")
    #expect(presentation.detail.contains("Spec is ready to save"))
    #expect(presentation.detail.contains("Codex Inbox thread"))
    #expect(!presentation.detail.contains("ChatGPT"))
}

@Test func deliveredCopyNamesLocalInboxNotOfficialClient() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "local transcript",
        audioIsPresent: true,
        isRetained: true
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)

    #expect(presentation.status == "Saved to local Inbox")
    #expect(presentation.detail.contains("Codex Inbox thread"))
    #expect(!presentation.detail.contains("Codex delivery confirmed"))
    #expect(!presentation.status.contains("Delivered to Codex"))
}

@Test func readyForCodexKeepsInsertRetryOnTheMemo() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .readyForCodex,
        transcript: "local transcript",
        audioIsPresent: true,
        isRetained: false
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )

    #expect(presentation.retryEnabled == true)
    #expect(header.primaryTitle == nil)
    #expect(header.spine.codex == .pending)
    #expect(header.headline == "Ready for Codex")
}

@Test func consoleHeaderUsesSpeechCTAWhenAuthorizationIsNotDetermined() {
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: nil
    )

    #expect(header.primaryTitle == "Allow Speech Recognition")
    #expect(header.tone == .attention)
}

@Test func consoleStatusHierarchyKeepsDeliveredChromeAndInspectorTitle() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "Far far away from the watch",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Far far away\n",
        specProvenance: .localFallback
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )
    let hierarchy = BridgeConsoleStatusHierarchy.make(header: header, selected: presentation)

    #expect(presentation.status == "Saved to local Inbox")
    #expect(header.headline == presentation.status)
    #expect(hierarchy.chromeHeadline == presentation.status)
    #expect(hierarchy.inspectorTitle == presentation.status)
    #expect(hierarchy.listStatus == presentation.status)
    #expect(BridgeExperienceTheme.TypeRole.inspectorTitle == Font.title2.weight(.bold))
}

@Test func consoleStatusHierarchyKeepsDistinctChromeWhenHeadlineDiffersFromList() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .needsAttention,
        transcript: nil,
        audioIsPresent: true,
        isRetained: false
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )
    let hierarchy = BridgeConsoleStatusHierarchy.make(header: header, selected: presentation)

    #expect(header.headline == "Transcription did not finish.")
    #expect(presentation.status == "Needs attention")
    #expect(hierarchy.chromeHeadline == header.headline)
    #expect(hierarchy.inspectorTitle == presentation.status)
    #expect(hierarchy.repeatCount(of: header.headline) == 1)
    #expect(hierarchy.repeatCount(of: presentation.status) == 2)
}

@Test func bridgeMotionStyleUsesEaseOutUnlessReduceMotion() {
    #expect(BridgeMotionStyle.defaultDamping == SignalExperienceToken.Motion.springDamping)
    #expect(BridgeMotionStyle.defaultResponse == SignalExperienceToken.Motion.springResponse)
    #expect(BridgeMotionStyle.crossFadeDuration == SignalExperienceToken.Motion.crossFadeDuration)
    #expect(
        BridgeMotionStyle.forTransition(reduceMotion: false)
            == .spring(
                response: SignalExperienceToken.Motion.springResponse,
                damping: SignalExperienceToken.Motion.springDamping
            )
    )
    #expect(BridgeMotionStyle.forTransition(reduceMotion: true) == .crossFade)
    #expect(BridgeExperienceTheme.Metric.nodeSize == 20)
    #expect(BridgeExperienceTheme.Metric.nodeSpacing == 28)
    #expect(BridgeSpineCopy.labels == ["WATCH", "MAC", "CODEX"])
}

@Test func bridgeChromeTypeUsesDynamicTypeTextStyles() {
    #expect(
        BridgeExperienceTheme.TypeRole.spineLabel
            == Font.system(.caption, design: .rounded, weight: .semibold)
    )
    #expect(BridgeExperienceTheme.TypeRole.inspectorTitle == Font.title2.weight(.bold))
    #expect(
        BridgeExperienceTheme.TypeRole.pairingCode
            == Font.system(.largeTitle, design: .rounded, weight: .bold)
    )
}

@Test func pairingFillBumpsOpacityWhenIncreaseContrast() {
    #expect(BridgePairingFill.opacity(increasedContrast: false) == 0.06)
    #expect(BridgePairingFill.opacity(increasedContrast: true) == 0.12)
}

@Test func bridgeThemeTokensMatchWatchSignalSpineRGBAndMacNeutral() {
    #expect(
        BridgeExperienceTheme.ColorToken.active
            == Color(
                red: SignalExperienceToken.RGB.active.red,
                green: SignalExperienceToken.RGB.active.green,
                blue: SignalExperienceToken.RGB.active.blue
            )
    )
    #expect(
        BridgeExperienceTheme.ColorToken.confirmed
            == Color(
                red: SignalExperienceToken.RGB.confirmed.red,
                green: SignalExperienceToken.RGB.confirmed.green,
                blue: SignalExperienceToken.RGB.confirmed.blue
            )
    )
    #expect(
        BridgeExperienceTheme.ColorToken.attention
            == Color(
                red: SignalExperienceToken.RGB.attention.red,
                green: SignalExperienceToken.RGB.attention.green,
                blue: SignalExperienceToken.RGB.attention.blue
            )
    )
    #expect(
        BridgeExperienceTheme.ColorToken.destructive
            == Color(
                red: SignalExperienceToken.RGB.destructive.red,
                green: SignalExperienceToken.RGB.destructive.green,
                blue: SignalExperienceToken.RGB.destructive.blue
            )
    )
    #expect(BridgeExperienceTheme.ColorToken.neutral == Color.primary.opacity(0.42))
}

@Test func toolbarKeepsSpeechAndSaveSpecVisibleTogether() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "Far far away from the watch",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Far far away\n",
        specProvenance: .localFallback
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .notDetermined)
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )
    let toolbar = BridgeConsoleToolbarPresentation.make(
        header: header,
        canSaveSelectedSpec: presentation.showsSpecDownload
    )

    #expect(header.primaryTitle == "Allow Speech Recognition")
    #expect(presentation.showsSpecDownload)
    #expect(toolbar.showsHeaderPrimary)
    #expect(toolbar.showsSaveSpec)
    #expect(toolbar.headerPrimaryTitle == "Allow Speech Recognition")
    #expect(toolbar.headerPrimarySymbol == "waveform")
}

@Test func toolbarDoesNotUseUninstalledStateAsTheSpeechGate() {
    let installedHeader = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: nil
    )
    let uninstalledHeader = BridgeConsoleHeaderPresentation.make(
        installed: false,
        listenerOnline: false,
        listenerPaused: false,
        watchPaired: false,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: nil
    )
    let installedToolbar = BridgeConsoleToolbarPresentation.make(
        header: installedHeader,
        canSaveSelectedSpec: false
    )
    let uninstalledToolbar = BridgeConsoleToolbarPresentation.make(
        header: uninstalledHeader,
        canSaveSelectedSpec: false
    )

    #expect(installedHeader.primaryTitle == "Allow Speech Recognition")
    #expect(installedToolbar.showsHeaderPrimary)
    #expect(uninstalledHeader.primaryTitle == nil)
    #expect(!uninstalledToolbar.showsHeaderPrimary)
    #expect(!uninstalledToolbar.showsSaveSpec)
}

@Test func toolbarSourceKeepsHeaderPrimaryLabeledAndIndependentOfSaveSpec() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/CodexWatchBridgeCLI/BridgeConsoleView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("if let title = toolbarPresentation.headerPrimaryTitle"))
    #expect(source.contains(".labelStyle(.titleAndIcon)"))
    #expect(source.contains("if toolbarPresentation.showsSaveSpec"))
    #expect(!source.contains("else if let title = model.header.primaryTitle"))
    #expect(!source.contains("model.header.primaryTitle == nil"))
}

@Test func fileMenuSaveCopyIsObviousWhenSpecDownloadIsShown() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "Far far away from the watch",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Far far away\n",
        specProvenance: .appServer
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)

    #expect(presentation.showsSpecDownload == true)
    #expect(BridgeFileMenuCopy.saveSpec == "Save Spec…")
    #expect(BridgeFileMenuCopy.saveHTML == "Save HTML…")
    #expect(MemoSpecCopy.provenanceLabel(.appServer) == "Improved by Codex App Server")
    #expect(MemoSpecCopy.provenanceLabel(.foundationModels) == "Improved on-device by Foundation Models")
    #expect(MemoSpecCopy.provenanceLabel(.localFallback) == "Unverified local wrapper")
}

@Test func pairingPresentationShowsPhraseAndCodeForOnWristEntry() {
    #expect(BridgePairingCopy.onWristInstruction.contains("on your Watch"))
    #expect(BridgePairingCopy.macShowsOnly.contains("Enter them on your Watch"))
    #expect(!BridgePairingCopy.macShowsOnly.contains("enter the code on this Mac"))
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: false,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: nil
    )
    #expect(header.detail == BridgePairingCopy.onWristInstruction)
    #expect(header.primaryTitle == "Generate pairing code")
    #expect(header.spine.watch == .pending)
}

@Test func consoleHeaderPrioritizesUnreachableBindOverSpeech() {
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .notDetermined,
        advertisedName: CodexWatchBrand.productName,
        latest: nil,
        bindHost: "172.20.10.2",
        currentHosts: ["192.168.1.38"]
    )
    #expect(header.primaryTitle == "Use current address")
    #expect(header.headline == "Watch cannot reach this Mac.")
    #expect(header.tone == .attention)
}

@Test func operatorStatusMarksStaleBindAndUnknownWatchQueue() {
    let status = BridgeOperatorStatusPresentation.make(
        loaded: true,
        healthy: true,
        bindHost: "172.20.10.2",
        advertisedHost: "172.20.10.2",
        currentHosts: ["192.168.1.38"],
        fingerprint: String(repeating: "ab", count: 32),
        launchAgentPID: 59771,
        lastEvent: .serviceFailed,
        watchPaired: true,
        lastIntake: Date(timeIntervalSince1970: 1_700_000_000),
        speech: .notDetermined,
        foundationModels: .unavailable("Apple Intelligence is not enabled."),
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(status.bindUnreachable)
    #expect(status.tlsFingerprintShort == "abababab")
    #expect(status.launchAgentPID == "59771")
    #expect(status.lastError == "Listener failed and is retrying.")
    #expect(status.queueDepth.contains("Unknown"))
    #expect(status.speechNeedsCTA)
    #expect(status.specEngine.contains("Foundation Models unavailable"))
}

@Test func resetConfirmationGatingDoesNotWipeWatchKeychainOrRotateTLS() {
    #expect(BridgeResetGate.allow(false) == false)
    #expect(BridgeResetGate.allow(true) == true)
    #expect(BridgeResetPlan.operator.wipesWatchKeychain == false)
    #expect(BridgeResetPlan.operator.rotatesTLS == false)
    #expect(BridgeResetPlan.operator.factoryResetsDevices == false)
    #expect(BridgeResetPlan.operator.regeneratesPairingChallenge)
}

@Test @MainActor func resetDoesNothingUnlessConfirmed() async {
    let model = BridgeAppModel(pollsRuntime: false)
    model.seedPreview(.unpaired)
    await model.performReset(confirmed: false, forgetDisplayedPairing: true)
    #expect(model.pairing?.code == "482917")
    await model.performReset(confirmed: true, forgetDisplayedPairing: true)
    #expect(model.pairing == nil)
}

@Test func memoPipelineLabelsSpecSourceHonestly() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "Far far away from the watch",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Far far away\n",
        specProvenance: .localFallback
    )
    let stages = MemoPipelinePresentation.stages(item: item, speech: .authorized)
    #expect(stages.map(\.label) == [
        "Watch saved", "Upload", "Intake", "Transcribe", "Spec", "Local Codex Inbox",
    ])
    #expect(stages[4].detail == "Unverified local wrapper")
    #expect(stages[5].state == .confirmed)
}

@Test func watchReachableAddressDoesNotClaimStaleWhenInterfacesAreUnknown() {
    #expect(WatchReachableAddress.bindLooksUnreachable(bindHost: "172.20.10.2", currentHosts: []) == false)
    #expect(WatchReachableAddress.bindLooksUnreachable(bindHost: "192.168.1.38", currentHosts: ["192.168.1.38"]) == false)
    #expect(WatchReachableAddress.bindLooksUnreachable(bindHost: "172.20.10.2", currentHosts: ["192.168.1.38"]))
}

@Test func needsAttentionKeepsWatchPairedSpineAndDoesNotAskToPair() throws {
    let item = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .needsAttention,
        transcript: "local transcript",
        audioIsPresent: true,
        isRetained: false
    )
    let presentation = MacInboxItemPresentation.make(item: item, speech: .authorized)
    let header = BridgeConsoleHeaderPresentation.make(
        installed: true,
        listenerOnline: true,
        listenerPaused: false,
        watchPaired: true,
        speech: .authorized,
        advertisedName: CodexWatchBrand.productName,
        latest: item
    )

    #expect(header.spine.watch == .confirmed)
    #expect(header.spine.mac == .attention)
    #expect(header.spine.codex == .pending)
    #expect(header.primaryTitle != "Generate pairing code")
    #expect(presentation.status == "Needs attention")
    #expect(!presentation.detail.contains("Pair again"))
}

@Test func specProvenanceCopyStaysHonestForLocalWrapperAndAppServer() throws {
    let local = MacInboxItem(
        id: try MemoID("11111111-1111-1111-1111-111111111111"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "local transcript",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Local\n",
        specProvenance: .localFallback
    )
    let improved = MacInboxItem(
        id: try MemoID("22222222-2222-2222-2222-222222222222"),
        capturedAt: Date(timeIntervalSince1970: 0),
        state: .delivered,
        transcript: "local transcript",
        audioIsPresent: true,
        isRetained: true,
        specMarkdown: "# Improved\n",
        specProvenance: .appServer
    )

    #expect(MacInboxItemPresentation.make(item: local, speech: .authorized).detail.contains("unverified local wrapper"))
    #expect(MacInboxItemPresentation.make(item: improved, speech: .authorized).detail.contains("Spec is ready to save"))
    #expect(MemoSpecCopy.provenanceLabel(local.specProvenance) == "Unverified local wrapper")
    #expect(MemoSpecCopy.provenanceLabel(improved.specProvenance) == "Improved by Codex App Server")
}
