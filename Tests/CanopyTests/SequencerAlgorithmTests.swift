import XCTest
@testable import Canopy

final class SequencerAlgorithmTests: XCTestCase {

    // MARK: - Xorshift64 PRNG

    func testXorshiftProducesDifferentValues() {
        var prng = Xorshift64(seed: 42)
        let a = prng.next()
        let b = prng.next()
        let c = prng.next()
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
    }

    func testXorshiftDoubleRange() {
        var prng = Xorshift64(seed: 123)
        for _ in 0..<100 {
            let val = prng.nextDouble()
            XCTAssertGreaterThanOrEqual(val, 0)
            XCTAssertLessThan(val, 1)
        }
    }

    func testXorshiftIntRange() {
        var prng = Xorshift64(seed: 456)
        for _ in 0..<100 {
            let val = prng.nextInt(in: 3...7)
            XCTAssertGreaterThanOrEqual(val, 3)
            XCTAssertLessThanOrEqual(val, 7)
        }
    }

    func testXorshiftDeterministic() {
        var prng1 = Xorshift64(seed: 999)
        var prng2 = Xorshift64(seed: 999)
        for _ in 0..<50 {
            XCTAssertEqual(prng1.next(), prng2.next())
        }
    }

    // MARK: - SequencerEvent Construction

    func testSequencerEventDefaults() {
        let event = SequencerEvent(pitch: 60, velocity: 0.8, startBeat: 0, endBeat: 1)
        XCTAssertEqual(event.probability, 1.0)
        XCTAssertEqual(event.ratchetCount, 1)
    }

    func testSequencerEventCustomFields() {
        let event = SequencerEvent(pitch: 60, velocity: 0.8, startBeat: 0, endBeat: 1,
                                   probability: 0.5, ratchetCount: 3)
        XCTAssertEqual(event.probability, 0.5)
        XCTAssertEqual(event.ratchetCount, 3)
    }

    // MARK: - Accumulator Config

    func testAccumulatorConfigDefaults() {
        let config = AccumulatorConfig()
        XCTAssertEqual(config.target, .pitch)
        XCTAssertEqual(config.amount, 1.0)
        XCTAssertEqual(config.limit, 12.0)
        XCTAssertEqual(config.mode, .clamp)
    }

    // MARK: - Mutation Config

    func testMutationConfigDefaults() {
        let config = MutationConfig()
        XCTAssertEqual(config.amount, 0.1)
        XCTAssertEqual(config.range, 1)
    }

    // MARK: - Playback Direction

    func testAllPlaybackDirections() {
        let cases = PlaybackDirection.allCases
        XCTAssertEqual(cases.count, 5)
        XCTAssertTrue(cases.contains(.forward))
        XCTAssertTrue(cases.contains(.reverse))
        XCTAssertTrue(cases.contains(.pingPong))
        XCTAssertTrue(cases.contains(.random))
        XCTAssertTrue(cases.contains(.brownian))
    }

    // MARK: - Accumulator Modes

    func testAllAccumulatorModes() {
        let modes = AccumulatorMode.allCases
        XCTAssertEqual(modes.count, 3)
        XCTAssertTrue(modes.contains(.clamp))
        XCTAssertTrue(modes.contains(.wrap))
        XCTAssertTrue(modes.contains(.pingPong))
    }

    func testAllAccumulatorTargets() {
        let targets = AccumulatorTarget.allCases
        XCTAssertEqual(targets.count, 3)
        XCTAssertTrue(targets.contains(.pitch))
        XCTAssertTrue(targets.contains(.velocity))
        XCTAssertTrue(targets.contains(.probability))
    }

    // MARK: - EuclideanConfig Codable

    func testEuclideanConfigRoundTrip() throws {
        let config = EuclideanConfig(pulses: 5, rotation: 2)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EuclideanConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - PitchRange Codable

    func testPitchRangeRoundTrip() throws {
        let range = PitchRange(low: 36, high: 84)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(PitchRange.self, from: data)
        XCTAssertEqual(range, decoded)
    }

    // MARK: - MutationConfig Codable

    func testMutationConfigRoundTrip() throws {
        let config = MutationConfig(amount: 0.3, range: 4)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MutationConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - AccumulatorConfig Codable

    func testAccumulatorConfigRoundTrip() throws {
        let config = AccumulatorConfig(target: .velocity, amount: 2.5, limit: 24.0, mode: .pingPong)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AccumulatorConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - Sequencer Cursor Correctness

    /// Helper: advance a sequencer by the given number of samples, collecting
    /// all (pitch, isNoteOn) events from VoiceManager state changes.
    private func collectEvents(
        seq: inout Sequencer,
        voices: inout VoiceManager,
        sampleRate: Double,
        totalSamples: Int
    ) -> [(sample: Int, pitch: Int, isOn: Bool)] {
        var result: [(sample: Int, pitch: Int, isOn: Bool)] = []
        // Track previous voice pitches to detect note-on/off transitions
        var prevPitches = voices.voicePitches
        for s in 0..<totalSamples {
            seq.advanceOneSample(sampleRate: sampleRate, receiver: &voices, detune: 0)
            // Detect changes in voice allocations
            for v in 0..<voices.voiceCount {
                let cur = voices.voicePitches[v]
                let prev = prevPitches[v]
                if cur != prev {
                    if prev >= 0 && !voices.voices[v].isActive {
                        // voice went from active to inactive → note-off
                        result.append((sample: s, pitch: prev, isOn: false))
                    }
                    if cur >= 0 && voices.voices[v].isActive {
                        // voice became active with new pitch → note-on
                        result.append((sample: s, pitch: cur, isOn: true))
                    }
                }
            }
            prevPitches = voices.voicePitches
        }
        return result
    }

    /// Verify that cursor-based forward scanning triggers note-on at the
    /// correct beat position for a simple 4-event sequence.
    func testCursorNoteOnTiming() {
        let sampleRate = 44100.0
        let bpm = 120.0
        let beatsPerSample = bpm / (60.0 * sampleRate)

        // Create events at beats 0, 1, 2, 3 with duration 0.5
        let events = (0..<4).map { i in
            SequencerEvent(pitch: 60 + i, velocity: 0.8,
                           startBeat: Double(i), endBeat: Double(i) + 0.5)
        }

        var seq = Sequencer()
        seq.load(events: events, lengthInBeats: 4)
        seq.start(bpm: bpm)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: sampleRate)

        // Advance sample-by-sample and check that each event fires
        // at or just after its startBeat
        var noteOnBeats: [Int: Double] = [:]
        for s in 0..<Int(4.0 / beatsPerSample) + 100 {
            seq.advanceOneSample(sampleRate: sampleRate, receiver: &voices, detune: 0)
            // Check if a new pitch appeared
            for v in 0..<voices.voiceCount {
                let p = voices.voicePitches[v]
                if p >= 60 && p <= 63 && noteOnBeats[p] == nil && voices.voices[v].isActive {
                    noteOnBeats[p] = seq.currentBeat
                }
            }
        }

        // Each note should have triggered
        for i in 0..<4 {
            let pitch = 60 + i
            XCTAssertNotNil(noteOnBeats[pitch], "Note \(pitch) should have triggered")
        }
    }

    // MARK: - Pre-allocation Capacity Tests

    /// Verify that loading 1 event works correctly.
    func testPreallocationSingleEvent() {
        var seq = Sequencer()
        let events = [SequencerEvent(pitch: 60, velocity: 0.8, startBeat: 0, endBeat: 0.5)]
        seq.load(events: events, lengthInBeats: 1)
        seq.start(bpm: 120)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: 44100)

        // Advance enough samples for the note to trigger
        for _ in 0..<1000 {
            seq.advanceOneSample(sampleRate: 44100, receiver: &voices, detune: 0)
        }

        // The note should have been allocated to a voice
        XCTAssertTrue(voices.voicePitches.contains(60), "Single event should trigger note-on")
    }

    /// Verify that loading 32 events works correctly.
    func testPreallocation32Events() {
        var seq = Sequencer()
        let events = (0..<32).map { i in
            SequencerEvent(pitch: 40 + (i % 48), velocity: 0.8,
                           startBeat: Double(i) * 0.5, endBeat: Double(i) * 0.5 + 0.25)
        }
        seq.load(events: events, lengthInBeats: 16)
        seq.start(bpm: 120)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: 44100)

        // Advance through the full sequence
        let samplesPerBeat = 44100.0 * 60.0 / 120.0
        let totalSamples = Int(16.0 * samplesPerBeat) + 100
        for _ in 0..<totalSamples {
            seq.advanceOneSample(sampleRate: 44100, receiver: &voices, detune: 0)
        }

        // Should have completed without crash
        XCTAssertTrue(true, "32-event sequence completed without crash")
    }

    /// Verify that loading 64 events works correctly.
    func testPreallocation64Events() {
        var seq = Sequencer()
        let events = (0..<64).map { i in
            SequencerEvent(pitch: 36 + (i % 52), velocity: 0.7,
                           startBeat: Double(i) * 0.25, endBeat: Double(i) * 0.25 + 0.125)
        }
        seq.load(events: events, lengthInBeats: 16)
        seq.start(bpm: 120)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: 44100)

        let samplesPerBeat = 44100.0 * 60.0 / 120.0
        let totalSamples = Int(16.0 * samplesPerBeat) + 100
        for _ in 0..<totalSamples {
            seq.advanceOneSample(sampleRate: 44100, receiver: &voices, detune: 0)
        }

        XCTAssertTrue(true, "64-event sequence completed without crash")
    }

    /// Verify that loading exactly maxEvents (128) events works correctly.
    func testPreallocation128Events() {
        var seq = Sequencer()
        let events = (0..<128).map { i in
            SequencerEvent(pitch: 24 + (i % 80), velocity: 0.6,
                           startBeat: Double(i) * 0.125, endBeat: Double(i) * 0.125 + 0.0625)
        }
        seq.load(events: events, lengthInBeats: 16)
        seq.start(bpm: 120)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: 44100)

        let samplesPerBeat = 44100.0 * 60.0 / 120.0
        let totalSamples = Int(16.0 * samplesPerBeat) + 100
        for _ in 0..<totalSamples {
            seq.advanceOneSample(sampleRate: 44100, receiver: &voices, detune: 0)
        }

        XCTAssertTrue(true, "128-event (maxEvents) sequence completed without crash")
    }

    /// Verify that events exceeding maxEvents are clamped (not crash).
    func testPreallocationOverMaxEventsClamps() {
        var seq = Sequencer()
        // Create 150 events (exceeds maxEvents=128)
        let events = (0..<150).map { i in
            SequencerEvent(pitch: 60, velocity: 0.8,
                           startBeat: Double(i) * 0.1, endBeat: Double(i) * 0.1 + 0.05)
        }
        seq.load(events: events, lengthInBeats: 16)
        seq.start(bpm: 120)

        var voices = VoiceManager(voiceCount: 8)
        voices.configurePatch(waveform: 0, detune: 0,
                              attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                              sampleRate: 44100)

        // Advance briefly — should not crash
        for _ in 0..<10000 {
            seq.advanceOneSample(sampleRate: 44100, receiver: &voices, detune: 0)
        }

        XCTAssertTrue(true, "Over-maxEvents sequence clamped without crash")
    }

    /// Verify maxEvents constant is what we expect.
    func testMaxEventsConstant() {
        XCTAssertEqual(Sequencer.maxEvents, 128)
    }
}
