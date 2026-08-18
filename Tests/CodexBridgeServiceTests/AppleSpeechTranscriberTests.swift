@testable import CodexBridgeService
import CodexBridgeShared
import Foundation
import Testing

@Test func speechTranscriberRejectsMissingAssetAndDeniedPermission() async throws {
    let missing = try privateAudioFixture()
    try FileManager.default.removeItem(at: missing.url)
    let transcriber = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { _ in true },
        recognize: { _, _ in "unused" }
    )
    await #expect(throws: TranscriptionError.invalidAudioAsset) {
        _ = try await transcriber.transcribe(committedAudio: missing, localeHint: "en-US")
    }

    let audio = try privateAudioFixture()
    let denied = AppleSpeechTranscriber(
        authorizationStatus: { .denied },
        supportsLocale: { _ in true },
        recognize: { _, _ in "unused" }
    )
    await #expect(throws: TranscriptionError.permissionDenied) {
        _ = try await denied.transcribe(committedAudio: audio, localeHint: nil)
    }
}

@Test func speechTranscriberFailsClosedForUnsupportedLocaleAndEmptyTranscript() async throws {
    let audio = try privateAudioFixture()
    let unsupported = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { _ in false },
        recognize: { _, _ in "unused" }
    )
    await #expect(throws: TranscriptionError.unsupportedLocale) {
        _ = try await unsupported.transcribe(committedAudio: audio, localeHint: "xx-ZZ")
    }

    let empty = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { _ in true },
        recognize: { _, _ in "  \n" }
    )
    await #expect(throws: TranscriptionError.emptyTranscript) {
        _ = try await empty.transcribe(committedAudio: audio, localeHint: "en-US")
    }
}

@Test func speechTranscriberFallsBackFromRegionTaggedEnglishToASupportedEnglishLocale() async throws {
    let audio = try privateAudioFixture()
    let transcriber = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { SpeechLocaleSelection.normalized($0.identifier) == "en-us" },
        recognize: { _, locale in
            #expect(SpeechLocaleSelection.normalized(locale.identifier) == "en-us")
            return "captured on mac"
        }
    )
    #expect(
        try await transcriber.transcribe(committedAudio: audio, localeHint: "en_PL")
            == "captured on mac"
    )
}

@Test func speechTranscriberReturnsTrimmedLocalRecognitionAndPreservesTypedFailure() async throws {
    let audio = try privateAudioFixture()
    let success = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { $0.identifier == "pl-PL" },
        recognize: { url, locale in
            #expect(url == audio.url)
            #expect(locale.identifier == "pl-PL")
            return "  Pomysl na aplikacje  "
        }
    )
    #expect(try await success.transcribe(
        committedAudio: audio,
        localeHint: "pl-PL"
    ) == "Pomysl na aplikacje")

    let cancelled = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { _ in true },
        recognize: { _, _ in throw TranscriptionError.cancelled }
    )
    await #expect(throws: TranscriptionError.cancelled) {
        _ = try await cancelled.transcribe(committedAudio: audio, localeHint: nil)
    }
}

@Test func speechTranscriberRejectsAssetReplacedDuringRecognition() async throws {
    let audio = try privateAudioFixture()
    let transcriber = AppleSpeechTranscriber(
        authorizationStatus: { .authorized },
        supportsLocale: { _ in true },
        recognize: { url, _ in
            try FileManager.default.removeItem(at: url)
            try Data("replacement".utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            return "must not escape identity validation"
        }
    )

    await #expect(throws: TranscriptionError.invalidAudioAsset) {
        _ = try await transcriber.transcribe(committedAudio: audio, localeHint: "en-US")
    }
}

private func privateAudioFixture() throws -> CommittedAudioAsset {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "speech-fixture-\(UUID().uuidString).m4a"
    )
    let data = Data("fixture".utf8)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )
    return try CommittedAudioAsset(url: url, expectedSHA256: AudioDigest.hex(data))
}

@Test func speechRecognitionFileCopiesCAFBytesNamedAsM4A() throws {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "speech-caf-\(UUID().uuidString).m4a"
    )
    var bytes = Data("caff".utf8)
    bytes.append(Data(repeating: 0, count: 32))
    try bytes.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let prepared = try SpeechRecognitionFile.prepared(from: url)
    defer { prepared.release() }
    #expect(prepared.cleanup == true)
    #expect(prepared.url.pathExtension == "caf")
    #expect(try Data(contentsOf: prepared.url) == bytes)
}
