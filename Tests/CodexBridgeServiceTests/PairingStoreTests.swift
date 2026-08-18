@testable import CodexBridgeService
import Foundation
import Testing

@Test func pairingCodeIsOneUseAndExpires() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let secrets = InMemorySecretStore()
    let pairing = try PairingStore(
        secretStore: secrets,
        clock: { clock.read() },
        codeGenerator: { "123456" },
        tokenGenerator: { Data(repeating: 0x11, count: 32) }
    )

    let first = try await pairing.beginPairing(validFor: 600)
    #expect(first.code == "123456")
    #expect(first.expiresAt == Date(timeIntervalSince1970: 1_700_000_600))

    let credential = try await pairing.redeem(code: first.code)
    #expect(credential.tokenHex == String(repeating: "11", count: 32))
    await #expect(throws: PairingError.self) {
        _ = try await pairing.redeem(code: first.code)
    }

    _ = try await pairing.beginPairing(validFor: 10)
    clock.set(Date(timeIntervalSince1970: 1_700_000_011))
    await #expect(throws: PairingError.expired) {
        _ = try await pairing.redeem(code: "123456")
    }
}

@Test func credentialPersistsAndRotationInvalidatesOldToken() async throws {
    let generated = LockedByteSequence([
        Data(repeating: 0x11, count: 32),
        Data(repeating: 0x22, count: 32),
    ])
    let secrets = InMemorySecretStore()
    let pairing = try PairingStore(
        secretStore: secrets,
        codeGenerator: { "654321" },
        tokenGenerator: { try generated.next() }
    )

    _ = try await pairing.beginPairing(validFor: 60)
    let original = try await pairing.redeem(code: "654321")
    let rotated = try await pairing.rotateCredential()
    let reloaded = try PairingStore(secretStore: secrets)

    #expect(original.tokenHex == String(repeating: "11", count: 32))
    #expect(rotated.tokenHex == String(repeating: "22", count: 32))
    #expect(try await reloaded.currentCredential() == rotated)
    #expect(!(try await reloaded.matchesBearerToken(original.tokenHex)))
    #expect(try await reloaded.matchesBearerToken(rotated.tokenHex))
}

@Test func clearDisplayedChallengeKeepsCredential() async throws {
    let secrets = InMemorySecretStore()
    let pairing = try PairingStore(
        secretStore: secrets,
        codeGenerator: { "111222" },
        tokenGenerator: { Data(repeating: 0x33, count: 32) }
    )
    _ = try await pairing.beginPairing(validFor: 60)
    _ = try await pairing.redeem(code: "111222")
    try await pairing.clearDisplayedChallenge()
    #expect(try await pairing.currentCredential() != nil)
    await #expect(throws: PairingError.noActiveCode) {
        _ = try await pairing.redeem(code: "111222")
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}

private final class LockedByteSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data]

    init(_ values: [Data]) { self.values = values }

    func next() throws -> Data {
        try lock.withLock {
            guard !values.isEmpty else { throw PairingError.invalidGeneratedSecret }
            return values.removeFirst()
        }
    }
}
