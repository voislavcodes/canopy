import XCTest
@testable import Canopy

final class QuakeVoiceTests: XCTestCase {

    // MARK: - QuakeVoice

    func testKickVoiceTriggerAndDecay() {
        var voice = QuakeVoice.kick()
        XCTAssertFalse(voice.isActive)

        voice.trigger(velocity: 0.8)
        XCTAssertTrue(voice.isActive)

        // Render enough samples for the voice to decay to silence
        let sampleRate = 44100.0
        var hadNonZero = false
        for _ in 0..<Int(sampleRate * 3) {
            let sample = voice.renderSample(sampleRate: sampleRate)
            if abs(sample) > 0.001 { hadNonZero = true }
        }

        XCTAssertTrue(hadNonZero, "Voice should produce non-zero output after trigger")
        XCTAssertFalse(voice.isActive, "Voice should auto-deactivate after decay")
    }

    func testInactiveVoiceRendersZero() {
        var voice = QuakeVoice.kick()
        let sample = voice.renderSample(sampleRate: 44100)
        XCTAssertEqual(sample, 0, "Inactive voice should produce zero output")
    }

    func testAllRegimeFactories() {
        _ = QuakeVoice.kick()
        _ = QuakeVoice.snare()
        _ = QuakeVoice.closedHat()
        _ = QuakeVoice.openHat()
        _ = QuakeVoice.tomLow()
        _ = QuakeVoice.tomHigh()
        _ = QuakeVoice.crash()
        _ = QuakeVoice.ride()
    }

    func testVoicePhysicsControlsAffectOutput() {
        let sampleRate = 44100.0

        // Render with low mass
        var voiceLow = QuakeVoice.kick()
        voiceLow.mass = 0.1
        voiceLow.trigger(velocity: 0.8)
        var sumLow: Float = 0
        for _ in 0..<512 {
            sumLow += abs(voiceLow.renderSample(sampleRate: sampleRate))
        }

        // Render with high mass
        var voiceHigh = QuakeVoice.kick()
        voiceHigh.mass = 0.9
        voiceHigh.trigger(velocity: 0.8)
        var sumHigh: Float = 0
        for _ in 0..<512 {
            sumHigh += abs(voiceHigh.renderSample(sampleRate: sampleRate))
        }

        // Different mass should produce different output
        XCTAssertNotEqual(sumLow, sumHigh, "Different mass values should produce different output")
    }

    func testDroneModeAtHighSustain() {
        var voice = QuakeVoice.kick()
        voice.sustain = 0.95  // Above 0.85 threshold
        voice.trigger(velocity: 0.8)

        let sampleRate = 44100.0
        // Render for 2 seconds — drone should keep voice active
        for _ in 0..<Int(sampleRate * 2) {
            _ = voice.renderSample(sampleRate: sampleRate)
        }
        // With high sustain (drone mode), voice may still be active
        // The drone crossover should produce self-sustaining output
        XCTAssertTrue(voice.isActive, "Voice should remain active in drone mode")
    }

    // MARK: - QuakeVoiceManager

    func testDefaultKitHas8Voices() {
        let kit = QuakeVoiceManager.defaultKit()
        XCTAssertEqual(QuakeVoiceManager.voiceCount, 8)
        XCTAssertEqual(QuakeVoiceManager.voiceNames.count, 8)
        XCTAssertEqual(QuakeVoiceManager.midiPitches.count, 8)
        _ = kit.voices
    }

    func testMIDIPitchMapping() {
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 36), 0, "MIDI 36 = kick")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 38), 1, "MIDI 38 = snare")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 42), 2, "MIDI 42 = closed hat")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 46), 3, "MIDI 46 = open hat")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 41), 4, "MIDI 41 = tom low")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 43), 5, "MIDI 43 = tom high")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 49), 6, "MIDI 49 = crash")
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 51), 7, "MIDI 51 = ride")
    }

    func testUnknownPitchReturnsNoMatch() {
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 60), -1)
        XCTAssertEqual(QuakeVoiceManager.voiceIndex(forPitch: 0), -1)
    }

    func testTriggerByPitch() {
        var kit = QuakeVoiceManager.defaultKit()
        let triggered = kit.trigger(pitch: 36, velocity: 0.8)
        XCTAssertTrue(triggered, "Should trigger kick at MIDI 36")

        let notTriggered = kit.trigger(pitch: 60, velocity: 0.8)
        XCTAssertFalse(notTriggered, "Should not trigger at unknown pitch")
    }

    func testConfigureVoice() {
        var kit = QuakeVoiceManager.defaultKit()
        kit.configureVoice(index: 0, mass: 0.8, surface: 0.5, force: 0.9, sustain: 0.2)
        // Trigger and verify it still produces output
        kit.trigger(pitch: 36, velocity: 0.8)
        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(kit.renderSample(sampleRate: 44100))
        }
        XCTAssertGreaterThan(sum, 0, "Configured voice should produce output")
    }

    func testPerVoiceIndependence() {
        var kit = QuakeVoiceManager.defaultKit()
        // Configure kick and snare differently
        kit.configureVoice(index: 0, mass: 0.9, surface: 0.1, force: 0.9, sustain: 0.1) // heavy kick
        kit.configureVoice(index: 1, mass: 0.1, surface: 0.8, force: 0.3, sustain: 0.5) // light snare

        // Trigger kick, collect samples
        kit.trigger(pitch: 36, velocity: 0.8)
        var kickSum: Float = 0
        for _ in 0..<200 {
            kickSum += abs(kit.renderSample(sampleRate: 44100))
        }

        // Reset and trigger snare
        var kit2 = QuakeVoiceManager.defaultKit()
        kit2.configureVoice(index: 0, mass: 0.9, surface: 0.1, force: 0.9, sustain: 0.1)
        kit2.configureVoice(index: 1, mass: 0.1, surface: 0.8, force: 0.3, sustain: 0.5)
        kit2.trigger(pitch: 38, velocity: 0.8)
        var snareSum: Float = 0
        for _ in 0..<200 {
            snareSum += abs(kit2.renderSample(sampleRate: 44100))
        }

        // Both should produce output but sound different
        XCTAssertGreaterThan(kickSum, 0)
        XCTAssertGreaterThan(snareSum, 0)
        XCTAssertNotEqual(kickSum, snareSum, accuracy: 0.001, "Different voice configs should produce different output")
    }

    func testAllVoicesRenderSimultaneously() {
        var kit = QuakeVoiceManager.defaultKit()
        let sampleRate = 44100.0

        for pitch in QuakeVoiceManager.midiPitches {
            kit.trigger(pitch: pitch, velocity: 0.8)
        }

        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(kit.renderSample(sampleRate: sampleRate))
        }
        XCTAssertGreaterThan(sum, 0, "All voices should produce combined output")
    }

    func testNoteReceiverConformance() {
        var kit = QuakeVoiceManager.defaultKit()
        kit.noteOn(pitch: 36, velocity: 0.8, frequency: 0)
        let sample = kit.renderSample(sampleRate: 44100)
        XCTAssertNotEqual(sample, 0, "noteOn should trigger drum voice")
    }

    func testOrbitalCoupledTrigger() {
        var kit = QuakeVoiceManager.defaultKit()
        kit.triggerWithOrbitalState(voiceIndex: 0, velocity: 0.8, orbitalSpeed: 1.5, orbitalStress: 0.3)
        var sum: Float = 0
        for _ in 0..<100 {
            sum += abs(kit.renderSample(sampleRate: 44100))
        }
        XCTAssertGreaterThan(sum, 0, "Orbital-coupled trigger should produce output")
    }

    func testVoiceNames() {
        let expected = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]
        XCTAssertEqual(QuakeVoiceManager.voiceNames, expected)
    }
}
