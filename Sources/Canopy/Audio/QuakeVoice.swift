import Foundation

/// Single QUAKE percussion voice for audio-thread rendering.
/// Physics-based synthesis: pitch sweep → 2-op FM → filtered noise → body filter → amp env → saturation.
/// Zero allocations, pure value type, audio-thread safe.
struct QuakeVoice {
    // Regime base values (set at trigger time based on voice slot)
    var baseFreq: Double = 180
    var baseFMRatio: Double = 1.5
    var baseNoiseMix: Double = 0.3
    var baseDecayMs: Double = 200

    // Shared physics controls (0–1, set from QuakeConfig)
    var mass: Double = 0.5
    var surface: Double = 0.3
    var force: Double = 0.5
    var sustain: Double = 0.3

    // State
    private var carrierPhase: Double = 0
    private var modulatorPhase: Double = 0
    private var pitchEnvPhase: Double = 0   // 1 at trigger, decays to 0
    private var ampEnv: Double = 0          // 1 at trigger, decays to 0
    private var noiseEnvPhase: Double = 0   // fast noise burst envelope
    private var svfLow: Double = 0          // Chamberlin SVF state
    private var svfBand: Double = 0         // Chamberlin SVF state
    private var noiseSeed: UInt32 = 12345
    private var velocity: Double = 0
    private var dronePhase: Double = 0      // for self-sustain above sustain 0.85
    private(set) var isActive: Bool = false

    // Orbital coupling (optional, from OrbitSequencer)
    private var orbitalPitchDetune: Double = 0
    private var orbitalAttackMod: Double = 0

    /// Trigger the voice with velocity and optional orbital state.
    mutating func trigger(velocity: Double, orbitalSpeed: Double = 0, orbitalStress: Double = 0) {
        self.velocity = velocity
        self.ampEnv = 1.0
        self.pitchEnvPhase = 1.0
        self.noiseEnvPhase = 1.0
        self.carrierPhase = 0
        self.modulatorPhase = 0
        self.isActive = true

        // Orbital coupling: subtle pitch detune from gravitational stress
        self.orbitalPitchDetune = orbitalStress * 0.02  // up to 2% detune
        // Attack sharpness from crossing speed
        self.orbitalAttackMod = orbitalSpeed * 0.3      // faster = sharper
    }

    /// Render one sample. Returns mono output.
    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        let sr = sampleRate

        // --- Derived parameters from shared controls ---

        // Mass → frequency scaling (higher mass = lower freq)
        let freqScale = 1.0 - mass * 0.6  // 1.0 at mass=0, 0.4 at mass=1
        let impactFreq = baseFreq * freqScale

        // Mass → pitch sweep depth (higher mass = more sweep)
        let sweepOctaves = 1.0 + mass * 3.0  // 1–4 octaves

        // Force → sweep boost (higher force = more initial pitch)
        let sweepBoost = 1.0 + force * 2.0  // 1–3x

        // Force → pitch envelope decay rate
        let pitchDecayMs = 10.0 + (1.0 - force) * 40.0  // 10–50ms
        let pitchDecayRate = exp(-1000.0 / (pitchDecayMs * sr))

        // Surface → FM modulation index
        let fmIndex = surface * 12.0  // 0–12

        // Surface → FM ratio bend (slight detuning from base)
        let ratioBend = 1.0 + surface * 0.15  // 1.0–1.15x

        // Force → noise burst amplitude
        let noiseBurst = baseNoiseMix * (0.5 + force * 0.5)

        // Sustain → decay time
        let decayMs = baseDecayMs * (0.3 + sustain * 3.0)  // 30%–330% of base
        let ampDecayRate = exp(-1000.0 / (decayMs * sr))

        // Sustain → body filter Q
        let bodyQ = 0.5 + sustain * 4.5  // 0.5–5.0

        // Mass → body filter frequency (lower mass = higher body resonance)
        let bodyFreq = impactFreq * (2.0 + (1.0 - mass) * 4.0)  // 2–6x carrier

        // Mass → noise filter cutoff
        let noiseCutoff = min(0.99, (1.0 - mass * 0.6))  // higher mass = duller noise

        // --- 1. Pitch sweep ---
        pitchEnvPhase *= pitchDecayRate
        let pitchMultiplier = pow(2.0, sweepOctaves * sweepBoost * pitchEnvPhase)
        let currentFreq = impactFreq * pitchMultiplier * (1.0 + orbitalPitchDetune)

        // --- 2. Two-operator FM ---
        let modulatorFreq = currentFreq * baseFMRatio * ratioBend
        let modOutput = sin(2.0 * .pi * modulatorPhase) * fmIndex
        let fmSample = sin(2.0 * .pi * carrierPhase + modOutput)

        // Advance FM phases
        carrierPhase += currentFreq / sr
        if carrierPhase > 1e6 { carrierPhase -= 1e6 }
        modulatorPhase += modulatorFreq / sr
        if modulatorPhase > 1e6 { modulatorPhase -= 1e6 }

        // --- 3. Filtered noise burst ---
        noiseSeed = noiseSeed &* 1103515245 &+ 12345
        let rawNoise = Double(Int32(bitPattern: noiseSeed)) / Double(Int32.max)

        // Fast noise envelope decay (2–10ms)
        let noiseDecayMs = 2.0 + (1.0 - force) * 8.0
        let noiseDecayRate = exp(-1000.0 / (noiseDecayMs * sr))
        noiseEnvPhase *= noiseDecayRate
        let filteredNoise = rawNoise * noiseEnvPhase * noiseCutoff

        // Mix FM and noise
        let dryMix = fmSample * (1.0 - noiseBurst) + filteredNoise * noiseBurst

        // --- 4. Body filter (Chamberlin SVF bandpass) ---
        let f = min(0.99, 2.0 * sin(.pi * bodyFreq / sr))
        let q = 1.0 / bodyQ
        svfLow += f * svfBand
        let svfHigh = dryMix - svfLow - q * svfBand
        svfBand += f * svfHigh

        // Blend: mostly dry with body resonance added
        let bodyBlend = sustain * 0.4  // more sustain = more body resonance
        let bodied = dryMix * (1.0 - bodyBlend) + svfBand * bodyBlend

        // --- 5. Amplitude envelope ---
        ampEnv *= ampDecayRate

        // --- 6. Tanh saturation (kicks in above force 0.7) ---
        var output = bodied * ampEnv * velocity
        if force > 0.7 {
            let drive = 1.0 + (force - 0.7) * 10.0  // 1–4x drive
            output = tanh(output * drive) / tanh(drive)
        }

        // --- 7. Drone crossover (self-sustain above sustain 0.85) ---
        if sustain > 0.85 {
            let droneAmount = (sustain - 0.85) / 0.15  // 0–1 over 0.85–1.0
            dronePhase += currentFreq / sr
            if dronePhase > 1e6 { dronePhase -= 1e6 }
            let droneSample = sin(2.0 * .pi * dronePhase + modOutput * 0.3)
            output += droneSample * droneAmount * velocity * 0.3
        }

        // Auto-deactivate when quiet enough (but not in drone mode)
        if ampEnv < 0.001 && sustain < 0.85 {
            isActive = false
        }

        return Float(output)
    }

    // MARK: - Voice Regime Factories

    /// Kick drum regime.
    static func kick() -> QuakeVoice {
        QuakeVoice(baseFreq: 55, baseFMRatio: 1.0, baseNoiseMix: 0.15, baseDecayMs: 200)
    }

    /// Snare drum regime.
    static func snare() -> QuakeVoice {
        QuakeVoice(baseFreq: 200, baseFMRatio: 2.3, baseNoiseMix: 0.60, baseDecayMs: 150)
    }

    /// Closed hi-hat regime.
    static func closedHat() -> QuakeVoice {
        QuakeVoice(baseFreq: 6000, baseFMRatio: 3.7, baseNoiseMix: 0.80, baseDecayMs: 50)
    }

    /// Open hi-hat regime.
    static func openHat() -> QuakeVoice {
        QuakeVoice(baseFreq: 6000, baseFMRatio: 3.7, baseNoiseMix: 0.70, baseDecayMs: 400)
    }

    /// Low tom regime.
    static func tomLow() -> QuakeVoice {
        QuakeVoice(baseFreq: 90, baseFMRatio: 1.2, baseNoiseMix: 0.10, baseDecayMs: 250)
    }

    /// High tom regime.
    static func tomHigh() -> QuakeVoice {
        QuakeVoice(baseFreq: 180, baseFMRatio: 1.2, baseNoiseMix: 0.10, baseDecayMs: 200)
    }

    /// Crash cymbal regime.
    static func crash() -> QuakeVoice {
        QuakeVoice(baseFreq: 4000, baseFMRatio: 4.5, baseNoiseMix: 0.85, baseDecayMs: 1500)
    }

    /// Ride cymbal regime.
    static func ride() -> QuakeVoice {
        QuakeVoice(baseFreq: 5000, baseFMRatio: 3.1, baseNoiseMix: 0.40, baseDecayMs: 800)
    }
}
