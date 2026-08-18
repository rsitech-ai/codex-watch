import CodexBridgeService
import CodexBridgeShared
import Foundation
import Testing

@Test func operatorRetryMailboxRoundTripsMemoIDsWithoutDuplicates() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "retry-mailbox-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let mailbox = OperatorRetryMailbox(stateDirectory: root)
    let first = try MemoID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    let second = try MemoID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    try mailbox.enqueue(first)
    try mailbox.enqueue(first)
    try mailbox.enqueue(second)

    #expect(try mailbox.takeAll() == [first, second])
    #expect(try mailbox.takeAll() == [])
}
