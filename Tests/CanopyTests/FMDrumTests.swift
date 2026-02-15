import XCTest
@testable import Canopy

final class FMDrumTests: XCTestCase {

    // MARK: - FMDrumVoice

    func testKickVoiceTriggerAndDecay() {
        var voice = FMDrumVoice.kickPreset()
        XCTAssertFalse(voice.isActive)

        voice.trigger(velocity: 0.8)
        XCTAssertTrue(voice.isActive)

        // Render enough samples for the voice to decay to silence
        // Kick ampDecay=0.4s → needs ~2.8s to reach 0.001 threshold
        let sampleRate = 44100.0
        var lastSample: Float = 0
        var hadNonZero = false
        for _ in 0..<Int(sampleRate * 4) { // 4 seconds
            lastSample = voice.renderSample(sampleRate: sampleRate)
            if abs(lastSample) > 0.001 { hadNonZero = true }
        }

        XCTAssertTrue(hadNonZero, "Voice should produce non-zero output after trigger")
        XCTAssertFalse(voice.isActive, "Voice should auto-deactivate after decay")
    }

    func testSnareVoiceHasNoiseContent() {
        var voice = FMDrumVoice.snarePreset()
        XCTAssertEqual(voice.noiseMix, 0.5, "Snare should have 50% noise mix")

        voice.trigger(velocity: 0.8)

        // Render a few samples and check non-zero output
        let sampleRate = 44100.0
        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(voice.renderSample(sampleRate: sampleRate))
        }
        XCTAssertGreaterThan(sum, 0, "Snare should produce output")
    }

    func testInactiveVoiceRendersZero() {
        var voice = FMDrumVoice.kickPreset()
        let sample = voice.renderSample(sampleRate: 44100)
        XCTAssertEqual(sample, 0, "Inactive voice should produce zero output")
    }

    // MARK: - FMDrumKit

    func testDefaultKitHas8Voices() {
        let kit = FMDrumKit.defaultKit()
        XCTAssertEqual(FMDrumKit.voiceCount, 8)
        XCTAssertEqual(FMDrumKit.voiceNames.count, 8)
        XCTAssertEqual(FMDrumKit.midiPitches.count, 8)
        // Verify tuple exists (can't count tuple elements, but voiceCount is correct)
        _ = kit.voices
    }

    func testMIDIPitchMapping() {
        // GM standard
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 36), 0, "MIDI 36 = kick")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 38), 1, "MIDI 38 = snare")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 42), 2, "MIDI 42 = closed hat")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 46), 3, "MIDI 46 = open hat")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 41), 4, "MIDI 41 = tom low")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 43), 5, "MIDI 43 = tom high")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 49), 6, "MIDI 49 = crash")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 51), 7, "MIDI 51 = ride")
    }

    func testUnknownPitchReturnsNoMatch() {
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 60), -1, "Unknown pitch should return -1")
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 0), -1)
        XCTAssertEqual(FMDrumKit.voiceIndex(forPitch: 127), -1)
    }

    func testTriggerByPitch() {
        var kit = FMDrumKit.defaultKit()
        let triggered = kit.trigger(pitch: 36, velocity: 0.8)
        XCTAssertTrue(triggered, "Should trigger kick at MIDI 36")

        let notTriggered = kit.trigger(pitch: 60, velocity: 0.8)
        XCTAssertFalse(notTriggered, "Should not trigger at unknown pitch")
    }

    func testAllVoicesRenderSimultaneously() {
        var kit = FMDrumKit.defaultKit()
        let sampleRate = 44100.0

        // Trigger all 8 voices
        for pitch in FMDrumKit.midiPitches {
            kit.trigger(pitch: pitch, velocity: 0.8)
        }

        // Render and verify output
        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(kit.renderSample(sampleRate: sampleRate))
        }
        XCTAssertGreaterThan(sum, 0, "All voices should produce combined output")
    }

    func testConfigureVoice() {
        var kit = FMDrumKit.defaultKit()
        kit.configureVoice(index: 0, carrierFreq: 100, modulatorRatio: 2.0,
                           fmDepth: 3.0, noiseMix: 0.1, ampDecay: 0.5,
                           pitchEnvAmount: 1.5, pitchDecay: 0.04, level: 0.7)

        // Trigger the configured voice and verify it produces output
        kit.triggerVoice(index: 0, velocity: 0.8)
        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(kit.renderSample(sampleRate: 44100))
        }
        XCTAssertGreaterThan(sum, 0, "Configured voice should produce output")
    }

    // MARK: - NoteReceiver Conformance

    func testNoteReceiverConformance() {
        var kit = FMDrumKit.defaultKit()
        // NoteReceiver.noteOn should trigger via MIDI pitch
        kit.noteOn(pitch: 36, velocity: 0.8, frequency: 0) // frequency ignored for drums
        let sample = kit.renderSample(sampleRate: 44100)
        XCTAssertNotEqual(sample, 0, "noteOn should trigger drum voice")
    }

    func testNoteOffIsNoOp() {
        var kit = FMDrumKit.defaultKit()
        kit.trigger(pitch: 36, velocity: 0.8)
        // noteOff should be a no-op for drums (they're one-shot)
        kit.noteOff(pitch: 36)
        // Voice should still be active (it decays naturally)
        let sample = kit.renderSample(sampleRate: 44100)
        XCTAssertNotEqual(sample, 0, "noteOff should not immediately silence drum voice")
    }

    // MARK: - DrumKitConfig Codable

    func testDrumKitConfigCodableRoundTrip() throws {
        let config = DrumKitConfig()
        XCTAssertEqual(config.voices.count, 8)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DrumKitConfig.self, from: data)

        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.voices.count, 8)
    }

    func testDrumVoiceConfigCodableRoundTrip() throws {
        let config = DrumVoiceConfig(
            carrierFreq: 120, modulatorRatio: 2.5, fmDepth: 4.0,
            noiseMix: 0.3, ampDecay: 0.25, pitchEnvAmount: 1.5,
            pitchDecay: 0.04, level: 0.7
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DrumVoiceConfig.self, from: data)

        XCTAssertEqual(decoded, config)
    }

    func testSoundTypeDrumKitCodableRoundTrip() throws {
        let soundType = SoundType.drumKit(DrumKitConfig())
        let data = try JSONEncoder().encode(soundType)
        let decoded = try JSONDecoder().decode(SoundType.self, from: data)
        XCTAssertEqual(decoded, soundType)
    }

    // MARK: - Factory Presets

    func testAllFactoryPresetsExist() {
        _ = FMDrumVoice.kickPreset()
        _ = FMDrumVoice.snarePreset()
        _ = FMDrumVoice.closedHatPreset()
        _ = FMDrumVoice.openHatPreset()
        _ = FMDrumVoice.tomLowPreset()
        _ = FMDrumVoice.tomHighPreset()
        _ = FMDrumVoice.crashPreset()
        _ = FMDrumVoice.ridePreset()
    }

    func testVoiceNamesMatchExpected() {
        let expected = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]
        XCTAssertEqual(FMDrumKit.voiceNames, expected)
    }
}
