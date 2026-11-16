import Foundation
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

    @Test("Active EQ creates active session while cleared/inactive EQ falls back to passthrough")
    func eqRoutingDecision() {
        let presetID = UUID()
        let activeRule = AppRule(
            volume: 1.0,
            muted: false,
            output: .followSystemDefault,
            eqPresetID: presetID
        )
        #expect(RoutingDecision.decide(rule: activeRule, hasActiveEQ: true) == .activeSession(gain: 1.0, muted: false))
        #expect(RoutingDecision.decide(rule: activeRule, hasActiveEQ: false) == .passthrough)
        #expect(!activeRule.isDefault)

        let noEQRule = AppRule(
            volume: 1.0,
            muted: false,
            output: .followSystemDefault,
            eqPresetID: nil
        )
        #expect(RoutingDecision.decide(rule: noEQRule) == .passthrough)
        #expect(noEQRule.isDefault)
    }

    @Test("ParametricEQParser parses AutoEQ / EqualizerAPO text and rejects invalid text")
    func parametricEQParsingAndCompilation() throws {
        let text = """
        # MOONDROP MM3A AutoEQ
        Preamp: -6.2 dB
        Filter 1: ON LSC Fc 105 Hz Gain 2.5 dB Q 0.71
        Filter 2: ON PK Fc 1000 Hz Gain -4.0 dB Q 1.41
        Filter 3: OFF PK Fc 3000 Hz Gain 5.0 dB Q 2.0
        Filter 4: ON HSC Fc 10000 Hz Gain -1.5 dB Q 0.71
        """

        let profile = try ParametricEQParser.parse(text, name: "MM3A")
        #expect(profile.name == "MM3A")
        #expect(abs(profile.preampDB - (-6.2)) < 1e-6)
        #expect(profile.bands.count == 4)
        #expect(profile.activeBandCount == 3)
        #expect(profile.bands[0].type == .lowShelf)
        #expect(profile.bands[1].type == .peaking)
        #expect(profile.bands[2].enabled == false)
        #expect(profile.bands[3].type == .highShelf)

        let compiled = CompiledEQChain.compile(profiles: [profile], sampleRate: 48_000)
        #expect(compiled.isActive == true)
        #expect(compiled.coefficients.count == 3)
        #expect(abs(compiled.preampGain - Float(pow(10.0, -6.2 / 20.0))) < 1e-4)

        #expect(throws: ParametricEQParseError.noValidFilters) {
            _ = try ParametricEQParser.parse("# just a comment\nhello world", name: "Empty")
        }
    }

    @Test("ParametricEQParser parses CiacconaTests/EQFile/eqtest.txt fixture file accurately")
    func parsesEQTestFixtureFile() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("EQFile", isDirectory: true)
            .appendingPathComponent("eqtest.txt")
        let content = try String(contentsOf: fixtureURL, encoding: .utf8)
        let profile = try ParametricEQParser.parse(
            content,
            name: fixtureURL.deletingPathExtension().lastPathComponent
        )

        #expect(profile.name == "eqtest")
        #expect(abs(profile.preampDB - (-4.0)) < 1e-6)
        #expect(profile.bands.count == 4)
        #expect(profile.activeBandCount == 4)

        let expected: [(freq: Double, gain: Double, q: Double)] = [
            (500, 2.0, 1.0),
            (1_000, 2.5, 1.0),
            (2_000, 2.0, 1.0),
            (3_000, 1.0, 1.0)
        ]
        for (band, target) in zip(profile.bands, expected) {
            #expect(band.enabled == true)
            #expect(band.type == .peaking)
            #expect(abs(band.frequencyHz - target.freq) < 1e-6)
            #expect(abs(band.gainDB - target.gain) < 1e-6)
            #expect(abs(band.q - target.q) < 1e-6)
        }

        let compiled = CompiledEQChain.compile(profiles: [profile], sampleRate: 48_000)
        #expect(compiled.isActive == true)
        #expect(compiled.coefficients.count == 4)
        #expect(compiled.hasPositiveBoost == true)
        #expect(abs(compiled.preampGain - Float(pow(10.0, -4.0 / 20.0))) < 1e-4)
    }
}
