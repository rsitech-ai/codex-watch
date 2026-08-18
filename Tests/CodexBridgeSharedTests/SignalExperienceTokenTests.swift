@testable import CodexBridgeShared
import Testing

@Test func signalExperienceTokensStayOnTheWatchCyanSpine() {
    #expect(SignalExperienceToken.RGB.active == (red: 0.18, green: 0.86, blue: 0.94))
    #expect(SignalExperienceToken.RGB.confirmed == (red: 0.69, green: 0.93, blue: 0.22))
    #expect(SignalExperienceToken.RGB.attention == (red: 1.00, green: 0.68, blue: 0.18))
    #expect(SignalExperienceToken.RGB.destructive == (red: 1.00, green: 0.27, blue: 0.32))
    #expect(SignalExperienceToken.Motion.springResponse == 0.35)
    #expect(SignalExperienceToken.Motion.springDamping == 1.0)
    #expect(SignalExperienceToken.Motion.crossFadeDuration == 0.2)
}
