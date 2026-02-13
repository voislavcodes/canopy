import Foundation

extension MusicalKey {
    /// All MIDI note numbers in this scale within the given range (inclusive).
    func notesInRange(low: Int, high: Int) -> [Int] {
        let rootSemitone = root.semitone
        let intervals = mode.intervals
        var result: [Int] = []

        for midi in low...high {
            let pc = ((midi % 12) - rootSemitone + 12) % 12
            if intervals.contains(pc) {
                result.append(midi)
            }
        }
        return result
    }

    /// Snap a MIDI note to the nearest scale tone.
    func quantize(_ midiNote: Int) -> Int {
        let rootSemitone = root.semitone
        let intervals = mode.intervals
        let pc = ((midiNote % 12) - rootSemitone + 12) % 12

        if intervals.contains(pc) { return midiNote }

        var bestOffset = 12
        for interval in intervals {
            let diff = interval - pc
            // Check both directions (up and down)
            for candidate in [diff, diff + 12, diff - 12] {
                if abs(candidate) < abs(bestOffset) {
                    bestOffset = candidate
                }
            }
        }
        let result = midiNote + bestOffset
        return max(0, min(127, result))
    }

    /// The scale degree (0-based) of a MIDI note, or nil if not in scale.
    func degree(of midiNote: Int) -> Int? {
        let rootSemitone = root.semitone
        let pc = ((midiNote % 12) - rootSemitone + 12) % 12
        return mode.intervals.firstIndex(of: pc)
    }

    /// Shift a MIDI note by the given number of scale degrees.
    /// Positive = up, negative = down. Returns clamped 0-127.
    func shiftByDegrees(_ midiNote: Int, degrees: Int) -> Int {
        let rootSemitone = root.semitone
        let intervals = mode.intervals
        let octave = midiNote / 12
        let pc = ((midiNote % 12) - rootSemitone + 12) % 12

        // Find the nearest scale degree
        guard let currentDegree = intervals.firstIndex(of: pc) else {
            // Not in scale — quantize first, then shift
            let quantized = quantize(midiNote)
            return shiftByDegrees(quantized, degrees: degrees)
        }

        let scaleSize = intervals.count
        let targetDegree = currentDegree + degrees
        let octaveShift = targetDegree >= 0
            ? targetDegree / scaleSize
            : (targetDegree - scaleSize + 1) / scaleSize
        let degreeInScale = ((targetDegree % scaleSize) + scaleSize) % scaleSize

        let resultNote = (octave + octaveShift) * 12 + rootSemitone + intervals[degreeInScale]
        return max(0, min(127, resultNote))
    }
}
