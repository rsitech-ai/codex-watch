@testable import CodexBridgeService
import CodexAppServerProtocol
import CodexBridgeShared
import Foundation
import Testing

@Test func inboxClientImproveSpecReadsAssistantMarkdown() async throws {
    let neutral = try privateNeutralDirectory()
    let session = AppServerSessionStub(responses: [
        inboxPage(id: "thr_inbox", cwd: neutral.path),
        .object(["turn": .object(["id": .string("turn_spec")])]),
        .object(["thread": .object([
            "id": .string("thr_inbox"),
            "cwd": .string(neutral.path),
            "turns": .array([.object([
                "items": .array([
                    .object([
                        "type": .string("userMessage"),
                        "text": .string("Turn this Watch voice transcript into a markdown spec."),
                    ]),
                    .object([
                        "type": .string("agentMessage"),
                        "text": .string("# Quiet capture\n\n## Summary\nKeep the raw transcript visible."),
                    ]),
                ]),
            ])]),
        ])]),
    ], notifications: [completionNotification(threadID: "thr_inbox", turnID: "turn_spec")])
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)
    let memoID = try MemoID("12121212-3434-5656-7878-909090909090")

    let markdown = try await client.improveSpec(
        memoID: memoID,
        transcript: "Keep the raw transcript visible."
    )

    #expect(markdown.contains("# Quiet capture"))
    let methods = await session.methods
    #expect(methods.map(\.name) == ["thread/list", "turn/start", "thread/read"])
    #expect(methods[1].params["clientUserMessageId"] == .string("\(memoID.rawValue)-spec"))
}

@Test func inboxClientImproveSpecFailsClosedWhenSessionCannotStart() async throws {
    let client = AppServerInboxClient(
        sessionFactory: { throw AppServerInboxError.unavailable },
        neutralDirectory: try privateNeutralDirectory()
    )
    let memoID = try MemoID("13131313-1414-1515-1616-171717171717")

    await #expect(throws: AppServerInboxError.unavailable) {
        _ = try await client.improveSpec(memoID: memoID, transcript: "idea")
    }
}

@Test func inboxClientReusesExactInboxAndUsesCaptureOnlyTurnPolicy() async throws {
    let neutral = try privateNeutralDirectory()
    let session = AppServerSessionStub(responses: [
        .object([
            "data": .array([.object([
                "id": .string("thr_inbox"),
                "name": .string("Codex Watch"),
                "cwd": .string(neutral.path),
            ])]),
            "nextCursor": .null,
        ]),
        .object(["turn": .object(["id": .string("turn_1")])]),
        inboxPage(id: "thr_inbox", cwd: neutral.path),
        .object(["thread": .object([
            "id": .string("thr_inbox"),
            "cwd": .string(neutral.path),
            "turns": .array([.object([
                "items": .array([.object([
                    "type": .string("userMessage"),
                    "text": .string("[codex-voice-memo:marker] idea"),
                ])]),
            ])]),
        ])]),
    ], notifications: [completionNotification(threadID: "thr_inbox", turnID: "turn_1")])
    let client = AppServerInboxClient(
        session: session,
        neutralDirectory: neutral
    )
    let memoID = try MemoID("55555555-5555-5555-5555-555555555555")

    try await client.submit(
        memoID: memoID,
        marker: "[codex-voice-memo:marker]",
        text: "[codex-voice-memo:marker] idea"
    )
    let history = try await client.history(containing: "[codex-voice-memo:marker]")

    #expect(history.authoritative)
    #expect(history.texts == ["[codex-voice-memo:marker] idea"])
    let methods = await session.methods
    #expect(methods.map(\.name) == ["thread/list", "turn/start", "thread/list", "thread/read"])
    #expect(methods[1].params["threadId"] == .string("thr_inbox"))
    #expect(methods[1].params["clientUserMessageId"] == .string(memoID.rawValue))
    #expect(methods[1].params["sandboxPolicy"] == .object([
        "type": .string("readOnly"),
        "networkAccess": .bool(false),
    ]))
    #expect(methods[1].params["approvalPolicy"] == .string("never"))
}

@Test func inboxClientCreatesPersistentNamedInboxWithExactRequestShape() async throws {
    let neutral = FileManager.default.temporaryDirectory.appending(
        path: "codex-inbox-client-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: neutral.path
    )
    let session = AppServerSessionStub(responses: [
        .object(["data": .array([]), "nextCursor": .null]),
        .object(["thread": .object([
            "id": .string("thr_new"),
            "cwd": .string(neutral.path),
        ])]),
        .object([:]),
        .object(["turn": .object(["id": .string("turn_new")])]),
    ], notifications: [completionNotification(threadID: "thr_new", turnID: "turn_new")])
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)
    let memoID = try MemoID("66666666-6666-6666-6666-666666666666")

    try await client.submit(memoID: memoID, marker: "marker", text: "marker idea")

    let methods = await session.methods
    #expect(methods.map(\.name) == [
        "thread/list", "thread/start", "thread/name/set", "turn/start",
    ])
    #expect(methods[1].params == .object([
        "cwd": .string(neutral.path),
        "ephemeral": .bool(false),
    ]))
    #expect(methods[2].params == .object([
        "threadId": .string("thr_new"),
        "name": .string("Codex Watch"),
    ]))
}

@Test func inboxClientIgnoresSameNamedThreadOutsideNeutralDirectory() async throws {
    let neutral = try privateNeutralDirectory()
    let session = AppServerSessionStub(responses: [
        .object([
            "data": .array([.object([
                "id": .string("thr_stale"),
                "name": .string("Codex Watch"),
                "cwd": .string("/private/tmp/cw-inbox-neutral.stale"),
            ])]),
            "nextCursor": .null,
        ]),
        .object(["thread": .object([
            "id": .string("thr_new"),
            "cwd": .string(neutral.path),
        ])]),
        .object([:]),
        .object(["turn": .object(["id": .string("turn_new")])]),
    ], notifications: [completionNotification(threadID: "thr_new", turnID: "turn_new")])
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)
    let memoID = try MemoID("77777777-7777-7777-7777-777777777777")

    try await client.submit(memoID: memoID, marker: "marker", text: "marker idea")

    let methods = await session.methods
    #expect(methods.map(\.name) == [
        "thread/list", "thread/start", "thread/name/set", "turn/start",
    ])
}

@Test func inboxClientReconnectsForAuthoritativeHistoryAfterAmbiguousSubmitLoss() async throws {
    let neutral = try privateNeutralDirectory()
    let first = AppServerSessionStub(responses: [
        inboxPage(id: "thr_inbox", cwd: neutral.path),
        .object(["turn": .object(["id": .string("turn_uncertain")])]),
    ], notifications: [])
    let second = AppServerSessionStub(responses: [
        inboxPage(id: "thr_inbox", cwd: neutral.path),
        .object(["thread": .object([
            "id": .string("thr_inbox"),
            "cwd": .string(neutral.path),
            "turns": .array([.object(["items": .array([.object([
                "type": .string("userMessage"),
                "text": .string("marker idea"),
            ])])])]),
        ])]),
    ])
    let sessions = AppServerSessionSequence([first, second])
    let client = AppServerInboxClient(
        sessionFactory: { try sessions.next() },
        neutralDirectory: neutral,
        completionTimeout: .milliseconds(20)
    )
    let memoID = try MemoID("88888888-8888-8888-8888-888888888888")

    await #expect(throws: InboxSubmissionFailure.acceptanceUnknown) {
        try await client.submit(memoID: memoID, marker: "marker", text: "marker idea")
    }
    let history = try await client.history(containing: "marker")

    #expect(history == .init(texts: ["marker idea"], authoritative: true))
    #expect(sessions.createdCount == 2)
    #expect(await first.closeCount == 1)
    #expect(await second.closeCount == 1)
}

@Test func inboxClientTypesFailuresBeforeTurnStartAsDefinitelyNotAccepted() async throws {
    let neutral = try privateNeutralDirectory()
    let session = AppServerSessionStub(responses: [])
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)

    await #expect(throws: InboxSubmissionFailure.definitelyNotAccepted) {
        try await client.submit(
            memoID: MemoID("89898989-8989-8989-8989-898989898989"),
            marker: "marker",
            text: "marker idea"
        )
    }
    #expect(await session.methods.map(\.name) == ["thread/list"])
    #expect(await session.closeCount == 1)
}

@Test func inboxClientTypesMalformedTurnAcceptanceAsUnknown() async throws {
    let neutral = try privateNeutralDirectory()
    let session = AppServerSessionStub(responses: [
        inboxPage(id: "thr_inbox", cwd: neutral.path),
        .object([:]),
    ])
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)

    await #expect(throws: InboxSubmissionFailure.acceptanceUnknown) {
        try await client.submit(
            memoID: MemoID("90909090-9090-9090-9090-909090909090"),
            marker: "marker",
            text: "marker idea"
        )
    }
    #expect(await session.methods.map(\.name) == ["thread/list", "turn/start"])
    #expect(await session.closeCount == 1)
}

@Test func inboxClientFailsClosedWhenThreadCatalogExceedsPageBound() async throws {
    let neutral = try privateNeutralDirectory()
    let pages: [JSONValue] = (0 ..< 64).map { index in
        .object([
            "data": .array([]),
            "nextCursor": .string("cursor-\(index)"),
        ])
    }
    let session = AppServerSessionStub(responses: pages)
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)

    await #expect(throws: AppServerInboxError.incompleteCatalog) {
        _ = try await client.history(containing: "marker")
    }
    #expect(await session.methods.count == 64)
}

@Test func cancellingInboxOperationClosesItsInflightSession() async throws {
    let neutral = try privateNeutralDirectory()
    let session = CancellationAwareSessionStub()
    let client = AppServerInboxClient(session: session, neutralDirectory: neutral)
    let operation = Task {
        try await client.submit(
            memoID: MemoID("99999999-0000-0000-0000-000000000000"),
            marker: "marker",
            text: "marker idea"
        )
    }
    await session.waitUntilCallStarted()
    operation.cancel()
    _ = try? await operation.value

    #expect(await session.closeCount == 1)
    #expect(await session.callFinished == true)
}

private actor AppServerSessionStub: AppServerRequesting {
    private var responses: [JSONValue]
    private(set) var methods: [AppServerMethod] = []
    private(set) var initializeCount = 0
    private(set) var closeCount = 0
    nonisolated let notificationStream: AsyncStream<JSONRPCNotification>

    init(responses: [JSONValue], notifications: [JSONRPCNotification] = []) {
        self.responses = responses
        notificationStream = AsyncStream { continuation in
            for notification in notifications { continuation.yield(notification) }
            continuation.finish()
        }
    }

    func initialize(clientName: String, title: String, version: String) async throws {
        initializeCount += 1
    }

    func call(_ method: AppServerMethod) async throws -> JSONValue {
        methods.append(method)
        guard !responses.isEmpty else { throw AppServerInboxError.invalidResponse }
        return responses.removeFirst()
    }

    nonisolated func notifications() -> AsyncStream<JSONRPCNotification> {
        notificationStream
    }

    func close() async { closeCount += 1 }
}

private actor CancellationAwareSessionStub: AppServerRequesting {
    private var callStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callFinished = false
    private(set) var closeCount = 0
    nonisolated let notificationStream = AsyncStream<JSONRPCNotification> { _ in }

    func initialize(clientName: String, title: String, version: String) async throws {}

    func call(_ method: AppServerMethod) async throws -> JSONValue {
        _ = method
        callStarted = true
        let pending = startWaiters
        startWaiters.removeAll()
        for continuation in pending { continuation.resume() }
        defer { callFinished = true }
        try await Task.sleep(for: .seconds(60))
        return .object([:])
    }

    nonisolated func notifications() -> AsyncStream<JSONRPCNotification> { notificationStream }
    func close() async { closeCount += 1 }

    func waitUntilCallStarted() async {
        guard !callStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private final class AppServerSessionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [any AppServerRequesting]
    private(set) var createdCount = 0

    init(_ sessions: [any AppServerRequesting]) {
        self.sessions = sessions
    }

    func next() throws -> any AppServerRequesting {
        try lock.withLock {
            guard !sessions.isEmpty else { throw AppServerInboxError.invalidResponse }
            createdCount += 1
            return sessions.removeFirst()
        }
    }
}

private func completionNotification(threadID: String, turnID: String) -> JSONRPCNotification {
    JSONRPCNotification(method: "turn/completed", params: .object([
        "threadId": .string(threadID),
        "turn": .object(["id": .string(turnID)]),
    ]))
}

private func inboxPage(id: String, cwd: String) -> JSONValue {
    .object([
        "data": .array([.object([
            "id": .string(id),
            "name": .string("Codex Watch"),
            "cwd": .string(cwd),
        ])]),
        "nextCursor": .null,
    ])
}

private func privateNeutralDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "codex-inbox-neutral-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
    )
    return url
}
