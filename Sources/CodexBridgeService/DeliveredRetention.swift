import CodexBridgeDelivery
import CodexBridgeShared
import Foundation

public enum BridgeDeliveredRetentionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidDeliveryState
}

public struct BridgeDeliveredRetentionResult: Equatable, Sendable {
    public let archivedMemoIDs: [MemoID]
    public let purgedMemoIDs: [MemoID]

    public init(archivedMemoIDs: [MemoID], purgedMemoIDs: [MemoID]) {
        self.archivedMemoIDs = archivedMemoIDs
        self.purgedMemoIDs = purgedMemoIDs
    }
}

public enum BridgeRetentionMaintenanceLoop {
    public static func run(
        interval: Duration = .seconds(6 * 60 * 60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        onFailure: @escaping @Sendable () async -> Void = {},
        maintenance: @escaping @Sendable () async throws -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await sleep(interval)
                try Task.checkCancellation()
                try await maintenance()
            } catch is CancellationError {
                return
            } catch {
                // Retention failure is fail-safe: keep the private archive and
                // retry at the next interval rather than deleting partially.
                await onFailure()
            }
        }
    }
}

public actor BridgeDeliveredRetentionController {
    private let intakeStore: IntakeStore
    private let journal: DeliveryJournal
    private let retentionInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private let pageSize = 128

    public init(
        intakeStore: IntakeStore,
        journal: DeliveryJournal,
        retentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard retentionInterval.isFinite, retentionInterval > 0 else {
            throw BridgeDeliveredRetentionError.invalidConfiguration
        }
        self.intakeStore = intakeStore
        self.journal = journal
        self.retentionInterval = retentionInterval
        self.clock = clock
    }

    public func retainDelivered(_ memoID: MemoID) async throws {
        let record = try journal.load(memoID: memoID)
        guard record.state == .delivered else {
            throw BridgeDeliveredRetentionError.invalidDeliveryState
        }
        try await intakeStore.retainDelivered(
            memoID: memoID,
            deliveredAt: record.updatedAt
        )
    }

    @discardableResult
    public func performMaintenance() async throws -> BridgeDeliveredRetentionResult {
        let archived = try await archiveVerifiedDeliveries()
        let cutoff = clock().addingTimeInterval(-retentionInterval)
        let purged = try await purgeDelivered(beforeOrAt: cutoff)
        return BridgeDeliveredRetentionResult(
            archivedMemoIDs: archived,
            purgedMemoIDs: purged
        )
    }

    @discardableResult
    public func purgeAllDelivered() async throws -> [MemoID] {
        _ = try await archiveVerifiedDeliveries()
        return try await purgeDelivered(beforeOrAt: .distantFuture)
    }

    private func archiveVerifiedDeliveries() async throws -> [MemoID] {
        var archived: [MemoID] = []
        var cursor: MemoID?
        while true {
            let page = try await intakeStore.committedRecordPage(
                maximumEntries: pageSize,
                afterMemoID: cursor
            )
            for record in page.records {
                do {
                    let delivery = try journal.load(memoID: record.memoID)
                    guard delivery.state == .delivered else { continue }
                    try await intakeStore.retainDelivered(
                        memoID: record.memoID,
                        deliveredAt: delivery.updatedAt
                    )
                    archived.append(record.memoID)
                } catch DeliveryJournalError.notFound {
                    continue
                }
            }
            guard page.hasMore, let last = page.records.last?.memoID else { break }
            cursor = last
        }
        return archived.sorted { $0.rawValue < $1.rawValue }
    }

    private func purgeDelivered(beforeOrAt cutoff: Date) async throws -> [MemoID] {
        var candidates: [RetainedIntakeRecord] = []
        var cursor: MemoID?
        while true {
            let page = try await intakeStore.retainedRecordPage(
                maximumEntries: pageSize,
                afterMemoID: cursor
            )
            candidates.append(contentsOf: page.records.filter { $0.deliveredAt <= cutoff })
            guard page.hasMore, let last = page.records.last?.memoID else { break }
            cursor = last
        }

        var purged: [MemoID] = []
        for candidate in candidates {
            do {
                try journal.removeDelivered(
                    memoID: candidate.memoID,
                    deliveredBeforeOrAt: cutoff
                )
            } catch DeliveryJournalError.notFound {
                // A previous attempt may have removed the journal just before
                // a crash. The retained manifest still proves the cleanup age.
            }
            try await intakeStore.removeRetained(
                memoID: candidate.memoID,
                deliveredBeforeOrAt: cutoff
            )
            purged.append(candidate.memoID)
        }
        return purged.sorted { $0.rawValue < $1.rawValue }
    }
}
