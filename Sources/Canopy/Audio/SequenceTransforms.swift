import Foundation

/// Pure-data transform pipeline for sequence events.
/// Applies all GENERATE / TRANSFORM / PLAY transforms stored on a NoteSequence.
/// Used by both the audio engine (tree loading) and the UI (sequencer display).
enum SequenceTransforms {

    /// Build raw SequencerEvents from a NoteSequence's notes, then apply all
    /// configured transforms (octave, fifth, invert, bloom, density, mirror, gate, swing).
    static func transformedEvents(from seq: NoteSequence, key: MusicalKey, stepRate: StepRate = .sixteenth) -> [SequencerEvent] {
        // Start with raw note events
        var events = seq.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration,
                probability: event.probability,
                ratchetCount: event.ratchetCount
            )
        }

        // --- GENERATE transforms ---

        // OCTAVE OFFSET: shift all pitches by octaves
        if let octOff = seq.octaveOffset, octOff != 0 {
            let semitoneShift = octOff * 12
            events = events.map { e in
                SequencerEvent(pitch: max(0, min(127, e.pitch + semitoneShift)), velocity: e.velocity,
                               startBeat: e.startBeat, endBeat: e.endBeat,
                               probability: e.probability, ratchetCount: e.ratchetCount)
            }
        }

        // FIFTH: scale-aware transposition
        if let fifthRot = seq.fifthRotation, fifthRot != 0 {
            events = applyFifthTranspose(events, rotation: fifthRot, key: key)
        }

        // --- TRANSFORM transforms ---

        // INVERT: mirror pitches around pivot
        if seq.invertEnabled ?? false {
            let pivot = seq.invertPivot ?? (key.root.semitone + 60)
            events = applyInvert(events, pivot: pivot, key: key)
        }

        // BLOOM: extend note durations
        if let bloom = seq.bloomAmount, bloom > 0 {
            events = applyBloom(events, amount: bloom, lengthInBeats: seq.lengthInBeats, stepRate: stepRate)
        }

        // DENSITY: deterministically remove notes
        if let density = seq.density, density < 1.0 {
            events = applyDensity(events, density: density)
        }

        // MIRROR: reverse note positions
        if seq.mirrorEnabled ?? false {
            events = applyMirror(events, lengthInBeats: seq.lengthInBeats)
        }

        // --- PLAY transforms ---

        // GATE: scale note durations
        if let gate = seq.gateLength, gate < 1.0 {
            events = applyGate(events, gateLength: gate, stepRate: stepRate)
        }

        // SWING: offset odd steps
        if let swing = seq.swing, swing > 0 {
            events = applySwing(events, swing: swing, stepRate: stepRate)
        }

        return events
    }

    // MARK: - Individual Transforms

    static func applyFifthTranspose(_ events: [SequencerEvent], rotation: Int, key: MusicalKey) -> [SequencerEvent] {
        let sourceRoot = key.root.semitone
        let targetRoot = ((sourceRoot + rotation * 7) % 12 + 12) % 12
        let semitoneShift = ((targetRoot - sourceRoot) % 12 + 12) % 12

        return events.map { event in
            let pc = ((event.pitch % 12) - sourceRoot + 12) % 12
            let intervals = key.mode.intervals
            if let degreeIdx = intervals.firstIndex(of: pc) {
                let octave = event.pitch / 12
                let newPitch = octave * 12 + targetRoot + intervals[degreeIdx]
                let clampedPitch = max(0, min(127, newPitch))
                return SequencerEvent(pitch: clampedPitch, velocity: event.velocity,
                                      startBeat: event.startBeat, endBeat: event.endBeat,
                                      probability: event.probability, ratchetCount: event.ratchetCount)
            } else {
                let newPitch = max(0, min(127, event.pitch + semitoneShift))
                return SequencerEvent(pitch: newPitch, velocity: event.velocity,
                                      startBeat: event.startBeat, endBeat: event.endBeat,
                                      probability: event.probability, ratchetCount: event.ratchetCount)
            }
        }
    }

    static func applyInvert(_ events: [SequencerEvent], pivot: Int, key: MusicalKey) -> [SequencerEvent] {
        return events.map { event in
            let inverted = 2 * pivot - event.pitch
            let snapped = key.quantize(max(0, min(127, inverted)))
            return SequencerEvent(pitch: snapped, velocity: event.velocity,
                                  startBeat: event.startBeat, endBeat: event.endBeat,
                                  probability: event.probability, ratchetCount: event.ratchetCount)
        }
    }

    static func applyBloom(_ events: [SequencerEvent], amount: Double, lengthInBeats: Double, stepRate: StepRate = .sixteenth) -> [SequencerEvent] {
        let sd = stepRate.beatsPerStep
        let maxExtension = sd * 8
        return events.map { event in
            let baseDuration = event.endBeat - event.startBeat
            let targetDuration = baseDuration + maxExtension * amount
            let newEnd = min(event.startBeat + targetDuration, lengthInBeats)
            return SequencerEvent(pitch: event.pitch, velocity: event.velocity,
                                  startBeat: event.startBeat, endBeat: newEnd,
                                  probability: event.probability, ratchetCount: event.ratchetCount)
        }
    }

    static func applyDensity(_ events: [SequencerEvent], density: Double) -> [SequencerEvent] {
        return events.enumerated().compactMap { idx, event in
            let hash = ((idx * 7 + 13) * 37) % 100
            let threshold = (1.0 - density) * 100
            return Double(hash) >= threshold ? event : nil
        }
    }

    static func applyMirror(_ events: [SequencerEvent], lengthInBeats: Double) -> [SequencerEvent] {
        return events.map { event in
            let duration = event.endBeat - event.startBeat
            let newStart = lengthInBeats - event.startBeat - duration
            let clampedStart = max(0, newStart)
            return SequencerEvent(pitch: event.pitch, velocity: event.velocity,
                                  startBeat: clampedStart, endBeat: clampedStart + duration,
                                  probability: event.probability, ratchetCount: event.ratchetCount)
        }
    }

    static func applyGate(_ events: [SequencerEvent], gateLength: Double, stepRate: StepRate = .sixteenth) -> [SequencerEvent] {
        let sd = stepRate.beatsPerStep
        return events.map { event in
            let duration = event.endBeat - event.startBeat
            let newDuration = max(sd * 0.1, duration * gateLength)
            return SequencerEvent(pitch: event.pitch, velocity: event.velocity,
                                  startBeat: event.startBeat, endBeat: event.startBeat + newDuration,
                                  probability: event.probability, ratchetCount: event.ratchetCount)
        }
    }

    static func applySwing(_ events: [SequencerEvent], swing: Double, stepRate: StepRate = .sixteenth) -> [SequencerEvent] {
        let sd = stepRate.beatsPerStep
        return events.map { event in
            let step = Int(round(event.startBeat / sd))
            if step % 2 == 1 {
                let offset = swing * sd
                return SequencerEvent(pitch: event.pitch, velocity: event.velocity,
                                      startBeat: event.startBeat + offset,
                                      endBeat: event.endBeat + offset,
                                      probability: event.probability, ratchetCount: event.ratchetCount)
            }
            return event
        }
    }
}
