import Foundation

/// An entry in the effect chain: slot + wet/dry + bypass state.
struct EffectSlotEntry {
    var slot: EffectSlot
    var wetDry: Float    // 0.0 = fully dry, 1.0 = fully wet
    var bypassed: Bool
}

/// Fixed-capacity effect chain for audio-thread processing.
///
/// Max 8 effects per chain. Iterates slots in order, applies wet/dry per effect,
/// skips bypassed slots. Empty chain = zero cost (early return).
///
/// The chain is built on the main thread and the struct is assigned
/// to the audio thread's captured pointer. Since EffectChain is a value type
/// composed of value types (except for the UnsafeMutablePointer buffers inside
/// individual effects which are stable across copies), simple assignment is safe.
struct EffectChain {
    /// Maximum number of effects in a chain.
    static let maxSlots = 8

    /// Effect slots (fixed-size storage).
    private var slots: [EffectSlotEntry] = []

    /// Number of active slots.
    var count: Int { slots.count }

    /// Whether the chain is empty.
    var isEmpty: Bool { slots.isEmpty }

    /// Process a single sample through the entire chain.
    /// Empty chain returns the input unchanged (zero overhead).
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        guard !slots.isEmpty else { return sample }

        var current = sample
        for i in 0..<slots.count {
            guard !slots[i].bypassed else { continue }

            let dry = current
            let wet = slots[i].slot.process(sample: current, sampleRate: sampleRate)
            let mix = slots[i].wetDry
            current = dry * (1.0 - mix) + wet * mix
        }
        return current
    }

    /// Process a stereo pair through the entire chain.
    /// Stereo-aware effects (Ghost) use true stereo; others process L/R independently.
    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        guard !slots.isEmpty else { return (sampleL, sampleR) }

        var currentL = sampleL
        var currentR = sampleR
        for i in 0..<slots.count {
            guard !slots[i].bypassed else { continue }

            let dryL = currentL
            let dryR = currentR
            let (wetL, wetR) = slots[i].slot.processStereo(
                sampleL: currentL, sampleR: currentR, sampleRate: sampleRate
            )
            let mix = slots[i].wetDry
            currentL = dryL * (1.0 - mix) + wetL * mix
            currentR = dryR * (1.0 - mix) + wetR * mix
        }
        return (currentL, currentR)
    }

    /// Build a chain from an array of Effect model objects.
    static func build(from effects: [Effect]) -> EffectChain {
        var chain = EffectChain()
        for effect in effects.prefix(maxSlots) {
            let slot = EffectSlot.create(type: effect.type, parameters: effect.parameters)
            chain.slots.append(EffectSlotEntry(
                slot: slot,
                wetDry: Float(effect.wetDry),
                bypassed: effect.bypassed
            ))
        }
        return chain
    }

    /// Update parameters for a specific slot index.
    mutating func updateSlot(at index: Int, parameters: [String: Double], wetDry: Float, bypassed: Bool) {
        guard index < slots.count else { return }
        slots[index].slot.updateParameters(parameters)
        slots[index].wetDry = wetDry
        slots[index].bypassed = bypassed
    }

    /// Propagate BPM to all effect slots (for tempo-synced effects like DRIFT).
    mutating func updateBPM(_ bpm: Double) {
        for i in 0..<slots.count {
            slots[i].slot.updateParameters(["_bpm": bpm])
        }
    }

    /// Reset all effect states.
    mutating func reset() {
        for i in 0..<slots.count {
            slots[i].slot.reset()
        }
    }
}
