import Foundation

/// Pre-built arp note pool for the audio thread.
/// Built on the main thread from NoteSequence data, then sent via ring buffer.
struct ArpNotePool {
    var pitches: [Int]
    var velocities: [Double]
    var count: Int

    /// Maximum pool size (matches Sequencer.maxEvents for pre-allocation).
    static let maxSize = 128

    /// Build an arp pool from a NoteSequence and ArpConfig.
    ///
    /// 1. Collect unique pitches (highest velocity wins on duplicates)
    /// 2. Sort by mode
    /// 3. Expand across octave range
    /// 4. For upDown/downUp: append reverse minus peaks (ping-pong)
    static func build(from sequence: NoteSequence, config: ArpConfig) -> ArpNotePool {
        guard !sequence.notes.isEmpty else {
            return ArpNotePool(pitches: [], velocities: [], count: 0)
        }

        // 1. Collect unique pitches — highest velocity wins
        var pitchVelocity: [Int: Double] = [:]
        var appearanceOrder: [Int] = []
        for note in sequence.notes {
            if let existing = pitchVelocity[note.pitch] {
                if note.velocity > existing {
                    pitchVelocity[note.pitch] = note.velocity
                }
            } else {
                pitchVelocity[note.pitch] = note.velocity
                appearanceOrder.append(note.pitch)
            }
        }

        // 2. Sort by mode
        var basePitches: [Int]
        switch config.mode {
        case .up, .upDown:
            basePitches = pitchVelocity.keys.sorted()
        case .down, .downUp:
            basePitches = pitchVelocity.keys.sorted(by: >)
        case .asPlayed:
            basePitches = appearanceOrder
        case .random:
            basePitches = pitchVelocity.keys.sorted() // order doesn't matter for random
        }

        // 3. Expand across octave range
        var expandedPitches: [Int] = []
        var expandedVelocities: [Double] = []

        for octave in 0..<config.octaveRange {
            let transpose = octave * 12
            for pitch in basePitches {
                let expanded = pitch + transpose
                guard expanded <= 127 else { continue }
                guard expandedPitches.count < ArpNotePool.maxSize else { break }
                expandedPitches.append(expanded)
                expandedVelocities.append(pitchVelocity[pitch] ?? 0.8)
            }
        }

        // 4. For upDown/downUp: append reverse minus endpoints (ping-pong)
        if (config.mode == .upDown || config.mode == .downUp) && expandedPitches.count > 2 {
            let reversed = Array(expandedPitches[1..<(expandedPitches.count - 1)].reversed())
            let reversedVel = Array(expandedVelocities[1..<(expandedVelocities.count - 1)].reversed())
            for i in 0..<reversed.count {
                guard expandedPitches.count < ArpNotePool.maxSize else { break }
                expandedPitches.append(reversed[i])
                expandedVelocities.append(reversedVel[i])
            }
        }

        return ArpNotePool(
            pitches: expandedPitches,
            velocities: expandedVelocities,
            count: expandedPitches.count
        )
    }

    /// Format a human-readable pool preview string.
    static func previewString(from sequence: NoteSequence, config: ArpConfig) -> String {
        let pool = build(from: sequence, config: config)
        guard pool.count > 0 else { return "Empty pool" }

        let uniqueCount = Set(sequence.notes.map { $0.pitch }).count
        let noteNames = pool.pitches.prefix(6).map { MIDIUtilities.noteName(forNote: $0) }
        var result = noteNames.joined(separator: " → ")
        if pool.count > 6 { result += " …" }
        result += " (\(uniqueCount) notes, \(config.octaveRange) oct)"
        return result
    }
}
