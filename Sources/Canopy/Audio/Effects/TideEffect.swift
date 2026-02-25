import Foundation

/// Tide effect — phaser built from cascaded all-pass filters with LFO modulation.
///
/// Parameters:
/// - `rate`: LFO speed (0.0–1.0). Maps to 0.05Hz–5Hz exponentially.
/// - `depth`: Modulation depth (0.0–1.0). How far the notches sweep.
/// - `stages`: Number of all-pass stages (0.0–1.0). Maps to 2/4/6/8 stages.
///
/// Classic analog phaser topology: input splits dry + wet, wet passes through
/// N cascaded first-order all-pass filters with LFO-modulated coefficients,
/// then mixes back. Feedback from output to input adds resonance.
struct TideEffect {
    // Maximum all-pass stages (8 = deep phaser)
    private static let maxStages = 8

    // All-pass filter state (one per stage, transposed direct form II)
    private var apState: (Double, Double, Double, Double, Double, Double, Double, Double)
        = (0, 0, 0, 0, 0, 0, 0, 0)

    // LFO state
    private var lfoPhase: Double = 0

    // Feedback state
    private var feedbackSample: Double = 0

    // Target parameters
    private var rate: Double = 0.3
    private var depth: Double = 0.5
    private var stages: Int = 4

    // Smoothed parameters
    private var rateSmoothed: Double = 0.3
    private var depthSmoothed: Double = 0.5

    private let smoothCoeff: Double = 0.002

    // Fixed feedback amount (provides resonance character)
    private let feedback: Double = 0.4

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        rateSmoothed += (rate - rateSmoothed) * smoothCoeff
        depthSmoothed += (depth - depthSmoothed) * smoothCoeff

        // LFO: triangle wave for smooth sweep
        let lfoRateHz = 0.05 * pow(100.0, rateSmoothed)  // 0.05Hz–5Hz
        lfoPhase += lfoRateHz / Double(sampleRate)
        if lfoPhase >= 1.0 { lfoPhase -= 1.0 }
        let lfo = 4.0 * abs(lfoPhase - 0.5) - 1.0  // triangle -1..+1

        // Map LFO to all-pass coefficient range
        // Sweep center frequency: 200Hz–4kHz, modulated by depth
        let centerFreq = 800.0
        let modRange = depthSmoothed * 600.0
        let freqHz = max(100.0, min(Double(sampleRate) * 0.45, centerFreq + lfo * modRange))

        // First-order all-pass coefficient: a = (tan(pi*f/sr) - 1) / (tan(pi*f/sr) + 1)
        let t = tan(.pi * freqHz / Double(sampleRate))
        let coeff = (t - 1.0) / (t + 1.0)

        // Input with feedback
        let x = Double(sample) + feedbackSample * feedback

        // Cascade all-pass stages
        var y = x
        if stages >= 1 { y = allpass(y, coeff: coeff, state: &apState.0) }
        if stages >= 2 { y = allpass(y, coeff: coeff, state: &apState.1) }
        if stages >= 3 { y = allpass(y, coeff: coeff, state: &apState.2) }
        if stages >= 4 { y = allpass(y, coeff: coeff, state: &apState.3) }
        if stages >= 5 { y = allpass(y, coeff: coeff, state: &apState.4) }
        if stages >= 6 { y = allpass(y, coeff: coeff, state: &apState.5) }
        if stages >= 7 { y = allpass(y, coeff: coeff, state: &apState.6) }
        if stages >= 8 { y = allpass(y, coeff: coeff, state: &apState.7) }

        // Store feedback (soft clip to prevent runaway)
        feedbackSample = max(-1.0, min(1.0, y))

        return Float(y)
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let r = params["rate"] { rate = max(0, min(1, r)) }
        if let d = params["depth"] { depth = max(0, min(1, d)) }
        if let s = params["stages"] {
            // Map 0–1 to 2/4/6/8 stages. Also accept direct integer values.
            if s <= 1.0 {
                let mapped = Int(round(s * 3.0)) * 2 + 2  // 2,4,6,8
                stages = max(2, min(Self.maxStages, mapped))
            } else {
                stages = max(2, min(Self.maxStages, Int(s)))
            }
        }
    }

    /// Reset filter state.
    mutating func reset() {
        apState = (0, 0, 0, 0, 0, 0, 0, 0)
        feedbackSample = 0
        lfoPhase = 0
    }

    // MARK: - First-order all-pass (transposed direct form II)

    /// H(z) = (a + z^-1) / (1 + a*z^-1)
    /// y = a*x + state; state = x - a*y
    private func allpass(_ input: Double, coeff: Double, state: inout Double) -> Double {
        let y = coeff * input + state
        state = input - coeff * y
        return y
    }
}
