import Foundation

/// Pre-built arp note pool for the audio thread.
/// Built on the main thread from NoteSequence data, then sent via ring buffer.
struct ArpNotePool {
    var pitches: [Int]
    var velocities: [Double]
    var startBeats: [Double]
    var endBeats: [Double]
    var count: Int

    /// Maximum pool size (matches Sequencer.maxEvents for pre-allocation).
    static let maxSize = 128

    /// Build an arp pool from a NoteSequence and ArpConfig.
    ///
    /// 1. Keep every NoteEvent as a separate pool entry with its timing
    /// 2. Sort by mode
    /// 3. Expand across octave range (expanded notes inherit base note's timing)
    /// 4. For upDown/downUp: append reverse minus peaks (ping-pong)
    static func build(from sequence: NoteSequence, config: ArpConfig) -> ArpNotePool {
        guard !sequence.notes.isEmpty else {
            return ArpNotePool(pitches: [], velocities: [], startBeats: [], endBeats: [], count: 0)
        }

        // 1. Collect all notes — no de-duplication. Each NoteEvent is a separate entry.
        struct PoolEntry {
            let pitch: Int
            let velocity: Double
            let startBeat: Double
            let endBeat: Double
        }

        var entries: [PoolEntry] = []
        entries.reserveCapacity(sequence.notes.count)
        for note in sequence.notes {
            entries.append(PoolEntry(
                pitch: note.pitch,
                velocity: note.velocity,
                startBeat: note.startBeat,
                endBeat: note.startBeat + note.duration
            ))
        }

        // 2. Sort by mode
        switch config.mode {
        case .up, .upDown:
            entries.sort { $0.pitch < $1.pitch }
        case .down, .downUp:
            entries.sort { $0.pitch > $1.pitch }
        case .asPlayed:
            break // keep insertion order
        case .random:
            entries.sort { $0.pitch < $1.pitch } // order doesn't matter for random
        }

        // 3. Expand across octave range
        var expandedPitches: [Int] = []
        var expandedVelocities: [Double] = []
        var expandedStartBeats: [Double] = []
        var expandedEndBeats: [Double] = []

        for octave in 0..<config.octaveRange {
            let transpose = octave * 12
            for entry in entries {
                let expanded = entry.pitch + transpose
                guard expanded <= 127 else { continue }
                guard expandedPitches.count < ArpNotePool.maxSize else { break }
                expandedPitches.append(expanded)
                expandedVelocities.append(entry.velocity)
                expandedStartBeats.append(entry.startBeat)
                expandedEndBeats.append(entry.endBeat)
            }
        }

        // 4. For upDown/downUp: append reverse minus endpoints (ping-pong)
        if (config.mode == .upDown || config.mode == .downUp) && expandedPitches.count > 2 {
            let innerRange = 1..<(expandedPitches.count - 1)
            let reversedPitches = Array(expandedPitches[innerRange].reversed())
            let reversedVel = Array(expandedVelocities[innerRange].reversed())
            let reversedStart = Array(expandedStartBeats[innerRange].reversed())
            let reversedEnd = Array(expandedEndBeats[innerRange].reversed())
            for i in 0..<reversedPitches.count {
                guard expandedPitches.count < ArpNotePool.maxSize else { break }
                expandedPitches.append(reversedPitches[i])
                expandedVelocities.append(reversedVel[i])
                expandedStartBeats.append(reversedStart[i])
                expandedEndBeats.append(reversedEnd[i])
            }
        }

        return ArpNotePool(
            pitches: expandedPitches,
            velocities: expandedVelocities,
            startBeats: expandedStartBeats,
            endBeats: expandedEndBeats,
            count: expandedPitches.count
        )
    }

    /// Format a human-readable pool preview string.
    static func previewString(from sequence: NoteSequence, config: ArpConfig) -> String {
        let pool = build(from: sequence, config: config)
        guard pool.count > 0 else { return "Empty pool" }

        let uniqueCount = Set(sequence.notes.map { $0.pitch }).count
        let noteNames = pool.pitches.prefix(6).map { MIDIUtilities.noteName(forNote: $0) }
        var result = noteNames.joined(separator: " \u{2192} ")
        if pool.count > 6 { result += " \u{2026}" }
        result += " (\(uniqueCount) notes, \(config.octaveRange) oct)"
        return result
    }
}
