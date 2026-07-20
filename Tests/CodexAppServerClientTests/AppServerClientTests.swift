import Foundation
import Testing
@testable import CodexAppServerClient
@testable import CodexAppServerProtocol

@Test func rejectsRequestsBeforeInitialization() async {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)

    do {
        _ = try await client.call(.threadList)
        Issue.record("Expected an uninitialized client to reject normal requests")
    } catch let error as AppServerClientError {
        #expect(error == .notInitialized)
    } catch {
        Issue.record("Expected AppServerClientError.notInitialized, got \(error)")
    }
}

@Test func initializesBeforeNormalRequests() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))

    try await client.initialize(
        clientName: "codex_voice_bridge",
        title: "Codex Voice Bridge",
        version: "0.1.0"
    )

    let sent = await transport.sentMessages()
    #expect(sent.map(\.methodName) == ["initialize", "initialized"])
}

@Test func waitsForInitializeResponseBeforeInitializedNotification() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    let initialization = Task {
        try await client.initialize(
            clientName: "codex_voice_bridge",
            title: "Codex Voice Bridge",
            version: "0.1.0"
        )
    }

    _ = await transport.waitForSentRequest(at: 0)
    #expect(await transport.sentMessages().map(\.methodName) == ["initialize"])

    await transport.replyToSentRequest(
        at: 0,
        result: .object(["userAgent": .string("codex/0.144.5")])
    )
    try await initialization.value
    #expect(await transport.sentMessages().map(\.methodName) == ["initialize", "initialized"])
}

@Test func correlatesOutOfOrderResponses() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))
    try await client.initialize(
        clientName: "codex_voice_bridge",
        title: "Codex Voice Bridge",
        version: "0.1.0"
    )
    await transport.resetSentMessages()

    let first = Task { try await client.call(.threadRead(threadID: "a", includeTurns: false)) }
    _ = await transport.waitForSentRequest(at: 0)
    let second = Task { try await client.call(.threadRead(threadID: "b", includeTurns: false)) }
    _ = await transport.waitForSentRequest(at: 1)

    await transport.replyToSentRequest(
        at: 1,
        result: .object(["thread": .object(["id": .string("b")])])
    )
    await transport.replyToSentRequest(
        at: 0,
        result: .object(["thread": .object(["id": .string("a")])])
    )

    let firstResult = try await first.value
    let secondResult = try await second.value
    #expect(firstResult["thread"]?["id"] == .string("a"))
    #expect(secondResult["thread"]?["id"] == .string("b"))
}

@Test func deliversUnknownNotificationsWithoutSchemaLoss() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    var notifications = client.notifications().makeAsyncIterator()
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))
    try await client.initialize(clientName: "bridge", title: "Bridge", version: "0.1.0")

    let expected = JSONRPCNotification(
        method: "future/event",
        params: .object(["nested": .array([.number(1), .bool(true)])])
    )
    await transport.enqueueNotification(expected)

    #expect(await notifications.next() == expected)
}

@Test func disconnectFailsEveryPendingRequestExactlyOnce() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))
    try await client.initialize(clientName: "bridge", title: "Bridge", version: "0.1.0")
    await transport.resetSentMessages()

    let first = Task { try await client.call(.threadRead(threadID: "a", includeTurns: false)) }
    let second = Task { try await client.call(.threadRead(threadID: "b", includeTurns: false)) }
    _ = await transport.waitForSentRequest(at: 1)
    await transport.finish()

    for request in [first, second] {
        do {
            _ = try await request.value
            Issue.record("Expected a pending request to fail on disconnect")
        } catch let error as AppServerClientError {
            #expect(error == .disconnected)
        } catch {
            Issue.record("Expected AppServerClientError.disconnected, got \(error)")
        }
    }
}

@Test func convertsCorrelatedServerErrors() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))
    try await client.initialize(clientName: "bridge", title: "Bridge", version: "0.1.0")
    await transport.resetSentMessages()

    let request = Task { try await client.call(.threadList) }
    await transport.replyToSentRequest(at: 0, errorCode: -32601, message: "not found")

    do {
        _ = try await request.value
        Issue.record("Expected the server error response to fail its correlated request")
    } catch let error as AppServerClientError {
        #expect(error == .server(code: -32601, message: "not found"))
    } catch {
        Issue.record("Expected a correlated AppServerClientError.server, got \(error)")
    }
}

@Test func cancellingCallRemovesAndResumesPendingContinuationBeforeClose() async throws {
    let transport = FakeAppServerTransport()
    let client = AppServerClient(transport: transport)
    await transport.enqueueResponse(id: 1, result: .object(["userAgent": .string("codex/0.144.5")]))
    try await client.initialize(clientName: "bridge", title: "Bridge", version: "0.1.0")
    await transport.resetSentMessages()

    let request = Task { try await client.call(.threadRead(threadID: "cancel-me", includeTurns: false)) }
    _ = await transport.waitForSentRequest(at: 0)
    request.cancel()
    await #expect(throws: CancellationError.self) { _ = try await request.value }

    // Must neither leak nor double-resume the cancelled continuation.
    await client.close()
}
