import XCTest
@testable import Canopy

final class MIDICaptureTests: XCTestCase {

    // MARK: - MIDICaptureBuffer Tests

    func testNoteOnOffProducesCorrectEvent() {
        let buffer = MIDICaptureBuffer()
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 0.0)
        buffer.noteOff(pitch: 60, atBeat: 1.0)

        XCTAssertEqual(buffer.count, 1)
        let event = buffer.events[0]
        XCTAssertEqual(event.pitch, 60)
        XCTAssertEqual(event.velocity, 0.8)
        XCTAssertEqual(event.startBeat, 0.0)
        XCTAssertEqual(event.durationBeats, 1.0, accuracy: 0.001)
    }

    func testPolyphonicTracking() {
        let buffer = MIDICaptureBuffer()
        // Two notes overlapping
        buffer.noteOn(pitch: 60, velocity: 0.7, atBeat: 0.0)
        buffer.noteOn(pitch: 64, velocity: 0.9, atBeat: 0.5)
        buffer.noteOff(pitch: 60, atBeat: 1.0)
        buffer.noteOff(pitch: 64, atBeat: 1.5)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.events[0].pitch, 60)
        XCTAssertEqual(buffer.events[0].durationBeats, 1.0, accuracy: 0.001)
        XCTAssertEqual(buffer.events[1].pitch, 64)
        XCTAssertEqual(buffer.events[1].durationBeats, 1.0, accuracy: 0.001)
    }

    func testNoteOffWithoutNoteOnIsIgnored() {
        let buffer = MIDICaptureBuffer()
        buffer.noteOff(pitch: 60, atBeat: 1.0)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPruningRemovesOldEvents() {
        let buffer = MIDICaptureBuffer()
        // Add an old note
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 0.0)
        buffer.noteOff(pitch: 60, atBeat: 1.0)

        // Add a much newer note (> 128 beats later) to trigger pruning
        buffer.noteOn(pitch: 64, velocity: 0.8, atBeat: 200.0)
        buffer.noteOff(pitch: 64, atBeat: 201.0)

        // Old event should be pruned
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.events[0].pitch, 64)
    }

    func testClearRemovesEverything() {
        let buffer = MIDICaptureBuffer()
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 0.0)
        buffer.noteOff(pitch: 60, atBeat: 1.0)
        XCTAssertFalse(buffer.isEmpty)

        buffer.clear()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.count, 0)
    }

    // MARK: - PhraseDetector / SpanLength Tests

    func testSpanLengthCoversAllNotes() {
        let buffer = MIDICaptureBuffer()
        // 6 notes spanning 3 beats
        for i in 0..<6 {
            let beat = Double(i) * 0.5
            buffer.noteOn(pitch: 60 + i, velocity: 0.8, atBeat: beat)
            buffer.noteOff(pitch: 60 + i, atBeat: beat + 0.25)
        }
        // Span: 0.0 to 2.75 → ceil(2.75 / 0.25) = 11 steps → 2.75 beats
        let length = PhraseDetector.spanLength(from: buffer, maxBeats: 8.0)
        XCTAssertEqual(length, 2.75, accuracy: 0.001)
    }

    func testSpanLengthCapsAt32Steps() {
        let buffer = MIDICaptureBuffer()
        // Notes spanning 12 beats — should cap at 8 (32 steps)
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 0.0)
        buffer.noteOff(pitch: 60, atBeat: 1.0)
        buffer.noteOn(pitch: 64, velocity: 0.8, atBeat: 11.0)
        buffer.noteOff(pitch: 64, atBeat: 12.0)

        let length = PhraseDetector.spanLength(from: buffer, maxBeats: 8.0)
        XCTAssertEqual(length, 8.0, accuracy: 0.001)
    }

    func testSpanLengthEmptyBuffer() {
        let buffer = MIDICaptureBuffer()
        let length = PhraseDetector.spanLength(from: buffer, maxBeats: 8.0)
        XCTAssertEqual(length, 0)
    }

    func testSpanLengthSingleShortNote() {
        let buffer = MIDICaptureBuffer()
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 5.0)
        buffer.noteOff(pitch: 60, atBeat: 5.1)
        // Span ~0.1 → ceil(0.1 / 0.25) = 1 step → 0.25 beats
        let length = PhraseDetector.spanLength(from: buffer, maxBeats: 8.0)
        XCTAssertEqual(length, 0.25, accuracy: 0.001)
    }

    func testRecentWindowExtraction() {
        let buffer = MIDICaptureBuffer()
        // 4 notes in the last 4 beats
        for i in 0..<4 {
            let beat = Double(i)
            buffer.noteOn(pitch: 60 + i, velocity: 0.8, atBeat: beat)
            buffer.noteOff(pitch: 60 + i, atBeat: beat + 0.5)
        }

        let phrase = PhraseDetector.extractPhrase(from: buffer, lengthInBeats: 4.0)
        XCTAssertEqual(phrase.count, 4)
        // All starts should be normalized to 0..<4
        for event in phrase {
            XCTAssertGreaterThanOrEqual(event.startBeat, 0)
            XCTAssertLessThan(event.startBeat, 4.0)
        }
    }

    func testDensestFallback() {
        let buffer = MIDICaptureBuffer()
        // Dense cluster at beats 10-14 (within 4x lookback from beat 20)
        for i in 0..<8 {
            let beat = 10.0 + Double(i) * 0.5
            buffer.noteOn(pitch: 60 + i, velocity: 0.8, atBeat: beat)
            buffer.noteOff(pitch: 60 + i, atBeat: beat + 0.25)
        }
        // Sparse recent area: single note at beat 20
        buffer.noteOn(pitch: 72, velocity: 0.8, atBeat: 20.0)
        buffer.noteOff(pitch: 72, atBeat: 20.5)

        let phrase = PhraseDetector.extractPhrase(from: buffer, lengthInBeats: 4.0)
        // Should find the dense window, not just the single recent note
        XCTAssertGreaterThan(phrase.count, 1)
    }

    func testEmptyBufferReturnsEmpty() {
        let buffer = MIDICaptureBuffer()
        let phrase = PhraseDetector.extractPhrase(from: buffer, lengthInBeats: 4.0)
        XCTAssertTrue(phrase.isEmpty)
    }

    func testNormalizationClampsToLoopLength() {
        let buffer = MIDICaptureBuffer()
        // Note that starts near end of the window
        buffer.noteOn(pitch: 60, velocity: 0.8, atBeat: 3.5)
        buffer.noteOff(pitch: 60, atBeat: 5.0) // duration 1.5, but only 0.5 left in loop
        // Add second note so recent window has >= 2
        buffer.noteOn(pitch: 64, velocity: 0.8, atBeat: 1.0)
        buffer.noteOff(pitch: 64, atBeat: 1.5)

        let phrase = PhraseDetector.extractPhrase(from: buffer, lengthInBeats: 4.0)
        for event in phrase {
            XCTAssertLessThanOrEqual(event.startBeat + event.durationBeats, 4.0 + 0.001)
        }
    }

    // MARK: - CaptureQuantizer Tests

    func testStrengthZeroKeepsRawTiming() {
        let key = MusicalKey(root: .C, mode: .chromatic) // chromatic = all notes in scale
        let events = [
            MIDIBufferEvent(pitch: 60, velocity: 0.8, startBeat: 0.13, durationBeats: 0.37)
        ]

        let result = CaptureQuantizer.quantize(events: events, strength: 0.0, key: key, lengthInBeats: 4.0)
        XCTAssertEqual(result.count, 1)
        // With strength 0, start should stay at raw position
        XCTAssertEqual(result[0].startBeat, 0.13, accuracy: 0.001)
    }

    func testStrengthOneSnapsToGrid() {
        let key = MusicalKey(root: .C, mode: .chromatic)
        let events = [
            MIDIBufferEvent(pitch: 60, velocity: 0.8, startBeat: 0.13, durationBeats: 0.37)
        ]

        let result = CaptureQuantizer.quantize(events: events, strength: 1.0, key: key, lengthInBeats: 4.0)
        XCTAssertEqual(result.count, 1)
        // With strength 1.0, 0.13 should snap to nearest 0.25 grid = 0.25
        XCTAssertEqual(result[0].startBeat, 0.25, accuracy: 0.001)
    }

    func testStrengthHalfInterpolates() {
        let key = MusicalKey(root: .C, mode: .chromatic)
        let events = [
            MIDIBufferEvent(pitch: 60, velocity: 0.8, startBeat: 0.13, durationBeats: 0.5)
        ]

        let result = CaptureQuantizer.quantize(events: events, strength: 0.5, key: key, lengthInBeats: 4.0)
        XCTAssertEqual(result.count, 1)
        // Nearest grid = 0.25, interpolated = 0.13 + (0.25 - 0.13) * 0.5 = 0.19
        XCTAssertEqual(result[0].startBeat, 0.19, accuracy: 0.001)
    }

    func testPitchScaleLock() {
        let key = MusicalKey(root: .C, mode: .major) // C major: C D E F G A B
        let events = [
            // C# (61) is not in C major — should snap to C (60) or D (62)
            MIDIBufferEvent(pitch: 61, velocity: 0.8, startBeat: 0.0, durationBeats: 0.5)
        ]

        let result = CaptureQuantizer.quantize(events: events, strength: 1.0, key: key, lengthInBeats: 4.0)
        XCTAssertEqual(result.count, 1)
        let quantizedPitch = result[0].pitch
        // Should be snapped to nearest scale tone
        XCTAssertTrue(quantizedPitch == 60 || quantizedPitch == 62,
                      "Pitch \(quantizedPitch) should be snapped to C(60) or D(62)")
    }

    func testDeduplication() {
        let key = MusicalKey(root: .C, mode: .chromatic)
        let events = [
            // Two notes at roughly the same grid step (both round to step 0)
            MIDIBufferEvent(pitch: 60, velocity: 0.5, startBeat: 0.1, durationBeats: 0.25),
            MIDIBufferEvent(pitch: 60, velocity: 0.9, startBeat: 0.12, durationBeats: 0.25)
        ]

        let result = CaptureQuantizer.quantize(events: events, strength: 1.0, key: key, lengthInBeats: 4.0)
        // Should be deduplicated to one note, keeping highest velocity
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].velocity, 0.9)
    }
}
