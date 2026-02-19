import Foundation

/// Per-voice DSP for West Coast complex oscillator synthesis.
/// Signal chain: primary osc + FM/ring mod → wavefolder → LPG (vactrol model).
/// Function generator replaces ADSR — provides rise/fall envelope with optional looping.
/// Zero allocations, pure value type, audio-thread safe.
struct WestCoastVoice {
    // MARK: - Configuration (set from main thread via AudioCommand)

    var primaryWaveform: Int = 0    // 0=sine, 1=triangle
    var modulatorRatio: Double = 1.0
    var modulatorFineTune: Double = 0  // cents
    var fmDepth: Double = 3.0
    var envToFM: Double = 0.5
    var ringModMix: Double = 0.0
    var foldAmount: Double = 0.3
    var foldStages: Int = 2
    var foldSymmetry: Double = 0.5
    var modToFold: Double = 0.0
    var lpgMode: Int = 2            // 0=filter, 1=vca, 2=both
    var strike: Double = 0.7
    var damp: Double = 0.4
    var color: Double = 0.6
    var rise: Double = 0.005
    var fall: Double = 0.3
    var funcShape: Int = 1          // 0=linear, 1=exponential, 2=logarithmic
    var funcLoop: Bool = false

    // MARK: - Per-voice state

    private var primaryPhase: Double = 0
    private var modulatorPhase: Double = 0
    private var frequency: Double = 440
    private var velocity: Double = 0
    private(set) var isActive: Bool = false

    // Function generator state
    private var funcGenLevel: Double = 0  // 0–1
    private var funcGenPhase: Int = 0     // 0=idle, 1=rise, 2=fall

    // Vactrol LPG state
    private var vactrolLevel: Double = 0  // 0–1, smoothed gate
    private var vactrolTarget: Double = 0

    // One-pole filter state for LPG color
    private var lpgFilterState: Double = 0

    /// Envelope level for voice stealing comparisons.
    var envelopeLevel: Float {
        Float(vactrolLevel)
    }

    // MARK: - Note Control

    /// Trigger a note: set frequency, start function generator rise phase.
    mutating func trigger(pitch: Int, velocity: Double, sampleRate: Double) {
        self.frequency = MIDIUtilities.frequency(forNote: pitch)
        self.velocity = velocity
        self.isActive = true

        // Start function generator rise
        funcGenPhase = 1
        // Don't reset funcGenLevel — allows re-triggering during decay for legato

        // Strike: immediate vactrol impulse proportional to strike * velocity
        vactrolTarget = strike * velocity
    }

    /// Release: begin function generator fall phase.
    mutating func release(sampleRate: Double) {
        funcGenPhase = 2
    }

    /// Silence immediately.
    mutating func kill() {
        isActive = false
        funcGenPhase = 0
        funcGenLevel = 0
        vactrolLevel = 0
        vactrolTarget = 0
        lpgFilterState = 0
    }

    // MARK: - Render

    /// Render one sample through the full West Coast signal chain.
    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        // 1. Advance function generator
        advanceFuncGen(sampleRate: sampleRate)

        // 2. Advance vactrol (smooth follower of funcGenLevel)
        advanceVactrol(sampleRate: sampleRate)

        // 3. Calculate effective FM depth (base + env modulation)
        let effectiveFMDepth = fmDepth + fmDepth * envToFM * funcGenLevel

        // 4. Modulator oscillator
        let modFineTuneMultiplier = pow(2.0, modulatorFineTune / 1200.0)
        let modFreq = frequency * modulatorRatio * modFineTuneMultiplier
        let modSample = sin(2.0 * .pi * modulatorPhase)
        modulatorPhase += modFreq / sampleRate
        if modulatorPhase > 1.0 { modulatorPhase -= Double(Int(modulatorPhase)) }

        // 5. Primary oscillator with FM
        let fmOffset = modSample * effectiveFMDepth
        let primaryRaw: Double
        if primaryWaveform == 1 {
            // Triangle
            let p = primaryPhase + fmOffset / (2.0 * .pi)
            let wrapped = p - floor(p)
            primaryRaw = 4.0 * abs(wrapped - 0.5) - 1.0
        } else {
            // Sine (default)
            primaryRaw = sin(2.0 * .pi * primaryPhase + fmOffset)
        }
        primaryPhase += frequency / sampleRate
        if primaryPhase > 1.0 { primaryPhase -= Double(Int(primaryPhase)) }

        // 6. Ring modulation mix
        let ringMod = primaryRaw * modSample
        let postRing = primaryRaw * (1.0 - ringModMix) + ringMod * ringModMix

        // 7. Wavefolder
        let effectiveFold = foldAmount + modToFold * (modSample * 0.5 + 0.5)
        let folded = wavefold(postRing, amount: effectiveFold, stages: foldStages, symmetry: foldSymmetry)

        // 8. LPG (vactrol-modeled low-pass gate)
        let gated = applyLPG(folded, sampleRate: sampleRate)

        // 9. Apply velocity and final output
        let output = Float(gated * velocity)

        // Auto-deactivate when envelope and vactrol are both silent
        if funcGenPhase == 0 && vactrolLevel < 0.0001 {
            isActive = false
        }

        return output
    }

    // MARK: - Function Generator

    /// Advance the function generator by one sample.
    /// Supports linear, exponential, and logarithmic shapes.
    private mutating func advanceFuncGen(sampleRate: Double) {
        switch funcGenPhase {
        case 1: // Rise
            let riseRate: Double
            switch funcShape {
            case 0: // Linear
                riseRate = 1.0 / max(0.001, rise * sampleRate)
                funcGenLevel = min(1.0, funcGenLevel + riseRate)
            case 2: // Logarithmic (fast start, slow finish)
                let target = 1.0
                let tau = max(0.001, rise) * 0.33
                let coeff = 1.0 - exp(-1.0 / (tau * sampleRate))
                funcGenLevel += (target - funcGenLevel) * coeff
            default: // Exponential (slow start, fast finish — default)
                let tau = max(0.001, rise) * 0.33
                let coeff = 1.0 - exp(-1.0 / (tau * sampleRate))
                funcGenLevel += (1.0 - funcGenLevel) * coeff
            }

            if funcGenLevel >= 0.999 {
                funcGenLevel = 1.0
                funcGenPhase = 2 // Transition to fall
            }

        case 2: // Fall
            switch funcShape {
            case 0: // Linear
                let fallRate = 1.0 / max(0.01, fall * sampleRate)
                funcGenLevel = max(0.0, funcGenLevel - fallRate)
            case 2: // Logarithmic
                let tau = max(0.01, fall) * 0.33
                let coeff = 1.0 - exp(-1.0 / (tau * sampleRate))
                funcGenLevel -= funcGenLevel * coeff
            default: // Exponential
                let tau = max(0.01, fall) * 0.5
                let coeff = exp(-1.0 / (tau * sampleRate))
                funcGenLevel *= coeff
            }

            if funcGenLevel < 0.001 {
                funcGenLevel = 0
                if funcLoop {
                    funcGenPhase = 1 // Loop back to rise
                } else {
                    funcGenPhase = 0 // Done
                }
            }

        default:
            break
        }
    }

    // MARK: - Vactrol Model

    /// Model vactrol behavior: fast 12ms rise, variable 50ms–2000ms fall.
    /// The `damp` parameter controls fall time within that range.
    private mutating func advanceVactrol(sampleRate: Double) {
        let target = funcGenLevel * strike

        if target > vactrolLevel {
            // Fast rise: ~12ms time constant
            let riseTime = 0.012
            let coeff = 1.0 - exp(-1.0 / (riseTime * sampleRate))
            vactrolLevel += (target - vactrolLevel) * coeff
        } else {
            // Variable fall: 50ms (damp=0) to 2000ms (damp=1)
            let fallTime = 0.05 + damp * 1.95
            let coeff = exp(-1.0 / (fallTime * sampleRate))
            vactrolLevel *= coeff
            // Pull toward target
            if vactrolLevel < target {
                vactrolLevel = target
            }
        }
    }

    // MARK: - Wavefolder

    /// Multi-stage soft wavefolder with tanh smoothing.
    private func wavefold(_ input: Double, amount: Double, stages: Int, symmetry: Double) -> Double {
        guard amount > 0.001 else { return input }

        // Asymmetry bias: shift the signal before folding
        let bias = (symmetry - 0.5) * 0.5
        var signal = input + bias

        // Drive signal by fold amount (1–10x gain)
        let drive = 1.0 + amount * 9.0
        signal *= drive

        // Multi-stage folding
        for _ in 0..<stages {
            signal = softFold(signal)
        }

        return signal
    }

    /// Single-stage soft fold using tanh for smooth saturation.
    private func softFold(_ x: Double) -> Double {
        // Fold: reflect signal at ±1 boundaries, then smooth with tanh
        let folded = sin(x * .pi * 0.5)
        return tanh(folded * 1.5) / tanh(1.5) // Normalize
    }

    // MARK: - Low Pass Gate

    /// Apply LPG: combined VCA and/or one-pole lowpass filter controlled by vactrol.
    private mutating func applyLPG(_ input: Double, sampleRate: Double) -> Double {
        var output = input

        // Filter mode: one-pole lowpass controlled by vactrol + color
        if lpgMode == 0 || lpgMode == 2 {
            // Cutoff frequency: vactrol level maps from ~100Hz to ~18kHz
            let minFreq = 80.0
            let maxFreq = 18000.0
            let cutoffFreq = minFreq * pow(maxFreq / minFreq, vactrolLevel * color)
            let rc = 1.0 / (2.0 * .pi * cutoffFreq)
            let dt = 1.0 / sampleRate
            let alpha = dt / (rc + dt)

            lpgFilterState += alpha * (output - lpgFilterState)
            output = lpgFilterState
        }

        // VCA mode: amplitude controlled by vactrol
        if lpgMode == 1 || lpgMode == 2 {
            output *= vactrolLevel
        }

        return output
    }
}
