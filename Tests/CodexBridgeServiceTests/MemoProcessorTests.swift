@testable import CodexBridgeService
import CodexBridgeDelivery
import CodexBridgeShared
import Foundation
import Testing

private let processorMemoID = try! MemoID("44444444-4444-4444-4444-444444444444")

@Test func processorPersistsBeforeSendAndNeverPassesAudioToInbox() async throws {
    let fixture = try ProcessorFixture()
    let transcriber = TranscriberStub(result: .success("Remember to test the onboarding flow"))
    let inbox = InboxStub(
        journal: fixture.journal,
        memoID: processorMemoID,
        histories: [.init(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: true)]
    )
    let processor = MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox
    )

    let outcome = try await processor.process(.init(
        memoID: processorMemoID,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        localeHint: "en-US",
        committedAudio: fixture.committedAudio
    ))

    #expect(outcome == .delivered)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .delivered)
    #expect(await transcriber.callCount == 1)
    let submissions = await inbox.submissions
    #expect(submissions.count == 1)
    #expect(submissions[0].memoID == processorMemoID)
    #expect(submissions[0].text.contains("Remember to test the onboarding flow"))
    #expect(submissions[0].text.contains(MemoProcessor.marker(for: processorMemoID)))
    #expect(submissions[0].text.contains("Captured at: 2023-11-14T22:13:20Z"))
    #expect(submissions[0].text.contains("Locale: en-US"))
}

@Test func ambiguousAcceptanceReconcilesWithoutBlindRetryAfterRestart() async throws {
    let fixture = try ProcessorFixture()
    try fixture.journal.create(.received(
        memoID: processorMemoID,
        capturedAt: .distantPast,
        localeHint: nil,
        audioSHA256: fixture.committedAudio.expectedSHA256
    ))
    _ = try fixture.journal.transition(memoID: processorMemoID, to: .transcribing)
    _ = try fixture.journal.transition(
        memoID: processorMemoID,
        to: .readyForCodex,
        transcript: "Restart-safe idea"
    )
    _ = try fixture.journal.transition(memoID: processorMemoID, to: .inserting)

    let transcriber = TranscriberStub(result: .failure(.engineFailure))
    let inbox = InboxStub(
        journal: fixture.journal,
        memoID: processorMemoID,
        histories: [.init(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: true)]
    )
    let outcome = try await MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox
    ).process(.init(
        memoID: processorMemoID,
        capturedAt: .distantPast,
        localeHint: nil,
        committedAudio: fixture.committedAudio
    ))

    #expect(outcome == .delivered)
    #expect(await transcriber.callCount == 0)
    #expect(await inbox.submissions.isEmpty)
    #expect(await inbox.historyCallCount == 1)
}

@Test func authoritativeAbsenceReopensInsertionAndRetriesSameMarker() async throws {
    let fixture = try ProcessorFixture()
    let inbox = ScriptedInbox(
        submissions: [.success(()), .success(())],
        histories: [
            .success(.init(texts: [], authoritative: true)),
            .success(.init(
                texts: [MemoProcessor.marker(for: processorMemoID)],
                authoritative: true
            )),
        ]
    )
    let processor = fixture.processor(inbox: inbox)

    #expect(try await processor.process(fixture.request) == .retryable)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .readyForCodex)
    #expect(try await processor.process(fixture.request) == .delivered)
    #expect(await inbox.submittedMemoIDs == [processorMemoID, processorMemoID])
    #expect(await inbox.submittedMarkers == [
        MemoProcessor.marker(for: processorMemoID),
        MemoProcessor.marker(for: processorMemoID),
    ])
}

@Test func definitelyNotAcceptedFailureRetriesButUnknownAcceptanceOnlyReconciles() async throws {
    let fixture = try ProcessorFixture()
    let notAccepted = ScriptedInbox(submissions: [.failure(.definitelyNotAccepted)])

    #expect(try await fixture.processor(inbox: notAccepted).process(fixture.request) == .retryable)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .readyForCodex)

    let second = try ProcessorFixture()
    let unknown = ScriptedInbox(submissions: [.failure(.acceptanceUnknown)])

    #expect(try await second.processor(inbox: unknown).process(second.request) == .retryable)
    #expect(try second.journal.load(memoID: processorMemoID).state == .reconciling)
    #expect(await unknown.historyCallCount == 0)
}

@Test func retryResubmitsReadyForCodexWithoutRetranscribing() async throws {
    let fixture = try ProcessorFixture()
    let transcriber = TranscriberStub(result: .success("must not run again"))
    let inbox = ScriptedInbox(
        submissions: [.failure(.definitelyNotAccepted), .success(())],
        histories: [.success(.init(
            texts: [MemoProcessor.marker(for: processorMemoID)],
            authoritative: true
        ))]
    )
    let processor = MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox
    )
    #expect(try await processor.process(fixture.request) == .retryable)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .readyForCodex)
    #expect(try await processor.retry(fixture.request) == .delivered)
    #expect(await transcriber.callCount == 1)
    #expect(await inbox.submittedMemoIDs == [processorMemoID, processorMemoID])
}

@Test func duplicateOrIncompleteHistoryBecomesTerminalAttentionOnNextReconciliationPass() async throws {
    for history in [
        InboxHistory(
            texts: [
                MemoProcessor.marker(for: processorMemoID),
                MemoProcessor.marker(for: processorMemoID),
            ],
            authoritative: true
        ),
        InboxHistory(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: false),
    ] {
        let fixture = try ProcessorFixture()
        let inbox = ScriptedInbox(
            submissions: [.failure(.acceptanceUnknown)],
            histories: [.success(history)]
        )
        let processor = fixture.processor(inbox: inbox)

        #expect(try await processor.process(fixture.request) == .retryable)
        #expect(try await processor.process(fixture.request) == .needsAttention)
        #expect(try fixture.journal.load(memoID: processorMemoID).state == .needsAttention)
        #expect(await inbox.submittedMemoIDs == [processorMemoID])
    }
}

@Test func transcriptionFailureIsTypedAndPersistsAttentionWithoutInboxSend() async throws {
    let fixture = try ProcessorFixture()
    let transcriber = TranscriberStub(result: .failure(.onDeviceRecognitionUnavailable))
    let inbox = InboxStub(journal: fixture.journal, memoID: processorMemoID, histories: [])

    let outcome = try await MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox
    ).process(.init(
        memoID: processorMemoID,
        capturedAt: .distantPast,
        localeHint: "pl-PL",
        committedAudio: fixture.committedAudio
    ))

    #expect(outcome == .needsAttention)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .needsAttention)
    #expect(await inbox.submissions.isEmpty)
}

@Test func reconciliationTransportFailureRemainsRetryableWithoutResubmission() async throws {
    let fixture = try ProcessorFixture()
    let inbox = ScriptedInbox(
        submissions: [.failure(.acceptanceUnknown)],
        histories: [
            .failure(.transport),
            .success(.init(
                texts: [MemoProcessor.marker(for: processorMemoID)],
                authoritative: true
            )),
        ]
    )
    let processor = fixture.processor(inbox: inbox)

    #expect(try await processor.process(fixture.request) == .retryable)
    #expect(try await processor.process(fixture.request) == .retryable)
    #expect(try fixture.journal.load(memoID: processorMemoID).state == .reconciling)
    #expect(try await processor.process(fixture.request) == .delivered)
    #expect(await inbox.submittedMemoIDs == [processorMemoID])
    #expect(await inbox.historyCallCount == 2)
}

@Test func processorPersistsLocalSpecWhenImproverFailsAndStillInsertsRawTranscript() async throws {
    let fixture = try ProcessorFixture()
    let specRoot = fixture.audioURL.deletingLastPathComponent().appending(
        path: "specs",
        directoryHint: .isDirectory
    )
    let specStore = MemoSpecStore(root: specRoot)
    let transcriber = TranscriberStub(result: .success("Remember to test the onboarding flow"))
    let inbox = InboxStub(
        journal: fixture.journal,
        memoID: processorMemoID,
        histories: [.init(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: true)]
    )
    let processor = MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox,
        specImprover: SpecImproverStub(result: .failure(AppServerInboxError.unavailable)),
        specStore: specStore
    )

    let outcome = try await processor.process(fixture.request)

    #expect(outcome == .delivered)
    let spec = try #require(specStore.load(memoID: processorMemoID))
    #expect(spec.provenance == .localFallback)
    #expect(spec.markdown.contains("unverified local wrapper"))
    let submissions = await inbox.submissions
    #expect(submissions.count == 1)
    #expect(submissions[0].text.contains("Voice idea:"))
    #expect(submissions[0].text.contains("Remember to test the onboarding flow"))
    #expect(!submissions[0].text.contains("Spec (Codex App Server):"))
}

@Test func processorInsertsAppServerSpecWhenImprovementSucceeds() async throws {
    let fixture = try ProcessorFixture()
    let specRoot = fixture.audioURL.deletingLastPathComponent().appending(
        path: "specs",
        directoryHint: .isDirectory
    )
    let specStore = MemoSpecStore(root: specRoot)
    let transcriber = TranscriberStub(result: .success("Remember to test the onboarding flow"))
    let inbox = InboxStub(
        journal: fixture.journal,
        memoID: processorMemoID,
        histories: [.init(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: true)]
    )
    let processor = MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox,
        specImprover: SpecImproverStub(result: .success("""
        # Onboarding flow

        ## Summary
        Cover the first-run path.
        """)),
        specStore: specStore
    )

    let outcome = try await processor.process(fixture.request)

    #expect(outcome == .delivered)
    let spec = try #require(specStore.load(memoID: processorMemoID))
    #expect(spec.provenance == .appServer)
    #expect(spec.title == "Onboarding flow")
    let submissions = await inbox.submissions
    #expect(submissions[0].text.contains("Spec (Codex App Server):"))
    #expect(submissions[0].text.contains("# Onboarding flow"))
    #expect(submissions[0].text.contains(MemoProcessor.marker(for: processorMemoID)))
}

@Test func processorPersistsFoundationModelsSpecWhenAvailable() async throws {
    let fixture = try ProcessorFixture()
    let specRoot = fixture.audioURL.deletingLastPathComponent().appending(
        path: "specs",
        directoryHint: .isDirectory
    )
    let specStore = MemoSpecStore(root: specRoot)
    let transcriber = TranscriberStub(result: .success("Remember to test the onboarding flow"))
    let inbox = InboxStub(
        journal: fixture.journal,
        memoID: processorMemoID,
        histories: [.init(texts: [MemoProcessor.marker(for: processorMemoID)], authoritative: true)]
    )
    let processor = MemoProcessor(
        journal: fixture.journal,
        transcriber: transcriber,
        inbox: inbox,
        specImprover: SpecImproverStub(result: .failure(AppServerInboxError.unavailable)),
        specStore: specStore,
        foundationModelsImprover: SpecImproverStub(result: .success("""
        # Onboarding flow

        ## Summary
        Cover the first-run path.
        """))
    )

    let outcome = try await processor.process(fixture.request)

    #expect(outcome == .delivered)
    let spec = try #require(specStore.load(memoID: processorMemoID))
    #expect(spec.provenance == .foundationModels)
    let submissions = await inbox.submissions
    #expect(submissions[0].text.contains("Spec (on-device Foundation Models):"))
}

@Test func specImproverFallsBackWhenFoundationModelsUnavailable() async {
    let improver = MemoSpecImprover(
        foundationModels: nil,
        appServer: SpecImproverStub(result: .failure(AppServerInboxError.unavailable))
    )
    let memoID = try! MemoID("44444444-4444-4444-4444-444444444444")
    let spec = await improver.improve(
        transcript: "Capture this quietly.",
        capturedAt: Date(timeIntervalSince1970: 1),
        memoID: memoID
    )
    #expect(spec.provenance == .localFallback)
    #expect(spec.markdown.contains("unverified local wrapper"))
    #expect(FoundationModelsAvailability.unavailable("Apple Intelligence is not enabled.").isAvailable == false)
}

private struct ProcessorFixture {
    let journal: DeliveryJournal
    let audioURL: URL
    let committedAudio: CommittedAudioAsset

    var request: MemoProcessingRequest {
        MemoProcessingRequest(
            memoID: processorMemoID,
            capturedAt: .distantPast,
            localeHint: nil,
            committedAudio: committedAudio
        )
    }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "memo-processor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        journal = try DeliveryJournal(root: root.appending(path: "journal", directoryHint: .isDirectory))
        audioURL = root.appending(path: "audio.m4a")
        let audio = Data("local-audio-never-sent".utf8)
        try audio.write(to: audioURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: audioURL.path
        )
        committedAudio = try CommittedAudioAsset(
            url: audioURL,
            expectedSHA256: AudioDigest.hex(audio)
        )
    }

    func processor(inbox: any InboxDeliveryClient) -> MemoProcessor {
        MemoProcessor(
            journal: journal,
            transcriber: TranscriberStub(result: .success("Idea")),
            inbox: inbox
        )
    }
}

private actor SpecImproverStub: SpecImproving {
    private let result: Result<String, AppServerInboxError>

    init(result: Result<String, AppServerInboxError>) {
        self.result = result
    }

    func improveSpec(memoID: MemoID, transcript: String) async throws -> String {
        _ = memoID
        _ = transcript
        return try result.get()
    }
}

private actor TranscriberStub: TranscriptionEngine {
    private let result: Result<String, TranscriptionError>
    private(set) var callCount = 0

    init(result: Result<String, TranscriptionError>) {
        self.result = result
    }

    func transcribe(committedAudio: CommittedAudioAsset, localeHint: String?) async throws -> String {
        callCount += 1
        return try result.get()
    }
}

private actor InboxStub: InboxDeliveryClient {
    struct Submission: Sendable {
        let memoID: MemoID
        let marker: String
        let text: String
    }

    private let journal: DeliveryJournal
    private let memoID: MemoID
    private var histories: [InboxHistory]
    private(set) var submissions: [Submission] = []
    private(set) var historyCallCount = 0

    init(journal: DeliveryJournal, memoID: MemoID, histories: [InboxHistory]) {
        self.journal = journal
        self.memoID = memoID
        self.histories = histories
    }

    func submit(memoID: MemoID, marker: String, text: String) async throws {
        #expect(try journal.load(memoID: self.memoID).state == .inserting)
        submissions.append(.init(memoID: memoID, marker: marker, text: text))
    }

    func history(containing marker: String) async throws -> InboxHistory {
        historyCallCount += 1
        return histories.isEmpty
            ? .init(texts: [], authoritative: false)
            : histories.removeFirst()
    }
}

private enum ScriptedInboxError: Error {
    case transport
}

private actor ScriptedInbox: InboxDeliveryClient {
    private var submissions: [Result<Void, InboxSubmissionFailure>]
    private var histories: [Result<InboxHistory, ScriptedInboxError>]
    private(set) var submittedMemoIDs: [MemoID] = []
    private(set) var submittedMarkers: [String] = []
    private(set) var historyCallCount = 0

    init(
        submissions: [Result<Void, InboxSubmissionFailure>] = [.success(())],
        histories: [Result<InboxHistory, ScriptedInboxError>] = []
    ) {
        self.submissions = submissions
        self.histories = histories
    }

    func submit(memoID: MemoID, marker: String, text: String) async throws {
        _ = text
        submittedMemoIDs.append(memoID)
        submittedMarkers.append(marker)
        guard !submissions.isEmpty else { return }
        try submissions.removeFirst().get()
    }

    func history(containing marker: String) async throws -> InboxHistory {
        _ = marker
        historyCallCount += 1
        guard !histories.isEmpty else { throw ScriptedInboxError.transport }
        return try histories.removeFirst().get()
    }
}
