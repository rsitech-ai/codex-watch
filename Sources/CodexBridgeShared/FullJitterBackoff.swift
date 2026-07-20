import Foundation

public enum FullJitterBackoffError: Error, Equatable, Sendable {
    case invalidConfiguration
}

public struct FullJitterBackoff: Equatable, Sendable {
    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval

    public init(baseDelay: TimeInterval, maximumDelay: TimeInterval) throws {
        guard baseDelay.isFinite,
              maximumDelay.isFinite,
              baseDelay > 0,
              maximumDelay >= baseDelay
        else { throw FullJitterBackoffError.invalidConfiguration }
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    public func delay(afterAttempt attempt: UInt64, sample: Double) -> TimeInterval {
        let boundedSample: Double
        if sample.isNaN {
            boundedSample = 0
        } else {
            boundedSample = min(1, max(0, sample))
        }
        let exponential = baseDelay * pow(2, Double(attempt))
        return min(maximumDelay, exponential) * boundedSample
    }
}
