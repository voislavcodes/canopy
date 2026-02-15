import XCTest
@testable import Canopy

final class DrumSequencerTests: XCTestCase {

    // MARK: - Drum Grid Note Mapping

    func testDrumGridWritesCorrectMIDIPitches() {
        // Simulate what the drum grid does: write NoteEvents at GM MIDI pitches
        let midiPitches = FMDrumKit.midiPitches
        var sequence = NoteSequence(lengthInBeats: 4)

        // Toggle kick on step 0
        sequence.notes.append(NoteEvent(
            pitch: midiPitches[0], velocity: 0.8,
            startBeat: 0, duration: NoteSequence.stepDuration
        ))

        // Toggle snare on step 4
        sequence.notes.append(NoteEvent(
            pitch: midiPitches[1], velocity: 0.8,
            startBeat: 4 * NoteSequence.stepDuration, duration: NoteSequence.stepDuration
        ))

        // Toggle closed hat on step 0
        sequence.notes.append(NoteEvent(
            pitch: midiPitches[2], velocity: 0.8,
            startBeat: 0, duration: NoteSequence.stepDuration
        ))

        XCTAssertEqual(sequence.notes.count, 3)
        XCTAssertEqual(sequence.notes[0].pitch, 36, "Kick should be MIDI 36")
        XCTAssertEqual(sequence.notes[1].pitch, 38, "Snare should be MIDI 38")
        XCTAssertEqual(sequence.notes[2].pitch, 42, "Closed hat should be MIDI 42")
    }

    func testDrumGridToggleRemovesNote() {
        let kickPitch = FMDrumKit.midiPitches[0]
        var sequence = NoteSequence(lengthInBeats: 4)

        // Add kick on step 0
        let step = 0
        let stepBeat = Double(step) * NoteSequence.stepDuration
        sequence.notes.append(NoteEvent(
            pitch: kickPitch, velocity: 0.8,
            startBeat: stepBeat, duration: NoteSequence.stepDuration
        ))
        XCTAssertEqual(sequence.notes.count, 1)

        // Toggle off (remove)
        if let idx = sequence.notes.firstIndex(where: {
            $0.pitch == kickPitch && Int(round($0.startBeat / NoteSequence.stepDuration)) == step
        }) {
            sequence.notes.remove(at: idx)
        }
        XCTAssertEqual(sequence.notes.count, 0)
    }

    // MARK: - Probability on Drum Events

    func testProbabilityAppliesToDrumEvents() {
        var event = NoteEvent(
            pitch: FMDrumKit.midiPitches[0], velocity: 0.8,
            startBeat: 0, duration: NoteSequence.stepDuration
        )
        event.probability = 0.5
        XCTAssertEqual(event.probability, 0.5)
    }

    func testRatchetAppliesToDrumEvents() {
        var event = NoteEvent(
            pitch: FMDrumKit.midiPitches[1], velocity: 0.8,
            startBeat: 0, duration: NoteSequence.stepDuration
        )
        event.ratchetCount = 3
        XCTAssertEqual(event.ratchetCount, 3)
    }

    // MARK: - Drum Sequence Codable Round-Trip

    func testDrumSequenceCodableRoundTrip() throws {
        var sequence = NoteSequence(lengthInBeats: 4)
        for (i, pitch) in FMDrumKit.midiPitches.enumerated() {
            sequence.notes.append(NoteEvent(
                pitch: pitch, velocity: 0.8,
                startBeat: Double(i) * NoteSequence.stepDuration,
                duration: NoteSequence.stepDuration
            ))
        }

        let data = try JSONEncoder().encode(sequence)
        let decoded = try JSONDecoder().decode(NoteSequence.self, from: data)

        XCTAssertEqual(decoded.notes.count, 8)
        for (i, pitch) in FMDrumKit.midiPitches.enumerated() {
            XCTAssertEqual(decoded.notes[i].pitch, pitch)
        }
    }

    // MARK: - Drum SoundPatch

    func testDrumNodeSoundPatch() throws {
        let patch = SoundPatch(
            name: "Drums",
            soundType: .drumKit(DrumKitConfig()),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.1, sustain: 0.0, release: 0.05)
        )

        // Verify it's a drum kit
        if case .drumKit(let config) = patch.soundType {
            XCTAssertEqual(config.voices.count, 8)
        } else {
            XCTFail("Expected drumKit sound type")
        }

        // Codable round-trip
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(SoundPatch.self, from: data)
        XCTAssertEqual(decoded, patch)
    }

    // MARK: - Drum Preset

    func testDrumPresetUsesDrumKit() {
        let preset = NodePreset.find("drums")
        XCTAssertNotNil(preset)
        if case .drumKit = preset!.defaultPatch.soundType {
            // correct
        } else {
            XCTFail("Drums preset should use .drumKit sound type")
        }
    }

    func testNonDrumPresetsUseOscillator() {
        for id in ["melody", "bass", "pad", "arp", "fx"] {
            let preset = NodePreset.find(id)
            XCTAssertNotNil(preset, "\(id) preset should exist")
            if case .oscillator = preset!.defaultPatch.soundType {
                // correct
            } else {
                XCTFail("\(id) preset should use .oscillator sound type")
            }
        }
    }
}
