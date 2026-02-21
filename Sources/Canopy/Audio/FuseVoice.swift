import Foundation

/// Per-voice DSP for the FUSE engine: three coupled nonlinear oscillators.
///
/// Three analog-modeled oscillators form a mutual influence network where
/// coupling strength, frequency relationships, and feedback create a continuous
/// space that unifies subtractive, FM, hard sync, ring mod, cross-modulation,
/// and waveshaping synthesis.
///
/// CRITICAL: All state is inline (no arrays, no heap). Audio-thread safe.
struct FuseVoice {
    // MARK: - Oscillator State (3 named fields, NOT array)

    var oscPhaseA: Double = 0
    var oscPhaseB: Double = 0
    var oscPhaseC: Double = 0

    var oscOutputA: Double = 0   // previous sample for coupling
    var oscOutputB: Double = 0
    var oscOutputC: Double = 0

    // MARK: - SVF Filter (network participant)

    var svfLow: Double = 0
    var svfBand: Double = 0

    // MARK: - Feedback Loop

    var feedbackSample: Double = 0
    var dcPrevIn: Double = 0
    var dcPrevOut: Double = 0

    // MARK: - Parameter Targets + Smoothed Values

    var characterTarget: Double = 0.1
    var characterParam: Double = 0.1
    var tuneTarget: Double = 0.0
    var tuneParam: Double = 0.0
    var coupleTarget: Double = 0.0
    var coupleParam: Double = 0.0
    var filterTarget: Double = 0.7
    var filterParam: Double = 0.7
    var feedbackTarget: Double = 0.0
    var feedbackParam: Double = 0.0
    var warmthTarget: Double = 0.3
    var warmthParam: Double = 0.3

    // MARK: - Note State

    var frequency: Double = 440
    var velocity: Double = 0
    var isActive: Bool = false
    var envelopeLevel: Float = 0

    // Envelope (attack/sustain/release/steal-fade)
    var envPhase: Int = 0       // 0=idle, 1=attack, 2=sustain, 3=release, 4=steal-fade
    var envValue: Double = 0

    // Filter envelope (velocity-scaled brightness transient)
    private var filterEnvValue: Double = 0

    // Steal-fade
    var pendingPitch: Int = -1
    private var pendingVelocity: Double = 0
    var stealFadeRate: Double = 0
    private var cachedSampleRate: Double = 48000

    // MARK: - Per-voice RNG

    var rng: UInt64 = 0x1234_5678_9ABC_DEF0

    // MARK: - WARM

    var warmState: WarmVoiceState = WarmVoiceState()

    // MARK: - Init

    init() {}

    // MARK: - Note Control

    /// Trigger a note. If voice is active, enter 5ms steal-fade.
    mutating func trigger(pitch: Int, velocity: Double, sampleRate: Double) {
        if isActive && envValue > 0.001 {
            pendingPitch = pitch
            pendingVelocity = velocity
            cachedSampleRate = sampleRate
            stealFadeRate = 1.0 / max(1, 0.005 * sampleRate)
            envPhase = 4
            return
        }
        beginNote(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    private mutating func beginNote(pitch: Int, velocity: Double, sampleRate: Double) {
        self.frequency = MIDIUtilities.frequency(forNote: pitch)
        self.velocity = velocity
        self.isActive = true
        self.envPhase = 1
        self.envValue = 0
        self.cachedSampleRate = sampleRate
        self.pendingPitch = -1

        // Don't reset oscillator phases — allows smooth transitions
        // But DO reset filter envelope for brightness transient
        self.filterEnvValue = velocity

        // Reset feedback state for clean start
        self.feedbackSample = 0
        self.dcPrevIn = 0
        self.dcPrevOut = 0
    }

    mutating func release(sampleRate: Double) {
        if envPhase != 0 {
            envPhase = 3
        }
    }

    mutating func kill() {
        isActive = false
        envPhase = 0
        envValue = 0
        envelopeLevel = 0
        oscOutputA = 0
        oscOutputB = 0
        oscOutputC = 0
        svfLow = 0
        svfBand = 0
        feedbackSample = 0
    }

    // MARK: - Render

    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        advanceEnvelope()
        guard envValue > 0.0001 else {
            if envPhase == 3 || envPhase == 0 {
                isActive = false
                envelopeLevel = 0
            }
            return 0
        }
        envelopeLevel = Float(envValue)

        // Smooth parameters (per-sample, one-pole)
        let paramSmooth = 0.002
        let tuneSmooth = 0.0005
        characterParam += (characterTarget - characterParam) * paramSmooth
        tuneParam += (tuneTarget - tuneParam) * tuneSmooth
        coupleParam += (coupleTarget - coupleParam) * paramSmooth
        filterParam += (filterTarget - filterParam) * paramSmooth
        feedbackParam += (feedbackTarget - feedbackParam) * paramSmooth
        warmthParam += (warmthTarget - warmthParam) * paramSmooth

        // WARM pitch drift
        let driftCents = WarmProcessor.computePitchOffset(&warmState, warm: Float(warmthParam), sampleRate: Float(sampleRate))
        let driftMul = Double(powf(2.0, driftCents / 1200.0))

        let baseFreq = frequency * driftMul

        // Step 1: Compute tune ratios
        let (ratioA, ratioB, ratioC) = tuneRatios(tune: tuneParam)

        // Step 2: Coupling depth (cubic for fine low-end control)
        let coupleDepth = coupleParam * coupleParam * coupleParam * baseFreq * 4.0

        // Step 3: Feedback injection scale
        let fbInject = coupleParam * 0.5

        // Step 4: Compute modulated frequencies
        // Coupling matrix weights:
        //   A←B: 1.0, A←C: 0.7, A←Filter: 0.3
        //   B←A: 1.0, B←C: 1.0, B←Filter: 0.3
        //   C←A: 0.7, C←B: 1.0, C←Filter: 0.3

        let filterFeedback = svfBand // bandpass feeds back into coupling

        var freqA = baseFreq * ratioA
            + coupleDepth * (oscOutputB * 1.0 + oscOutputC * 0.7 + filterFeedback * 0.3)
            + feedbackSample * fbInject * baseFreq
        var freqB = baseFreq * ratioB
            + coupleDepth * (oscOutputA * 1.0 + oscOutputC * 1.0 + filterFeedback * 0.3)
            + feedbackSample * fbInject * baseFreq
        var freqC = baseFreq * ratioC
            + coupleDepth * (oscOutputA * 0.7 + oscOutputB * 1.0 + filterFeedback * 0.3)
            + feedbackSample * fbInject * baseFreq

        // Step 5: Clamp frequencies
        let maxFreq = 0.48 * sampleRate
        freqA = max(0.1, min(maxFreq, freqA))
        freqB = max(0.1, min(maxFreq, freqB))
        freqC = max(0.1, min(maxFreq, freqC))

        // Step 6: Advance phases
        oscPhaseA += freqA / sampleRate
        oscPhaseA -= Double(Int(oscPhaseA))
        oscPhaseB += freqB / sampleRate
        oscPhaseB -= Double(Int(oscPhaseB))
        oscPhaseC += freqC / sampleRate
        oscPhaseC -= Double(Int(oscPhaseC))

        // Step 7: Waveshape
        let rawA = sin(2.0 * .pi * oscPhaseA)
        let rawB = sin(2.0 * .pi * oscPhaseB)
        let rawC = sin(2.0 * .pi * oscPhaseC)

        oscOutputA = waveshape(rawA, character: characterParam)
        oscOutputB = waveshape(rawB, character: characterParam)
        oscOutputC = waveshape(rawC, character: characterParam)

        // Step 8: Sum oscillators
        var mix = (oscOutputA + oscOutputB + oscOutputC) / 3.0

        // Step 9: SVF filter (Chamberlin)
        let filterCutoff = filterCutoffFromParam()
        let filterEnvCutoff = filterCutoff * (1.0 + filterEnvValue * 2.0) // brightness transient
        let clampedCutoff = min(filterEnvCutoff, 0.48 * sampleRate)
        let f = 2.0 * sin(.pi * clampedCutoff / sampleRate)
        let q = max(0.05, 1.0 - filterParam * 0.95)

        svfLow += f * svfBand
        let high = mix - svfLow - q * svfBand
        svfBand += f * high

        // Mix LP with a bit of input based on filter position
        mix = svfLow

        // Step 10: Filter envelope decay
        filterEnvValue *= 0.9993

        // Step 11: Feedback path
        // output → DC block → tanh → scale
        let dcIn = mix
        let dcOut = dcIn - dcPrevIn + 0.995 * dcPrevOut
        dcPrevIn = dcIn
        dcPrevOut = dcOut

        let fbScaled = feedbackParam * feedbackParam * 0.98
        feedbackSample = tanh(dcOut) * fbScaled

        // Step 12: Apply amplitude envelope and output limiting
        let envOut = mix * envValue * velocity
        var output = Float(tanh(envOut * 1.5))

        // WARM processing
        output = WarmProcessor.processSample(&warmState, sample: output,
                                              warm: Float(warmthParam), sampleRate: Float(sampleRate))

        return output
    }

    // MARK: - Waveshaping

    /// Continuous waveshaping: sine → asymmetric saturation → triangle wavefolding.
    @inline(__always)
    private func waveshape(_ x: Double, character: Double) -> Double {
        if character < 0.01 {
            // Pure sine
            return x
        } else if character < 0.5 {
            // Blend sine → asymmetric saturation
            let s = character * 2.0  // 0–1 within this range
            let sat = x * (1.0 + s) / (1.0 + s * abs(x))
            let blend = character / 0.5
            return x * (1.0 - blend) + sat * blend
        } else {
            // Blend saturation → triangle wavefolding
            let s = 1.0  // full saturation amount
            let sat = x * (1.0 + s) / (1.0 + s * abs(x))
            let foldBlend = (character - 0.5) / 0.5

            // 2-pass fold at ±1
            var folded = x * (1.0 + foldBlend * 2.0)
            // First fold
            if folded > 1.0 { folded = 2.0 - folded }
            else if folded < -1.0 { folded = -2.0 - folded }
            // Second fold
            if folded > 1.0 { folded = 2.0 - folded }
            else if folded < -1.0 { folded = -2.0 - folded }

            return sat * (1.0 - foldBlend) + folded * foldBlend
        }
    }

    // MARK: - Tune Ratios

    /// Piecewise curve mapping tune parameter (0–1) to three oscillator frequency ratios.
    @inline(__always)
    private func tuneRatios(tune: Double) -> (Double, Double, Double) {
        if tune < 0.1 {
            // Unison detune: ±7 cents max
            let t = tune / 0.1
            let detuneCents = t * 7.0
            let ratioUp = pow(2.0, detuneCents / 1200.0)
            let ratioDown = pow(2.0, -detuneCents / 1200.0)
            return (1.0, ratioUp, ratioDown)
        } else if tune < 0.25 {
            // Close intervals: unison → fifth → octave
            let t = (tune - 0.1) / 0.15
            let ratioB = 1.0 + t * 0.5   // 1.0 → 1.5 (fifth)
            let ratioC = 1.0 + t * 1.0   // 1.0 → 2.0 (octave)
            return (1.0, ratioB, ratioC)
        } else if tune < 0.5 {
            // Harmonic FM ratios: 1:1.5:2 → 1:2:3
            let t = (tune - 0.25) / 0.25
            let ratioB = 1.5 + t * 0.5   // 1.5 → 2.0
            let ratioC = 2.0 + t * 1.0   // 2.0 → 3.0
            return (1.0, ratioB, ratioC)
        } else if tune < 0.75 {
            // Enharmonic ratios: → 1:√7:π
            let t = (tune - 0.5) / 0.25
            let ratioB = 2.0 + t * (2.6457513 - 2.0)  // 2.0 → √7
            let ratioC = 3.0 + t * (.pi - 3.0)         // 3.0 → π
            return (1.0, ratioB, ratioC)
        } else {
            // Extreme spread: → 1:7.3:11.7
            let t = (tune - 0.75) / 0.25
            let ratioB = 2.6457513 + t * (7.3 - 2.6457513)   // √7 → 7.3
            let ratioC = .pi + t * (11.7 - .pi)                // π → 11.7
            return (1.0, ratioB, ratioC)
        }
    }

    // MARK: - Filter Cutoff

    /// Map filter parameter (0–1) to frequency (60Hz–18kHz, exponential).
    @inline(__always)
    private func filterCutoffFromParam() -> Double {
        return 60.0 * pow(300.0, filterParam)  // 60 * 300^1 = 18000
    }

    // MARK: - Envelope

    private mutating func advanceEnvelope() {
        switch envPhase {
        case 1: // Attack (one-pole toward 1.0)
            envValue += (1.0 - envValue) * 0.003
            if envValue >= 0.999 {
                envValue = 1.0
                envPhase = 2
            }
        case 2: // Sustain
            break
        case 3: // Release (multiplicative decay)
            envValue *= 0.9997
            if envValue < 0.0001 {
                envValue = 0
                envPhase = 0
                isActive = false
            }
        case 4: // Steal-fade
            envValue -= stealFadeRate
            if envValue <= 0.001 {
                envValue = 0
                if pendingPitch >= 0 {
                    beginNote(pitch: pendingPitch, velocity: pendingVelocity,
                              sampleRate: cachedSampleRate)
                } else {
                    envPhase = 0
                    isActive = false
                }
            }
        default:
            break
        }
    }
}
