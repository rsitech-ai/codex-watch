@testable import CodexWatchBridgeCLI
import CodexBridgeShared
import Foundation
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
