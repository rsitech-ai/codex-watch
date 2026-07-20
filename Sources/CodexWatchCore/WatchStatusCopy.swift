import CodexBridgeShared

public extension MemoState {
    var watchStatusText: String {
        switch self {
        case .saved:
            "Saved on Watch"
        case .uploading:
            "Sending to Mac"
        case .received, .transcribing, .readyForCodex, .inserting, .reconciling:
            "Adding to local Inbox"
        case .delivered:
            "Saved to local Inbox"
        case .needsAttention:
            "Needs attention"
        }
    }
}
