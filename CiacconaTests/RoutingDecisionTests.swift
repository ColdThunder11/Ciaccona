import Testing
@testable import Ciaccona

@Suite("RoutingDecision Tests")
struct RoutingDecisionTests {
    @Test("Default rule produces zero-overhead passthrough")
    func defaultIsPassthrough() {
        let rule = AppRule(volume: 1.0, muted: false, output: .followSystemDefault)
        #expect(RoutingDecision.decide(rule: rule) == .passthrough)
    }

    @Test("Non-unity volume creates active session")
    func changedVolumeIsActive() {
        let quieter = AppRule(volume: 0.6, muted: false, output: .followSystemDefault)
        #expect(RoutingDecision.decide(rule: quieter) == .activeSession(gain: 0.6, muted: false))

        let boosted = AppRule(volume: 1.4, muted: false, output: .followSystemDefault)
        #expect(RoutingDecision.decide(rule: boosted) == .activeSession(gain: 1.4, muted: false))
    }

    @Test("Muted rule creates active session")
    func mutedIsActive() {
        let rule = AppRule(volume: 1.0, muted: true, output: .followSystemDefault)
        #expect(RoutingDecision.decide(rule: rule) == .activeSession(gain: 1.0, muted: true))
    }

    @Test("Custom output device creates active session even at 100% volume")
    func customDeviceIsActive() {
        let rule = AppRule(
            volume: 1.0,
            muted: false,
            output: .device(uid: "USB-DAC", lastKnownName: "USB DAC")
        )
        #expect(RoutingDecision.decide(rule: rule) == .activeSession(gain: 1.0, muted: false))
    }
}
