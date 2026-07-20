import CodexBridgeDelivery
import CodexBridgeShared
import Foundation

public struct DeliveryCompletionPublisher: Sendable {
    private let intakeStore: IntakeStore
    private let journal: DeliveryJournal
    private let finalStatusStore: FinalDeliveryStatusStore
    private let retainDelivered: @Sendable (MemoID) async throws -> Void

    public init(
        intakeStore: IntakeStore,
        journal: DeliveryJournal,
        finalStatusStore: FinalDeliveryStatusStore,
        retainDelivered: @escaping @Sendable (MemoID) async throws -> Void
    ) {
        self.intakeStore = intakeStore
        self.journal = journal
        self.finalStatusStore = finalStatusStore
        self.retainDelivered = retainDelivered
    }

    public func publishAndRetain(_ memoID: MemoID) async throws {
        if try await finalStatusStore.receipt(for: memoID) != nil {
            try await retainDelivered(memoID)
            return
        }
        guard let intakeReceipt = try await intakeStore.receipt(for: memoID) else {
            guard try await intakeStore.retainedRecord(for: memoID) != nil else {
                throw IntakeStoreError.corruptRecord
            }
            try await retainDelivered(memoID)
            return
        }
        let delivery = try journal.load(memoID: memoID)
        guard delivery.state == .delivered,
              delivery.memoID == intakeReceipt.memoID,
              delivery.audioSHA256 == intakeReceipt.audioSHA256,
              delivery.revision <= UInt64.max - intakeReceipt.acknowledgedRevision
        else { throw BridgeDeliveredRetentionError.invalidDeliveryState }
        let receipt = try FinalDeliveryReceipt(
            memoID: memoID,
            audioSHA256: delivery.audioSHA256,
            stateRevision: intakeReceipt.acknowledgedRevision + delivery.revision,
            deliveredAt: delivery.updatedAt
        )
        try await finalStatusStore.publish(receipt)
        try await retainDelivered(memoID)
    }
}
