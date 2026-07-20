import CodexBridgeDelivery
import Testing

@Test func markerReconcilerClassifiesZeroOneMultipleAndIncompleteHistory() {
    let marker = "[codex-voice-memo:33333333-3333-3333-3333-333333333333]"

    #expect(MarkerReconciler.evaluate(marker: marker, historyTexts: [], authoritative: true) == .absent)
    #expect(MarkerReconciler.evaluate(
        marker: marker,
        historyTexts: ["Idea\n\(marker)"],
        authoritative: true
    ) == .delivered)
    #expect(MarkerReconciler.evaluate(
        marker: marker,
        historyTexts: [marker, "again \(marker)"],
        authoritative: true
    ) == .duplicate(count: 2))
    #expect(MarkerReconciler.evaluate(
        marker: marker,
        historyTexts: [marker],
        authoritative: false
    ) == .inconclusive)
}
