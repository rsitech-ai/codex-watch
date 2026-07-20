import CodexBridgeShared
import CodexWatchCore
import Testing

@Suite struct WatchStatusCopyTests {
    @Test func mapsEveryDurableMemoStateToVerifiableWatchCopy() {
        #expect(MemoState.saved.watchStatusText == "Saved on Watch")
        #expect(MemoState.uploading.watchStatusText == "Sending to Mac")
        #expect(MemoState.received.watchStatusText == "Adding to local Inbox")
        #expect(MemoState.transcribing.watchStatusText == "Adding to local Inbox")
        #expect(MemoState.readyForCodex.watchStatusText == "Adding to local Inbox")
        #expect(MemoState.inserting.watchStatusText == "Adding to local Inbox")
        #expect(MemoState.reconciling.watchStatusText == "Adding to local Inbox")
        #expect(MemoState.delivered.watchStatusText == "Saved to local Inbox")
        #expect(MemoState.needsAttention.watchStatusText == "Needs attention")
    }
}
