import CodexBridgeShared
import Foundation

public enum WatchBridgeTransportFailure: Error, Equatable, Sendable {
    case transient
    case authentication
    case statusAbsent
    case conflict
    case permanent
}

public protocol WatchBridgeTransport: Sendable {
    func upload(
        memo: VoiceMemoMetadata,
        audioURL: URL,
        expectedRevision: UInt64
    ) async throws -> BridgeReceipt

    func status(for memo: VoiceMemoMetadata) async throws -> BridgeMemoStatus
    func recoverAbsentStatus(memo: VoiceMemoMetadata, audioURL: URL) async throws
    func acknowledgeDelivery(_ acknowledgement: FinalDeliveryAcknowledgement) async throws
}

public extension WatchBridgeTransport {
    func status(for _: VoiceMemoMetadata) async throws -> BridgeMemoStatus {
        throw WatchBridgeTransportFailure.permanent
    }

    func acknowledgeDelivery(_: FinalDeliveryAcknowledgement) async throws {
        throw WatchBridgeTransportFailure.permanent
    }

    func recoverAbsentStatus(memo _: VoiceMemoMetadata, audioURL _: URL) async throws {
        throw WatchBridgeTransportFailure.permanent
    }
}

public enum WatchRetryPolicyError: Error, Equatable, Sendable {
    case invalidConfiguration
}

public struct WatchRetryPolicy: Equatable, Sendable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval
    private let backoff: FullJitterBackoff

    public init(baseDelay: TimeInterval, maximumDelay: TimeInterval) throws {
        guard baseDelay.isFinite,
              maximumDelay.isFinite,
              baseDelay > 0,
              maximumDelay >= baseDelay
        else {
            throw WatchRetryPolicyError.invalidConfiguration
        }
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        backoff = try FullJitterBackoff(baseDelay: baseDelay, maximumDelay: maximumDelay)
    }

    public func nextAttemptDate(
        afterAttempt attempt: UInt64,
        now: Date,
        sample: Double
    ) -> Date {
        now.addingTimeInterval(backoff.delay(afterAttempt: attempt, sample: sample))
    }
}

public enum WatchTransferOutcome: Equatable, Sendable {
    case idle
    case busy
    case received(MemoID)
    case retryScheduled(MemoID, Date)
    case pairingRequired(MemoID)
    case needsAttention(MemoID)
    case statusUpdated(MemoID, MemoState)
}

public actor WatchTransferActivityRegistry {
    private var active: Set<MemoID> = []

    public init() {}

    public var activeMemoIDs: Set<MemoID> {
        active
    }

    public func cancelIfActive(
        _ memoID: MemoID,
        cancellation: @Sendable () -> Void
    ) -> Bool {
        guard active.contains(memoID) else { return false }
        cancellation()
        return true
    }

    func begin(_ memoID: MemoID) {
        active.insert(memoID)
    }

    func end(_ memoID: MemoID) {
        active.remove(memoID)
    }
}

public actor WatchTransferCoordinator {
    private enum CompletedUpload {
        case receipt(BridgeReceipt)
        case transient
        case pairingRequired
        case needsAttention
    }

    private let store: WatchMemoStore
    private let transport: any WatchBridgeTransport
    private let retryPolicy: WatchRetryPolicy
    private let clock: @Sendable () -> Date
    private let randomSample: @Sendable () -> Double
    private let transientFinalizationCheckpoint: (@Sendable () async -> Void)?
    private var transferOperationInProgress = false
    public nonisolated let activityRegistry: WatchTransferActivityRegistry

    public init(
        store: WatchMemoStore,
        transport: any WatchBridgeTransport,
        retryPolicy: WatchRetryPolicy,
        clock: @escaping @Sendable () -> Date = Date.init,
        randomSample: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        activityRegistry: WatchTransferActivityRegistry = WatchTransferActivityRegistry()
    ) throws {
        self.store = store
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.randomSample = randomSample
        self.activityRegistry = activityRegistry
        transientFinalizationCheckpoint = nil
    }

    init(
        store: WatchMemoStore,
        transport: any WatchBridgeTransport,
        retryPolicy: WatchRetryPolicy,
        clock: @escaping @Sendable () -> Date = Date.init,
        randomSample: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        transientFinalizationCheckpoint: @escaping @Sendable () async -> Void,
        activityRegistry: WatchTransferActivityRegistry = WatchTransferActivityRegistry()
    ) throws {
        self.store = store
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.clock = clock
        self.randomSample = randomSample
        self.activityRegistry = activityRegistry
        self.transientFinalizationCheckpoint = transientFinalizationCheckpoint
    }

    public func uploadNext() async throws -> WatchTransferOutcome {
        guard !transferOperationInProgress else { return .busy }
        transferOperationInProgress = true
        defer { transferOperationInProgress = false }

        let now = clock()
        var pending = try await store.loadPendingMetadata()
        for interrupted in pending where interrupted.state == .uploading {
            _ = try await store.recoverInterruptedUpload(memoID: interrupted.memoID)
        }
        if pending.contains(where: { $0.state == .uploading }) {
            pending = try await store.loadPendingMetadata()
        }
        let saved = pending.filter { $0.state == .saved }
        guard !saved.isEmpty else {
            return .idle
        }
        if try await store.pairingIsRequired(), let first = saved.first {
            return .pairingRequired(first.memoID)
        }
        var waiting: [(MemoID, Date)] = []
        for metadata in saved {
            if let nextAttempt = try await store.retryNotBefore(memoID: metadata.memoID),
               nextAttempt > now
            {
                waiting.append((metadata.memoID, nextAttempt))
                continue
            }
            do {
                let stored = try await store.load(memoID: metadata.memoID)
                return try await upload(stored, now: now)
            } catch WatchMemoStoreError.corruptMemo {
                continue
            }
        }
        guard let earliest = waiting.min(by: { $0.1 < $1.1 }) else {
            return .idle
        }
        return .retryScheduled(earliest.0, earliest.1)
    }

    private func upload(_ stored: StoredWatchMemo, now: Date) async throws -> WatchTransferOutcome {
        let memoID = stored.metadata.memoID
        let lease = try await store.acquireUploadLease(memoID: memoID)
        let uploading = lease.metadata
        let expectedRevision = uploading.stateRevision + 1
        let attempt = (uploading.stateRevision - 1) / 2
        let completed: CompletedUpload
        do {
            let receipt = try await withActivity(memoID) {
                try await transport.upload(
                    memo: uploading,
                    audioURL: lease.audioURL,
                    expectedRevision: expectedRevision
                )
            }
            do {
                try receipt.validateAcknowledgement(
                    for: uploading,
                    expectedRevision: expectedRevision
                )
                completed = .receipt(receipt)
            } catch {
                completed = isAuthoritativeReceiptFromEarlierAcceptedUpload(
                    receipt,
                    for: uploading,
                    expectedRevision: expectedRevision
                ) ? .receipt(receipt) : .needsAttention
            }
        } catch is CancellationError {
            _ = try await store.finishUploadLease(lease, state: .saved)
            throw CancellationError()
        } catch let failure as WatchBridgeTransportFailure {
            switch failure {
            case .transient:
                completed = .transient
            case .authentication:
                completed = .pairingRequired
            case .statusAbsent, .conflict, .permanent:
                completed = .needsAttention
            }
        } catch {
            completed = .transient
        }

        switch completed {
        case let .receipt(receipt):
            if receipt.acknowledgedRevision == expectedRevision {
                _ = try await store.finishUploadLease(lease, state: .received)
            } else {
                _ = try await store.finishUploadLease(
                    lease,
                    state: .received,
                    authoritativeRevision: receipt.acknowledgedRevision
                )
            }
            try await store.clearRetryNotBefore(memoID: memoID)
            return .received(memoID)
        case .transient:
            let nextAttempt = retryPolicy.nextAttemptDate(
                afterAttempt: attempt,
                now: now,
                sample: randomSample()
            )
            _ = try await store.finishUploadLease(
                lease,
                state: .saved,
                retryNotBefore: nextAttempt
            )
            await transientFinalizationCheckpoint?()
            return .retryScheduled(memoID, nextAttempt)
        case .pairingRequired:
            _ = try await store.finishUploadLease(
                lease,
                state: .saved,
                pairingRequired: true
            )
            try await store.clearRetryNotBefore(memoID: memoID)
            return .pairingRequired(memoID)
        case .needsAttention:
            _ = try await store.finishUploadLease(lease, state: .needsAttention)
            try await store.clearRetryNotBefore(memoID: memoID)
            return .needsAttention(memoID)
        }
    }

    public func syncNextStatus() async throws -> WatchTransferOutcome {
        guard !transferOperationInProgress else { return .busy }
        transferOperationInProgress = true
        defer { transferOperationInProgress = false }

        let pendingAcknowledgements = try await store.pendingFinalAcknowledgements()
        if try await store.pairingIsRequired() {
            if let acknowledgement = pendingAcknowledgements.first {
                return .pairingRequired(acknowledgement.memoID)
            }
            if let memo = try await store.loadPendingMetadata().first {
                return .pairingRequired(memo.memoID)
            }
            return .idle
        }
        var finalAcknowledgementDisposition: WatchTransferOutcome?
        var earliestFinalAcknowledgementRetry: (memoID: MemoID, date: Date)?
        for acknowledgement in pendingAcknowledgements {
            if let notBefore = try await store.retryNotBefore(memoID: acknowledgement.memoID),
               notBefore > clock()
            {
                if let earliest = earliestFinalAcknowledgementRetry {
                    if notBefore < earliest.date {
                        earliestFinalAcknowledgementRetry = (acknowledgement.memoID, notBefore)
                    }
                } else {
                    earliestFinalAcknowledgementRetry = (acknowledgement.memoID, notBefore)
                }
                continue
            }
            do {
                try await withActivity(acknowledgement.memoID) {
                    try await transport.acknowledgeDelivery(acknowledgement)
                }
                try await store.markFinalAcknowledged(acknowledgement)
                try await store.clearRetryNotBefore(memoID: acknowledgement.memoID)
            } catch is CancellationError {
                throw CancellationError()
            } catch WatchBridgeTransportFailure.authentication {
                try await store.markPairingRequired()
                return .pairingRequired(acknowledgement.memoID)
            } catch let failure as WatchBridgeTransportFailure {
                let retry = retryPolicy.nextAttemptDate(
                    afterAttempt: acknowledgement.stateRevision,
                    now: clock(),
                    sample: randomSample()
                )
                try await store.setRetryNotBefore(memoID: acknowledgement.memoID, date: retry)
                if failure == .conflict || failure == .permanent {
                    if finalAcknowledgementDisposition == nil {
                        finalAcknowledgementDisposition = .needsAttention(acknowledgement.memoID)
                    }
                } else if let earliest = earliestFinalAcknowledgementRetry {
                    if retry < earliest.date {
                        earliestFinalAcknowledgementRetry = (acknowledgement.memoID, retry)
                    }
                } else {
                    earliestFinalAcknowledgementRetry = (acknowledgement.memoID, retry)
                }
            } catch {
                let retry = retryPolicy.nextAttemptDate(
                    afterAttempt: acknowledgement.stateRevision,
                    now: clock(),
                    sample: randomSample()
                )
                try await store.setRetryNotBefore(memoID: acknowledgement.memoID, date: retry)
                if let earliest = earliestFinalAcknowledgementRetry {
                    if retry < earliest.date {
                        earliestFinalAcknowledgementRetry = (acknowledgement.memoID, retry)
                    }
                } else {
                    earliestFinalAcknowledgementRetry = (acknowledgement.memoID, retry)
                }
            }
        }

        let candidates = try await store.loadPendingMetadata().filter {
            switch $0.state {
            case .received, .transcribing, .readyForCodex, .inserting, .reconciling:
                true
            case .saved, .uploading, .delivered, .needsAttention:
                false
            }
        }
        for memo in candidates {
            let status: BridgeMemoStatus
            do {
                status = try await withActivity(memo.memoID) {
                    try await transport.status(for: memo)
                }
            } catch WatchBridgeTransportFailure.authentication {
                try await store.markPairingRequired()
                return .pairingRequired(memo.memoID)
            } catch WatchBridgeTransportFailure.statusAbsent {
                let stored = try await store.load(memoID: memo.memoID)
                do {
                    try await withActivity(memo.memoID) {
                        try await transport.recoverAbsentStatus(
                            memo: stored.metadata,
                            audioURL: stored.audioURL
                        )
                    }
                    return .retryScheduled(memo.memoID, clock())
                } catch WatchBridgeTransportFailure.authentication {
                    try await store.markPairingRequired()
                    return .pairingRequired(memo.memoID)
                }
            }
            if status.memoID == memo.memoID,
               status.audioSHA256 == memo.audioSHA256,
               status.state == memo.state,
               status.stateRevision == memo.stateRevision
            {
                continue
            }
            do {
                try status.validateAcknowledgement(
                    for: memo,
                    expectedRevision: status.stateRevision
                )
            } catch {
                throw WatchBridgeTransportFailure.permanent
            }
            let updated = try await store.reconcileAuthoritative(
                memoID: memo.memoID,
                state: status.state,
                revision: status.stateRevision
            )
            if updated.state == .delivered {
                let acknowledgement = FinalDeliveryAcknowledgement(
                    memoID: updated.memoID,
                    audioSHA256: updated.audioSHA256,
                    stateRevision: updated.stateRevision
                )
                do {
                    try await withActivity(acknowledgement.memoID) {
                        try await transport.acknowledgeDelivery(acknowledgement)
                    }
                    try await store.markFinalAcknowledged(acknowledgement)
                } catch is CancellationError {
                    throw CancellationError()
                } catch WatchBridgeTransportFailure.authentication {
                    try await store.markPairingRequired()
                    return .pairingRequired(memo.memoID)
                } catch {
                    // Local delivered truth and audio-retention eligibility do
                    // not depend on the transient final acknowledgement.
                }
            }
            return .statusUpdated(memo.memoID, status.state)
        }
        if let finalAcknowledgementDisposition {
            return finalAcknowledgementDisposition
        }
        if let earliestFinalAcknowledgementRetry {
            return .retryScheduled(
                earliestFinalAcknowledgementRetry.memoID,
                earliestFinalAcknowledgementRetry.date
            )
        }
        return .idle
    }

    private func withActivity<T>(
        _ memoID: MemoID,
        operation: () async throws -> T
    ) async throws -> T {
        await activityRegistry.begin(memoID)
        do {
            let result = try await operation()
            await activityRegistry.end(memoID)
            try Task.checkCancellation()
            return result
        } catch {
            await activityRegistry.end(memoID)
            throw error
        }
    }

    private func isAuthoritativeReceiptFromEarlierAcceptedUpload(
        _ receipt: BridgeReceipt,
        for uploading: VoiceMemoMetadata,
        expectedRevision: UInt64
    ) -> Bool {
        receipt.memoID == uploading.memoID
            && receipt.audioSHA256 == uploading.audioSHA256.lowercased()
            && receipt.capturedAt == uploading.capturedAt
            && receipt.localeHint == uploading.localeHint
            && receipt.acknowledgedRevision > 0
            && receipt.acknowledgedRevision < expectedRevision
            && receipt.acknowledgedRevision.isMultiple(of: 2)
    }
}
