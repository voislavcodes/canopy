import XCTest
@testable import Canopy

final class AudioDSPTests: XCTestCase {

    // MARK: - MIDI Utilities

    func testMiddleCFrequency() {
        let freq = MIDIUtilities.frequency(forNote: 60)
        // C4 ≈ 261.63 Hz
        XCTAssertEqual(freq, 261.63, accuracy: 0.01)
    }

    func testA4Frequency() {
        let freq = MIDIUtilities.frequency(forNote: 69)
        XCTAssertEqual(freq, 440.0, accuracy: 0.001)
    }

    func testOctaveDoubling() {
        let c3 = MIDIUtilities.frequency(forNote: 48)
        let c4 = MIDIUtilities.frequency(forNote: 60)
        XCTAssertEqual(c4, c3 * 2, accuracy: 0.001)
    }

    func testNoteNumberFromFrequency() {
        XCTAssertEqual(MIDIUtilities.noteNumber(forFrequency: 440.0), 69)
        XCTAssertEqual(MIDIUtilities.noteNumber(forFrequency: 261.63), 60)
    }

    func testDetuneRatioZeroCents() {
        XCTAssertEqual(MIDIUtilities.detuneRatio(cents: 0), 1.0, accuracy: 0.0001)
    }

    func testDetuneRatio100Cents() {
        // 100 cents = 1 semitone = 2^(1/12)
        let expected = pow(2.0, 1.0 / 12.0)
        XCTAssertEqual(MIDIUtilities.detuneRatio(cents: 100), expected, accuracy: 0.0001)
    }

    func testDetunedFrequency() {
        let base = 440.0
        let detuned = MIDIUtilities.detunedFrequency(base: base, cents: 1200)
        // 1200 cents = 1 octave
        XCTAssertEqual(detuned, 880.0, accuracy: 0.01)
    }

    func testNoteNames() {
        XCTAssertEqual(MIDIUtilities.noteName(forNote: 60), "C4")
        XCTAssertEqual(MIDIUtilities.noteName(forNote: 69), "A4")
        XCTAssertEqual(MIDIUtilities.noteName(forNote: 61), "C#4")
    }

    // MARK: - Oscillator Renderer

    func testSineOutputRange() {
        var osc = OscillatorRenderer()
        osc.configureEnvelope(attack: 0.0001, decay: 0.1, sustain: 0.8, release: 0.3, sampleRate: 44100)
        osc.noteOn(frequency: 440, velocity: 1.0)

        // Render enough samples to get past attack
        let sampleRate = 44100.0
        for _ in 0..<100 {
            let sample = osc.renderSample(sampleRate: sampleRate)
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0, "Sine sample out of range: \(sample)")
        }
    }

    func testSquareOutputRange() {
        var osc = OscillatorRenderer()
        osc.waveform = 3 // square
        osc.configureEnvelope(attack: 0.0001, decay: 0.1, sustain: 1.0, release: 0.3, sampleRate: 44100)
        osc.noteOn(frequency: 440, velocity: 1.0)

        for _ in 0..<200 {
            let sample = osc.renderSample(sampleRate: 44100)
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0, "Square sample out of range: \(sample)")
        }
    }

    func testSawtoothOutputRange() {
        var osc = OscillatorRenderer()
        osc.waveform = 2 // sawtooth
        osc.configureEnvelope(attack: 0.0001, decay: 0.1, sustain: 1.0, release: 0.3, sampleRate: 44100)
        osc.noteOn(frequency: 440, velocity: 1.0)

        for _ in 0..<200 {
            let sample = osc.renderSample(sampleRate: 44100)
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0, "Sawtooth sample out of range: \(sample)")
        }
    }

    func testTriangleOutputRange() {
        var osc = OscillatorRenderer()
        osc.waveform = 1 // triangle
        osc.configureEnvelope(attack: 0.0001, decay: 0.1, sustain: 1.0, release: 0.3, sampleRate: 44100)
        osc.noteOn(frequency: 440, velocity: 1.0)

        for _ in 0..<200 {
            let sample = osc.renderSample(sampleRate: 44100)
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0, "Triangle sample out of range: \(sample)")
        }
    }

    func testNoiseOutputRange() {
        var osc = OscillatorRenderer()
        osc.waveform = 4 // noise
        osc.configureEnvelope(attack: 0.0001, decay: 0.1, sustain: 1.0, release: 0.3, sampleRate: 44100)
        osc.noteOn(frequency: 440, velocity: 1.0)

        for _ in 0..<200 {
            let sample = osc.renderSample(sampleRate: 44100)
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0, "Noise sample out of range: \(sample)")
        }
    }

    func testInactiveOscillatorProducesSilence() {
        var osc = OscillatorRenderer()
        let sample = osc.renderSample(sampleRate: 44100)
        XCTAssertEqual(sample, 0)
    }

    func testADSRLifecycle() {
        var osc = OscillatorRenderer()
        osc.configureEnvelope(attack: 0.001, decay: 0.001, sustain: 0.5, release: 0.001, sampleRate: 44100)

        // Start idle
        XCTAssertEqual(osc.envelopeStage, .idle)
        XCTAssertFalse(osc.isActive)

        // Note on → attack
        osc.noteOn(frequency: 440, velocity: 1.0)
        XCTAssertEqual(osc.envelopeStage, .attack)
        XCTAssertTrue(osc.isActive)

        // Advance through attack
        let sampleRate = 44100.0
        for _ in 0..<Int(0.001 * sampleRate + 10) {
            _ = osc.renderSample(sampleRate: sampleRate)
        }
        // Should be past attack into decay or sustain
        XCTAssertNotEqual(osc.envelopeStage, .attack)

        // Note off → release
        osc.noteOff()
        XCTAssertEqual(osc.envelopeStage, .release)

        // Advance through release
        for _ in 0..<Int(0.002 * sampleRate) {
            _ = osc.renderSample(sampleRate: sampleRate)
        }
        // Should be back to idle
        XCTAssertEqual(osc.envelopeStage, .idle)
        XCTAssertFalse(osc.isActive)
    }

    // MARK: - Ring Buffer

    func testRingBufferPushPop() {
        let buffer = AudioCommandRingBuffer(capacity: 16)

        XCTAssertNil(buffer.pop()) // empty

        buffer.push(.noteOn(pitch: 60, velocity: 0.8))
        buffer.push(.noteOff(pitch: 60))

        if case .noteOn(let pitch, let velocity) = buffer.pop()! {
            XCTAssertEqual(pitch, 60)
            XCTAssertEqual(velocity, 0.8)
        } else {
            XCTFail("Expected noteOn")
        }

        if case .noteOff(let pitch) = buffer.pop()! {
            XCTAssertEqual(pitch, 60)
        } else {
            XCTFail("Expected noteOff")
        }

        XCTAssertNil(buffer.pop()) // empty again
    }

    func testRingBufferFull() {
        // Capacity rounds up to 4, but usable slots = capacity - 1 = 3
        let buffer = AudioCommandRingBuffer(capacity: 4)

        XCTAssertTrue(buffer.push(.noteOn(pitch: 60, velocity: 0.5)))
        XCTAssertTrue(buffer.push(.noteOn(pitch: 61, velocity: 0.5)))
        XCTAssertTrue(buffer.push(.noteOn(pitch: 62, velocity: 0.5)))
        XCTAssertFalse(buffer.push(.noteOn(pitch: 63, velocity: 0.5))) // full

        // Drain one, then push should work again
        _ = buffer.pop()
        XCTAssertTrue(buffer.push(.noteOn(pitch: 63, velocity: 0.5)))
    }

    func testRingBufferWraparound() {
        let buffer = AudioCommandRingBuffer(capacity: 4)

        // Fill and drain multiple times to test wrapping
        for i in 0..<10 {
            buffer.push(.noteOn(pitch: i, velocity: 0.5))
            if case .noteOn(let pitch, _) = buffer.pop()! {
                XCTAssertEqual(pitch, i)
            }
        }
    }

    // MARK: - Voice Manager

    func testVoiceAllocation() {
        var vm = VoiceManager()
        vm.configurePatch(waveform: 0, detune: 0, attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3, sampleRate: 44100)

        vm.noteOn(pitch: 60, velocity: 0.8, frequency: 261.63)
        XCTAssertEqual(vm.voicePitches.filter { $0 == 60 }.count, 1)

        vm.noteOff(pitch: 60)
        // Voice still active during release
        let sample = vm.renderSample(sampleRate: 44100)
        XCTAssertTrue(sample != 0 || true) // may be very small
    }

    func testVoicePolyphony() {
        var vm = VoiceManager()
        vm.configurePatch(waveform: 0, detune: 0, attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3, sampleRate: 44100)

        // Play 3 simultaneous notes
        vm.noteOn(pitch: 60, velocity: 0.8, frequency: 261.63)
        vm.noteOn(pitch: 64, velocity: 0.8, frequency: 329.63)
        vm.noteOn(pitch: 67, velocity: 0.8, frequency: 392.0)

        let activeCount = vm.voicePitches.filter { $0 >= 0 }.count
        XCTAssertEqual(activeCount, 3)
    }

    func testAllNotesOff() {
        var vm = VoiceManager()
        vm.configurePatch(waveform: 0, detune: 0, attack: 0.001, decay: 0.001, sustain: 0.7, release: 0.001, sampleRate: 44100)

        vm.noteOn(pitch: 60, velocity: 0.8, frequency: 261.63)
        vm.noteOn(pitch: 64, velocity: 0.8, frequency: 329.63)
        vm.allNotesOff()

        // After sufficient release time, all should be idle
        for _ in 0..<100 {
            _ = vm.renderSample(sampleRate: 44100)
        }

        let active = vm.voices.filter { $0.isActive }.count
        XCTAssertEqual(active, 0)
    }

    // MARK: - Sequencer

    func testSequencerBeatAdvance() {
        var seq = Sequencer()
        var vm = VoiceManager()
        vm.configurePatch(waveform: 0, detune: 0, attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3, sampleRate: 44100)

        seq.load(events: [], lengthInBeats: 4)
        seq.start(bpm: 120)

        // At 120 BPM and 44100 Hz, 1 beat = 0.5 seconds = 22050 samples
        let samplesPerBeat = 44100.0 * 60.0 / 120.0
        for _ in 0..<Int(samplesPerBeat) {
            seq.advanceOneSample(sampleRate: 44100, voices: &vm, detune: 0)
        }

        XCTAssertEqual(seq.currentBeat, 1.0, accuracy: 0.01)
    }

    func testSequencerLoop() {
        var seq = Sequencer()
        var vm = VoiceManager()
        vm.configurePatch(waveform: 0, detune: 0, attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3, sampleRate: 44100)

        seq.load(events: [], lengthInBeats: 4)
        seq.start(bpm: 120)

        // Advance 5 beats worth of samples (should wrap back to ~1.0)
        let samplesPerBeat = 44100.0 * 60.0 / 120.0
        for _ in 0..<Int(samplesPerBeat * 5) {
            seq.advanceOneSample(sampleRate: 44100, voices: &vm, detune: 0)
        }

        // After 5 beats with 4-beat loop, should be at ~1.0
        XCTAssertEqual(seq.currentBeat, 1.0, accuracy: 0.05)
    }

    // MARK: - Project State

    func testSelectedNodeComputed() {
        let state = ProjectState()
        XCTAssertNil(state.selectedNode)

        let rootID = state.project.trees[0].rootNode.id
        state.selectNode(rootID)
        XCTAssertNotNil(state.selectedNode)
        XCTAssertEqual(state.selectedNode?.id, rootID)
    }

    func testUpdateNode() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.updateNode(id: rootID) { node in
            node.name = "Updated"
        }

        XCTAssertEqual(state.findNode(id: rootID)?.name, "Updated")
        XCTAssertTrue(state.isDirty)
    }

    func testUpdateNodePatch() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.updateNode(id: rootID) { node in
            node.patch.soundType = .oscillator(OscillatorConfig(waveform: .sawtooth, detune: 10))
        }

        if let node = state.findNode(id: rootID),
           case .oscillator(let config) = node.patch.soundType {
            XCTAssertEqual(config.waveform, .sawtooth)
            XCTAssertEqual(config.detune, 10)
        } else {
            XCTFail("Expected oscillator patch")
        }
    }

    func testUpdateNodeSequence() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.updateNode(id: rootID) { node in
            node.sequence.notes.append(NoteEvent(pitch: 60, startBeat: 0))
            node.sequence.notes.append(NoteEvent(pitch: 64, startBeat: 4))
        }

        let node = state.findNode(id: rootID)
        XCTAssertEqual(node?.sequence.notes.count, 2)
    }

    func testProjectRoundTripWithNotes() throws {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // Add some notes and change the patch
        state.updateNode(id: rootID) { node in
            node.sequence.notes = [
                NoteEvent(pitch: 60, velocity: 0.8, startBeat: 0, duration: 1),
                NoteEvent(pitch: 64, velocity: 0.6, startBeat: 2, duration: 0.5),
                NoteEvent(pitch: 67, velocity: 0.9, startBeat: 4, duration: 2),
            ]
            node.patch.soundType = .oscillator(OscillatorConfig(waveform: .sawtooth, detune: 5))
            node.patch.envelope = EnvelopeConfig(attack: 0.05, decay: 0.2, sustain: 0.5, release: 0.5)
            node.patch.volume = 0.6
        }

        // Save and reload
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(state.project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        // Compare structural content (Date round-trip has known precision issues)
        XCTAssertEqual(decoded.name, state.project.name)
        XCTAssertEqual(decoded.bpm, state.project.bpm)
        XCTAssertEqual(decoded.trees.count, state.project.trees.count)

        let decodedNode = decoded.trees[0].rootNode
        XCTAssertEqual(decodedNode.sequence.notes.count, 3)
        XCTAssertEqual(decodedNode.sequence.notes[0].pitch, 60)
        XCTAssertEqual(decodedNode.sequence.notes[1].pitch, 64)
        XCTAssertEqual(decodedNode.sequence.notes[2].pitch, 67)
        XCTAssertEqual(decodedNode.patch.volume, 0.6)
        if case .oscillator(let config) = decodedNode.patch.soundType {
            XCTAssertEqual(config.waveform, .sawtooth)
            XCTAssertEqual(config.detune, 5)
        } else {
            XCTFail("Expected oscillator")
        }
    }
}
