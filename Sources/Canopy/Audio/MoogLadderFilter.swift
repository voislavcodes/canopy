import Foundation

/// 24dB/oct resonant lowpass filter using the Huovilainen improved Moog ladder model.
///
/// Four cascaded one-pole sections with `tanh` nonlinearity for analog transistor
/// saturation. Runs per-sample on the audio thread — no allocations, no ARC.
///
/// Usage:
/// 1. Set `enabled`, `cutoffHz`, `resonance`, then call `updateCoefficients(sampleRate:)`.
/// 2. Call `process(_:)` for each sample in the render loop.
/// 3. Call `reset()` when restarting playback to clear state.
struct MoogLadderFilter {
    // Filter state — 4 cascaded one-pole stages
    private var stage0: Double = 0
    private var stage1: Double = 0
    private var stage2: Double = 0
    private var stage3: Double = 0

    // Delay elements (previous stage outputs for trapezoidal integration)
    private var delay0: Double = 0
    private var delay1: Double = 0
    private var delay2: Double = 0
    private var delay3: Double = 0

    // Parameters
    var enabled: Bool = false
    var cutoffHz: Double = 8000.0
    var resonance: Double = 0.0

    // Derived coefficients (updated once per command drain, not per-sample)
    private var g: Double = 0       // one-pole coefficient
    private var gComp: Double = 1.0 // gain compensation

    /// Recompute filter coefficients from current parameters.
    /// Call once when parameters change (in command drain), NOT per-sample.
    mutating func updateCoefficients(sampleRate: Double) {
        let clampedCutoff = max(20.0, min(cutoffHz, min(sampleRate * 0.45, 20000.0)))
        g = 1.0 - exp(-2.0 * .pi * clampedCutoff / sampleRate)
        gComp = 1.0 + resonance * 0.5
    }

    /// Process a single sample through the 4-pole ladder filter.
    /// Must be called on the audio thread. Zero allocations.
    mutating func process(_ input: Float) -> Float {
        guard enabled else { return input }

        let x = Double(input)

        // Feedback path: resonance * 4 * (last stage output - half input)
        // The 4.0 multiplier means self-oscillation begins around resonance ≈ 1.0
        let feedback = resonance * 4.0 * (delay3 - 0.5 * x)

        // Soft-clip input + feedback with tanh (models transistor saturation)
        let driven = tanh(x - feedback)

        // 4 cascaded one-pole lowpass stages (trapezoidal integration)
        stage0 = driven * g + delay0 * (1.0 - g)
        delay0 = stage0

        stage1 = stage0 * g + delay1 * (1.0 - g)
        delay1 = stage1

        stage2 = stage1 * g + delay2 * (1.0 - g)
        delay2 = stage2

        stage3 = stage2 * g + delay3 * (1.0 - g)
        delay3 = stage3

        // Apply gain compensation to counter resonance-induced level drop
        return Float(stage3 * gComp)
    }

    /// Process a single sample with per-sample cutoff modulation from an LFO.
    /// `cutoffMod` is in the range [-1, 1] and scales exponentially (±4 octaves at depth 1.0).
    /// Used when an LFO is routed to filter cutoff. Zero allocations.
    mutating func processWithCutoffMod(_ input: Float, cutoffMod: Double, sampleRate: Double) -> Float {
        guard enabled else { return input }

        // Exponential scaling: ±4 octaves at full depth gives perceptually even sweeps
        let modCutoff = cutoffHz * pow(2.0, cutoffMod * 4.0)
        let clamped = max(20.0, min(sampleRate * 0.45, modCutoff))
        let gMod = 1.0 - exp(-2.0 * .pi * clamped / sampleRate)

        let x = Double(input)
        let feedback = resonance * 4.0 * (delay3 - 0.5 * x)
        let driven = tanh(x - feedback)

        stage0 = driven * gMod + delay0 * (1.0 - gMod)
        delay0 = stage0
        stage1 = stage0 * gMod + delay1 * (1.0 - gMod)
        delay1 = stage1
        stage2 = stage1 * gMod + delay2 * (1.0 - gMod)
        delay2 = stage2
        stage3 = stage2 * gMod + delay3 * (1.0 - gMod)
        delay3 = stage3

        return Float(stage3 * gComp)
    }

    /// Clear all filter state. Call when restarting playback.
    mutating func reset() {
        stage0 = 0; stage1 = 0; stage2 = 0; stage3 = 0
        delay0 = 0; delay1 = 0; delay2 = 0; delay3 = 0
    }
}
