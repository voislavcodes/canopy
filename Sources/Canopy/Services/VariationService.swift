import Foundation

/// Stateless service that applies musical variations to create new trees from existing ones.
/// All methods are pure functions — no side effects, no audio thread interaction.
enum VariationService {

    /// Apply a variation to a tree, producing a new deep-copied tree with fresh UUIDs.
    /// - Parameters:
    ///   - variation: The variation to apply.
    ///   - tree: The source tree to variate from.
    ///   - scale: The resolved musical key for scale-aware operations.
    /// - Returns: A new tree with the variation applied.
    static func apply(_ variation: VariationType, to tree: NodeTree, scale: MusicalKey) -> NodeTree {
        var newTree = NodeTree(
            name: tree.name + " " + variation.displayName.lowercased(),
            rootNode: deepCopyNode(tree.rootNode),
            scale: tree.scale,
            sourceTreeID: tree.id,
            variationType: variation,
            anchor: tree.anchor,
            colorSeedId: Int.random(in: 0..<1_000_000)
        )

        applyToNode(&newTree.rootNode, variation: variation, scale: scale)
        return newTree
    }

    /// Generate a random "surprise" variation with musically sensible parameters.
    static func surprise(tree: NodeTree, scale: MusicalKey) -> (NodeTree, VariationType) {
        let variation = randomVariation()
        let result = apply(.surprise(variations: [variation]), to: tree, scale: scale)
        return (result, .surprise(variations: [variation]))
    }

    // MARK: - Private: Recursive Application

    private static func applyToNode(_ node: inout Node, variation: VariationType, scale: MusicalKey) {
        let sd = node.stepRate.beatsPerStep
        switch variation {
        case .transpose(let semitones):
            applyTranspose(&node.sequence, semitones: semitones, scale: scale)
        case .invert(let pivot):
            applyInvert(&node.sequence, pivot: pivot, scale: scale)
        case .fifth(let targetRoot):
            applyFifth(&node.sequence, from: scale, targetRoot: targetRoot)
        case .density(let amount):
            applyDensity(&node.sequence, amount: amount, scale: scale, pitchRange: node.sequence.pitchRange, sd: sd)
        case .mirror:
            applyMirror(&node.sequence)
        case .rotate(let steps):
            applyRotate(&node.sequence, steps: steps, sd: sd)
        case .euclideanRefill(let hits, let steps, let rotation):
            applyEuclideanRefill(&node.sequence, hits: hits, steps: steps, rotation: rotation, sd: sd)
        case .bloom(let amount):
            applyBloom(&node.sequence, amount: amount)
        case .drift(let ticks):
            applyDrift(&node.sequence, ticks: ticks, sd: sd)
        case .scramble(let seed):
            applyScramble(&node.sequence, seed: seed)
        case .human(let amount):
            applyHuman(&node.sequence, amount: amount, sd: sd)
        case .mutate(let amount, let range):
            applyMutate(&node.sequence, amount: amount, range: range, scale: scale)
        case .engineSwap(let soundType):
            node.patch.soundType = soundType
        case .surprise(let variations):
            for v in variations {
                applyToNode(&node, variation: v, scale: scale)
            }
        }

        // Recurse into children
        for i in 0..<node.children.count {
            applyToNode(&node.children[i], variation: variation, scale: scale)
        }
    }

    // MARK: - Deep Copy

    private static func deepCopyNode(_ node: Node) -> Node {
        var copy = node
        copy.id = UUID()
        copy.children = node.children.map { deepCopyNode($0) }
        return copy
    }

    // MARK: - Algorithms

    /// Shift all pitches by semitones, scale-quantize.
    private static func applyTranspose(_ seq: inout NoteSequence, semitones: Int, scale: MusicalKey) {
        for i in 0..<seq.notes.count {
            let newPitch = seq.notes[i].pitch + semitones
            seq.notes[i].pitch = scale.quantize(max(0, min(127, newPitch)))
        }
    }

    /// Invert pitches around a pivot point, scale-quantize.
    private static func applyInvert(_ seq: inout NoteSequence, pivot: Int, scale: MusicalKey) {
        for i in 0..<seq.notes.count {
            let inverted = 2 * pivot - seq.notes[i].pitch
            seq.notes[i].pitch = scale.quantize(max(0, min(127, inverted)))
        }
    }

    /// Transpose from source key to target key via circle-of-fifths relationship.
    private static func applyFifth(_ seq: inout NoteSequence, from sourceKey: MusicalKey, targetRoot: PitchClass) {
        let semitoneShift = (targetRoot.semitone - sourceKey.root.semitone + 12) % 12
        let targetKey = MusicalKey(root: targetRoot, mode: sourceKey.mode)

        for i in 0..<seq.notes.count {
            let shifted = seq.notes[i].pitch + semitoneShift
            seq.notes[i].pitch = targetKey.quantize(max(0, min(127, shifted)))
        }
    }

    /// Adjust note density. Below 1.0: remove notes deterministically. Above 1.0: add scale-fill notes.
    private static func applyDensity(_ seq: inout NoteSequence, amount: Double, scale: MusicalKey, pitchRange: PitchRange?, sd: Double = 0.25) {
        guard !seq.notes.isEmpty else { return }

        if amount < 1.0 {
            // Remove notes deterministically based on index hash
            var kept: [NoteEvent] = []
            for (i, note) in seq.notes.enumerated() {
                let hash = Double((i &* 2654435761) & 0xFFFF) / 65536.0
                if hash < amount {
                    kept.append(note)
                }
            }
            // Always keep at least one note
            if kept.isEmpty, let first = seq.notes.first {
                kept.append(first)
            }
            seq.notes = kept
        } else if amount > 1.0 {
            // Add notes at empty beats
            let steps = max(1, Int(round(seq.lengthInBeats / sd)))
            let occupiedSteps = Set(seq.notes.map { Int(round($0.startBeat / sd)) })
            let range = pitchRange ?? PitchRange()
            let scaleNotes = scale.notesInRange(low: range.low, high: range.high)
            guard !scaleNotes.isEmpty else { return }

            let fillProb = min(1.0, amount - 1.0) // 1.5 → 50% fill probability
            for step in 0..<steps {
                guard !occupiedSteps.contains(step) else { continue }
                let hash = Double(((step &* 2654435761) ^ (step &* 340573321)) & 0xFFFF) / 65536.0
                if hash < fillProb {
                    seq.notes.append(NoteEvent(
                        pitch: scaleNotes[abs(step &* 7) % scaleNotes.count],
                        velocity: 0.7,
                        startBeat: Double(step) * sd,
                        duration: sd
                    ))
                }
            }
        }
    }

    /// Reverse the time positions of all notes (retrograde).
    private static func applyMirror(_ seq: inout NoteSequence) {
        let length = seq.lengthInBeats
        for i in 0..<seq.notes.count {
            let newStart = length - seq.notes[i].startBeat - seq.notes[i].duration
            seq.notes[i].startBeat = max(0, newStart)
        }
    }

    /// Rotate note start times by steps.
    private static func applyRotate(_ seq: inout NoteSequence, steps: Int, sd: Double = 0.25) {
        let length = seq.lengthInBeats
        let offset = Double(steps) * sd

        for i in 0..<seq.notes.count {
            var newStart = seq.notes[i].startBeat + offset
            // Wrap around
            newStart = newStart.truncatingRemainder(dividingBy: length)
            if newStart < 0 { newStart += length }
            seq.notes[i].startBeat = newStart
        }
    }

    /// Generate Euclidean pattern and redistribute original pitches to new hit positions.
    private static func applyEuclideanRefill(_ seq: inout NoteSequence, hits: Int, steps: Int, rotation: Int, sd: Double = 0.25) {
        let pattern = EuclideanRhythm.generate(steps: steps, pulses: hits, rotation: rotation)

        // Collect original pitches (cycle through if needed)
        let originalPitches = seq.notes.map { $0.pitch }
        guard !originalPitches.isEmpty else { return }

        var newNotes: [NoteEvent] = []
        var pitchIdx = 0
        for (step, isActive) in pattern.enumerated() where isActive {
            let pitch = originalPitches[pitchIdx % originalPitches.count]
            newNotes.append(NoteEvent(
                pitch: pitch,
                velocity: 0.8,
                startBeat: Double(step) * sd,
                duration: sd
            ))
            pitchIdx += 1
        }

        // Adjust sequence length if needed
        seq.lengthInBeats = max(seq.lengthInBeats, Double(steps) * sd)
        seq.notes = newNotes
    }

    /// Extend note durations, capping at next note's start to avoid overlap.
    private static func applyBloom(_ seq: inout NoteSequence, amount: Double) {
        guard !seq.notes.isEmpty else { return }

        // Sort by start time for overlap detection
        var sorted = seq.notes.sorted { $0.startBeat < $1.startBeat }

        for i in 0..<sorted.count {
            let extended = sorted[i].duration * (1.0 + amount)
            if i + 1 < sorted.count {
                let maxDuration = sorted[i + 1].startBeat - sorted[i].startBeat
                sorted[i].duration = min(extended, max(sorted[i].duration, maxDuration))
            } else {
                let maxDuration = seq.lengthInBeats - sorted[i].startBeat
                sorted[i].duration = min(extended, maxDuration)
            }
        }
        seq.notes = sorted
    }

    /// Shift note start times by micro-timing offset, wrapping.
    private static func applyDrift(_ seq: inout NoteSequence, ticks: Double, sd: Double = 0.25) {
        let offset = ticks * sd
        let length = seq.lengthInBeats

        for i in 0..<seq.notes.count {
            var newStart = seq.notes[i].startBeat + offset
            newStart = newStart.truncatingRemainder(dividingBy: length)
            if newStart < 0 { newStart += length }
            seq.notes[i].startBeat = newStart
        }
    }

    /// Shuffle pitches using seeded PRNG, keep rhythm intact.
    private static func applyScramble(_ seq: inout NoteSequence, seed: UInt64) {
        guard seq.notes.count > 1 else { return }

        var pitches = seq.notes.map { $0.pitch }
        var rng = SeededRNG(seed: seed)

        // Fisher-Yates shuffle
        for i in stride(from: pitches.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            pitches.swapAt(i, j)
        }

        for i in 0..<seq.notes.count {
            seq.notes[i].pitch = pitches[i]
        }
    }

    /// Add random micro-timing + velocity variation (seeded for reproducibility).
    private static func applyHuman(_ seq: inout NoteSequence, amount: Double, sd: Double = 0.25) {
        var rng = SeededRNG(seed: 42)

        for i in 0..<seq.notes.count {
            // Micro-timing: +-amount * 0.5 steps
            let timingNoise = (rng.nextDouble() * 2.0 - 1.0) * amount * 0.5 * sd
            seq.notes[i].startBeat = max(0, seq.notes[i].startBeat + timingNoise)

            // Velocity variation: +-amount * 0.3
            let velNoise = (rng.nextDouble() * 2.0 - 1.0) * amount * 0.3
            seq.notes[i].velocity = max(0.1, min(1.0, seq.notes[i].velocity + velNoise))
        }
    }

    /// Per-note probability roll to shift pitch by random scale degrees within range.
    private static func applyMutate(_ seq: inout NoteSequence, amount: Double, range: Int, scale: MusicalKey) {
        var rng = SeededRNG(seed: 77)

        for i in 0..<seq.notes.count {
            if rng.nextDouble() < amount {
                let shift = Int(rng.next() % UInt64(range * 2 + 1)) - range
                seq.notes[i].pitch = scale.shiftByDegrees(seq.notes[i].pitch, degrees: shift)
            }
        }
    }

    // MARK: - Random Variation Generator (for Surprise)

    private static func randomVariation() -> VariationType {
        let roll = Int.random(in: 0..<10)
        switch roll {
        case 0: return .transpose(semitones: [-7, -5, -3, -2, 2, 3, 5, 7].randomElement()!)
        case 1: return .invert(pivot: Int.random(in: 55...72))
        case 2: return .mirror
        case 3: return .rotate(steps: Int.random(in: -4...4))
        case 4: return .bloom(amount: Double.random(in: 0.2...0.8))
        case 5: return .drift(ticks: Double.random(in: -2...2))
        case 6: return .scramble(seed: UInt64.random(in: 1...9999))
        case 7: return .human(amount: Double.random(in: 0.2...0.6))
        case 8: return .mutate(amount: Double.random(in: 0.2...0.5), range: Int.random(in: 1...3))
        default: return .density(amount: Double.random(in: 0.5...1.5))
        }
    }
}

// MARK: - Seeded RNG (deterministic randomness for reproducible variations)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextDouble() -> Double {
        return Double(next() & 0xFFFFFFFF) / Double(UInt32.max)
    }
}
