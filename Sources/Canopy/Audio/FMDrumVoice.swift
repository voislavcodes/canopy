import Foundation

/// Single FM drum voice for audio-thread rendering.
/// 2-operator FM synthesis with pitch envelope, amplitude envelope, and noise mix.
/// Zero allocations, pure value type, audio-thread safe.
struct FMDrumVoice {
    // Parameters
    var carrierFreq: Double = 180       // Hz
    var modulatorRatio: Double = 1.5    // freq multiplier relative to carrier
    var fmDepth: Double = 5.0           // modulation index
    var noiseMix: Double = 0.0          // 0-1, blend with noise
    var ampDecay: Double = 0.3          // seconds
    var pitchEnvAmount: Double = 2.0    // octaves of sweep
    var pitchDecay: Double = 0.05       // seconds
    var level: Double = 0.8             // 0-1

    // State
    private var carrierPhase: Double = 0
    private var modulatorPhase: Double = 0
    private var ampEnvelope: Double = 0
    private var pitchEnvelope: Double = 0
    private var velocity: Double = 0
    private(set) var isActive: Bool = false

    // LCG noise state
    private var noiseSeed: UInt32 = 12345

    /// Trigger the voice. Resets phases and starts envelopes.
    mutating func trigger(velocity: Double) {
        self.velocity = velocity
        self.ampEnvelope = 1.0
        self.pitchEnvelope = 1.0
        self.carrierPhase = 0
        self.modulatorPhase = 0
        self.isActive = true
    }

    /// Render one sample. Returns the output value.
    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        // Exponential decay for amplitude
        let ampDecayRate = ampDecay > 0 ? exp(-1.0 / (ampDecay * sampleRate)) : 0
        ampEnvelope *= ampDecayRate

        // Exponential decay for pitch
        let pitchDecayRate = pitchDecay > 0 ? exp(-1.0 / (pitchDecay * sampleRate)) : 0
        pitchEnvelope *= pitchDecayRate

        // Pitch with envelope sweep
        let pitchMultiplier = pow(2.0, pitchEnvAmount * pitchEnvelope)
        let currentCarrierFreq = carrierFreq * pitchMultiplier

        // FM synthesis: modulator → carrier
        let modulatorFreq = currentCarrierFreq * modulatorRatio
        let modOutput = sin(2.0 * .pi * modulatorPhase) * fmDepth
        let fmSample = sin(2.0 * .pi * carrierPhase + modOutput)

        // Advance phases
        carrierPhase += currentCarrierFreq / sampleRate
        if carrierPhase > 1.0 { carrierPhase -= 1.0 }
        modulatorPhase += modulatorFreq / sampleRate
        if modulatorPhase > 1.0 { modulatorPhase -= 1.0 }

        // Noise (LCG)
        noiseSeed = noiseSeed &* 1103515245 &+ 12345
        let noiseValue = Double(Int32(bitPattern: noiseSeed)) / Double(Int32.max)

        // Mix FM and noise
        let mixed = fmSample * (1.0 - noiseMix) + noiseValue * noiseMix

        // Apply envelope and velocity
        let output = Float(mixed * ampEnvelope * velocity * level)

        // Auto-deactivate when quiet enough
        if ampEnvelope < 0.001 {
            isActive = false
        }

        return output
    }

    // MARK: - Factory Presets

    static func kickPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 60, modulatorRatio: 1.0, fmDepth: 4.0,
                    noiseMix: 0.02, ampDecay: 0.4, pitchEnvAmount: 3.0,
                    pitchDecay: 0.03, level: 0.9)
    }

    static func snarePreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 180, modulatorRatio: 2.3, fmDepth: 3.0,
                    noiseMix: 0.5, ampDecay: 0.2, pitchEnvAmount: 1.0,
                    pitchDecay: 0.02, level: 0.8)
    }

    static func closedHatPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 400, modulatorRatio: 3.7, fmDepth: 6.0,
                    noiseMix: 0.7, ampDecay: 0.05, pitchEnvAmount: 0.5,
                    pitchDecay: 0.01, level: 0.6)
    }

    static func openHatPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 400, modulatorRatio: 3.7, fmDepth: 6.0,
                    noiseMix: 0.7, ampDecay: 0.3, pitchEnvAmount: 0.5,
                    pitchDecay: 0.01, level: 0.6)
    }

    static func tomLowPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 100, modulatorRatio: 1.2, fmDepth: 3.0,
                    noiseMix: 0.05, ampDecay: 0.35, pitchEnvAmount: 2.5,
                    pitchDecay: 0.04, level: 0.8)
    }

    static func tomHighPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 150, modulatorRatio: 1.2, fmDepth: 3.0,
                    noiseMix: 0.05, ampDecay: 0.3, pitchEnvAmount: 2.0,
                    pitchDecay: 0.03, level: 0.8)
    }

    static func crashPreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 300, modulatorRatio: 4.5, fmDepth: 8.0,
                    noiseMix: 0.6, ampDecay: 1.0, pitchEnvAmount: 0.3,
                    pitchDecay: 0.02, level: 0.5)
    }

    static func ridePreset() -> FMDrumVoice {
        FMDrumVoice(carrierFreq: 500, modulatorRatio: 3.1, fmDepth: 5.0,
                    noiseMix: 0.4, ampDecay: 0.6, pitchEnvAmount: 0.2,
                    pitchDecay: 0.01, level: 0.5)
    }
}
