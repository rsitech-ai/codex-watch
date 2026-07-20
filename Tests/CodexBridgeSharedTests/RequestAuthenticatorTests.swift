@testable import CodexBridgeShared
import CryptoKit
import Foundation
import Testing

private let requestMemoID = try! MemoID("123e4567-e89b-12d3-a456-426614174000")
private let requestDigest = String(repeating: "a", count: 64)

@Test func canonicalRequestBytesAreDeterministicAndUnambiguous() throws {
    let request = try makeRequest()

    let canonical = try request.canonicalBytes()

    #expect(String(data: canonical, encoding: .utf8) == """
    codex-watch-request-v2
    POST
    /v1/memos/123e4567-e89b-12d3-a456-426614174000
    1700000000
    nonce-123
    123e4567-e89b-12d3-a456-426614174000
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    7
    0

    """)
}

@Test func requestHMACMatchesKnownVectorAndVerifies() throws {
    let request = try makeRequest()
    let key = SymmetricKey(data: Data("secret".utf8))

    let signature = try RequestAuthenticator.signatureHex(for: request, key: key)

    #expect(signature == "e9f252bf59b58a670eac52f387d776e7684f6651051fc073f83918c9cf04a4a9")
    #expect(try RequestAuthenticator.verify(signatureHex: signature, for: request, key: key))
    #expect(try !RequestAuthenticator.verify(
        signatureHex: String(repeating: "0", count: 64),
        for: request,
        key: key
    ))
}

@Test func canonicalRequestRejectsHeaderInjectionAndInvalidDigest() {
    #expect(throws: RequestAuthenticationError.self) {
        _ = try makeRequest(nonce: "nonce\nforged")
    }
    #expect(throws: RequestAuthenticationError.self) {
        _ = try makeRequest(bodySHA256: "not-a-digest")
    }
}

@Test(arguments: ["ß", "ſ", "ı", "PØST"])
func canonicalRequestRejectsUnicodeMethodCanonicalizationCollisions(_ method: String) {
    #expect(throws: RequestAuthenticationError.self) {
        _ = try CanonicalBridgeRequest(
            method: method,
            path: "/v1/memos/\(requestMemoID.rawValue)",
            timestamp: 1_700_000_000,
            nonce: "unicode-method",
            memoID: requestMemoID,
            bodySHA256: requestDigest,
            revision: 1
        )
    }
}

@Test func authenticatedVerifierAcceptsFreshRequestThenRejectsReplay() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_030)
    let request = try makeRequest(timestamp: 1_700_000_000)
    let key = SymmetricKey(data: Data("secret".utf8))
    let signature = try RequestAuthenticator.signatureHex(for: request, key: key)
    let verifier = try AuthenticatedRequestVerifier(
        allowedClockSkew: 60,
        replayRetention: 600,
        clock: { now },
        replayStore: InMemoryReplayNonceStore()
    )

    try await verifier.verify(signatureHex: signature, request: request, key: key)

    await #expect(throws: RequestAuthenticationError.self) {
        try await verifier.verify(signatureHex: signature, request: request, key: key)
    }
}

@Test func authenticatedVerifierRejectsExpiredFutureAndInvalidSignaturesWithoutConsumingNonce() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_100)
    let key = SymmetricKey(data: Data("secret".utf8))
    let verifier = try AuthenticatedRequestVerifier(
        allowedClockSkew: 30,
        replayRetention: 600,
        clock: { now },
        replayStore: InMemoryReplayNonceStore()
    )
    let expired = try makeRequest(timestamp: 1_700_000_000, nonce: "expired")
    let future = try makeRequest(timestamp: 1_700_000_200, nonce: "future")
    let fresh = try makeRequest(timestamp: 1_700_000_100, nonce: "fresh")
    let freshSignature = try RequestAuthenticator.signatureHex(for: fresh, key: key)

    await #expect(throws: RequestAuthenticationError.self) {
        try await verifier.verify(
            signatureHex: RequestAuthenticator.signatureHex(for: expired, key: key),
            request: expired,
            key: key
        )
    }
    await #expect(throws: RequestAuthenticationError.self) {
        try await verifier.verify(
            signatureHex: RequestAuthenticator.signatureHex(for: future, key: key),
            request: future,
            key: key
        )
    }
    await #expect(throws: RequestAuthenticationError.self) {
        try await verifier.verify(signatureHex: String(repeating: "0", count: 64), request: fresh, key: key)
    }
    try await verifier.verify(signatureHex: freshSignature, request: fresh, key: key)
}

@Test func nonceRemainsOneUseAcrossTimeAndVerifierRestartForCredentialLifetime() async throws {
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        func read() -> Date {
            lock.withLock { value }
        }

        func set(_ value: Date) {
            lock.withLock { self.value = value }
        }
    }

    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let replayStore = InMemoryReplayNonceStore()
    let key = SymmetricKey(data: Data("secret".utf8))
    let firstRequest = try makeRequest(timestamp: 1_700_000_000, nonce: "lifetime-nonce")
    let firstVerifier = try AuthenticatedRequestVerifier(
        allowedClockSkew: 60,
        replayRetention: 600,
        clock: { clock.read() },
        replayStore: replayStore
    )
    try await firstVerifier.verify(
        signatureHex: RequestAuthenticator.signatureHex(for: firstRequest, key: key),
        request: firstRequest,
        key: key
    )

    clock.set(Date(timeIntervalSince1970: 1_700_000_121))
    let replayWithFreshTimestamp = try makeRequest(timestamp: 1_700_000_121, nonce: "lifetime-nonce")
    let restartedVerifier = try AuthenticatedRequestVerifier(
        allowedClockSkew: 60,
        replayRetention: 600,
        clock: { clock.read() },
        replayStore: replayStore
    )

    await #expect(throws: RequestAuthenticationError.self) {
        try await restartedVerifier.verify(
            signatureHex: RequestAuthenticator.signatureHex(for: replayWithFreshTimestamp, key: key),
            request: replayWithFreshTimestamp,
            key: key
        )
    }
}

@Test func authenticatedVerifierPassesAcceptanceAndExpiryTimesToReplayStore() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let replayStore = RecordingReplayNonceStore()
    let request = try makeRequest(timestamp: 1_700_000_000, nonce: "retained-nonce")
    let key = SymmetricKey(data: Data("secret".utf8))
    let verifier = try AuthenticatedRequestVerifier(
        allowedClockSkew: 300,
        replayRetention: 600,
        clock: { now },
        replayStore: replayStore
    )

    try await verifier.verify(
        signatureHex: RequestAuthenticator.signatureHex(for: request, key: key),
        request: request,
        key: key
    )

    let consumed = await replayStore.consumed
    #expect(consumed?.nonce == "retained-nonce")
    #expect(consumed?.acceptedAt == now)
    #expect(consumed?.expiresAt == now.addingTimeInterval(600))
}

private actor RecordingReplayNonceStore: ReplayNonceStore {
    private(set) var consumed: (nonce: String, acceptedAt: Date, expiresAt: Date)?

    func consume(_ nonce: String, acceptedAt: Date, expiresAt: Date) -> Bool {
        consumed = (nonce, acceptedAt, expiresAt)
        return true
    }
}

private func makeRequest(
    timestamp: Int64 = 1_700_000_000,
    nonce: String = "nonce-123",
    bodySHA256: String = requestDigest
) throws -> CanonicalBridgeRequest {
    try CanonicalBridgeRequest(
        method: "post",
        path: "/v1/memos/123e4567-e89b-12d3-a456-426614174000",
        timestamp: timestamp,
        nonce: nonce,
        memoID: requestMemoID,
        bodySHA256: bodySHA256,
        revision: 7
    )
}
