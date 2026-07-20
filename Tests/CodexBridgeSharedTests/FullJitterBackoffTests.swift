@testable import CodexBridgeShared
import Foundation
import Testing

@Test func fullJitterBackoffRejectsInvalidBounds() {
    #expect(throws: FullJitterBackoffError.self) {
        _ = try FullJitterBackoff(baseDelay: 0, maximumDelay: 1)
    }
    #expect(throws: FullJitterBackoffError.self) {
        _ = try FullJitterBackoff(baseDelay: 5, maximumDelay: 4)
    }
    #expect(throws: FullJitterBackoffError.self) {
        _ = try FullJitterBackoff(baseDelay: .infinity, maximumDelay: .infinity)
    }
}

@Test func fullJitterBackoffUsesSampleAcrossExponentialWindow() throws {
    let backoff = try FullJitterBackoff(baseDelay: 5, maximumDelay: 900)

    #expect(backoff.delay(afterAttempt: 0, sample: 0) == 0)
    #expect(backoff.delay(afterAttempt: 0, sample: 1) == 5)
    #expect(backoff.delay(afterAttempt: 1, sample: 0.5) == 5)
    #expect(backoff.delay(afterAttempt: 2, sample: 1) == 20)
}

@Test func fullJitterBackoffCapsOverflowAndClampsUntrustedSamples() throws {
    let backoff = try FullJitterBackoff(baseDelay: 5, maximumDelay: 900)

    #expect(backoff.delay(afterAttempt: 8, sample: 1) == 900)
    #expect(backoff.delay(afterAttempt: .max, sample: 1) == 900)
    #expect(backoff.delay(afterAttempt: .max, sample: -1) == 0)
    #expect(backoff.delay(afterAttempt: .max, sample: 2) == 900)
    #expect(backoff.delay(afterAttempt: .max, sample: .nan) == 0)
}
