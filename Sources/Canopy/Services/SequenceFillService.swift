import Foundation

/// Generates note patterns for sequences. Main-thread only — writes to model data.
enum SequenceFillService {
    /// Assign random scale-quantized pitches to all active steps in a sequence.
    static func randomScaleFill(sequence: inout NoteSequence, key: MusicalKey, pitchRange: PitchRange?) {
        let range = pitchRange ?? PitchRange()
        let scaleNotes = key.notesInRange(low: range.low, high: range.high)
        guard !scaleNotes.isEmpty else { return }

        for i in 0..<sequence.notes.count {
            sequence.notes[i].pitch = scaleNotes[Int.random(in: 0..<scaleNotes.count)]
        }
    }

    /// Generate a Euclidean rhythm and optionally fill with scale pitches.
    static func applyEuclidean(
        sequence: inout NoteSequence,
        config: EuclideanConfig,
        key: MusicalKey,
        pitchRange: PitchRange?
    ) {
        let steps = Int(sequence.lengthInBeats)
        let pattern = EuclideanRhythm.generate(steps: steps, pulses: config.pulses, rotation: config.rotation)

        let range = pitchRange ?? PitchRange()
        let scaleNotes = key.notesInRange(low: range.low, high: range.high)

        // Remove existing notes and rebuild from pattern
        sequence.notes.removeAll()

        for (step, isActive) in pattern.enumerated() where isActive {
            let pitch = scaleNotes.isEmpty ? 60 : scaleNotes[Int.random(in: 0..<scaleNotes.count)]
            sequence.notes.append(NoteEvent(
                pitch: pitch,
                velocity: 0.8,
                startBeat: Double(step),
                duration: 1.0
            ))
        }

        sequence.euclidean = config
    }

    /// Fill empty steps with random scale notes at a given density (0-1).
    static func randomFill(
        sequence: inout NoteSequence,
        key: MusicalKey,
        pitchRange: PitchRange?,
        density: Double = 0.5
    ) {
        let steps = Int(sequence.lengthInBeats)
        let range = pitchRange ?? PitchRange()
        let scaleNotes = key.notesInRange(low: range.low, high: range.high)
        guard !scaleNotes.isEmpty else { return }

        // Find steps that already have notes
        let occupiedSteps = Set(sequence.notes.map { Int(round($0.startBeat)) })

        for step in 0..<steps {
            guard !occupiedSteps.contains(step) else { continue }
            if Double.random(in: 0...1) < density {
                sequence.notes.append(NoteEvent(
                    pitch: scaleNotes[Int.random(in: 0..<scaleNotes.count)],
                    velocity: 0.8,
                    startBeat: Double(step),
                    duration: 1.0
                ))
            }
        }
    }
}
