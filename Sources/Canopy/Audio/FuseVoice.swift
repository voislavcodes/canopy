import Foundation

/// Per-voice DSP for the FUSE engine: three coupled nonlinear oscillators.
///
/// Signal flow (per sample):
///   1. Compute tune ratios (smooth power curve)
///   2. Compute matrix weights (6 coupling weights from MATRIX param)
///   3. Compute coupling depth (matrix² × 800 Hz, pitch-independent)
///   4. Compute modulated frequencies using CLEAN previous sine outputs
///   5. Clamp frequencies
///   6. Advance phases
///   7. Generate raw sines
///   8. Store clean outputs for next-sample coupling
///   9. Waveshape the sines for timbre (ADAA saturation + sinusoidal fold)
///  10. Mix waveshaped outputs
///  11. SVF filter
///  12. Filter envelope decay
///  13. Feedback path (DC block → tanh → scale)
///  14. Apply AD envelope, output linearly (no per-voice tanh)
///  15. WARM processing
///
/// CRITICAL: All state is inline (no arrays, no heap). Audio-thread safe.
struct FuseVoice {
    // MARK: - Oscillator State (3 named fields, NOT array)

    var oscPhaseA: Double = 0
    var oscPhaseB: Double = 0
    var oscPhaseC: Double = 0

    // Clean sine outputs for coupling (pre-waveshape)
    var oscCleanA: Double = 0
    var oscCleanB: Double = 0
    var oscCleanC: Double = 0

    // Waveshaped outputs for mix
    var oscOutputA: Double = 0
    var oscOutputB: Double = 0
    var oscOutputC: Double = 0

    // ADAA previous input state (one per oscillator)
    var prevInputA: Double = 0
    var prevInputB: Double = 0
    var prevInputC: Double = 0

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
    var matrixTarget: Double = 0.0
    var matrixParam: Double = 0.0
    var filterTarget: Double = 0.7
    var filterParam: Double = 0.7
    var feedbackTarget: Double = 0.0
    var feedbackParam: Double = 0.0
    var filterFBTarget: Double = 0.0
    var filterFBParam: Double = 0.0
    var attackTarget: Double = 0.1
    var attackParam: Double = 0.1
    var decayTarget: Double = 0.5
    var decayParam: Double = 0.5
    var warmthTarget: Double = 0.3
    var warmthParam: Double = 0.3

    // MARK: - Matrix Weights (smoothed, updated per control block)

    var wAB: Double = 0, wAC: Double = 0
    var wBA: Double = 0, wBC: Double = 0
    var wCA: Double = 0, wCB: Double = 0
    // Targets for one-pole smoothing
    var wABt: Double = 0, wACt: Double = 0
    var wBAt: Double = 0, wBCt: Double = 0
    var wCAt: Double = 0, wCBt: Double = 0
    var matrixBlockCounter: Int = 0

    // MARK: - Note State

    var frequency: Double = 440
    var velocity: Double = 0
    var isActive: Bool = false
    var envelopeLevel: Float = 0

    // AD Envelope: 0=idle, 1=attack, 2=decay, 3=fast-release, 4=steal-fade
    var envPhase: Int = 0
    var envValue: Double = 0
    var attackCoeff: Double = 0
    var decayCoeff: Double = 0

    // Filter envelope (velocity-scaled brightness transient)
    private var filterEnvValue: Double = 0
    private var filterDecayCoeff: Double = 0

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

        // Compute envelope coefficients
        recomputeEnvelopeCoeffs(sampleRate: sampleRate)

        // Filter envelope: velocity-scaled decay
        self.filterEnvValue = velocity
        let ampDecaySec = 0.05 * pow(100.0, decayParam)
        let velocityRatio = 0.2 + 0.3 * (1.0 - velocity)
        let filterDecaySec = ampDecaySec * velocityRatio
        self.filterDecayCoeff = exp(-1.0 / (filterDecaySec * sampleRate))

        // Don't reset oscillator phases — allows smooth transitions
        // Reset feedback state for clean start
        self.feedbackSample = 0
        self.dcPrevIn = 0
        self.dcPrevOut = 0
    }

    mutating func release(sampleRate: Double) {
        switch envPhase {
        case 1:
            // Note-off during attack → fast 5ms release
            envPhase = 3
            let fastReleaseSec = 0.005
            stealFadeRate = 1.0 / max(1, fastReleaseSec * sampleRate)
        case 2:
            // Note-off during decay → already fading, no change
            break
        default:
            break
        }
    }

    mutating func kill() {
        isActive = false
        envPhase = 0
        envValue = 0
        envelopeLevel = 0
        oscCleanA = 0; oscCleanB = 0; oscCleanC = 0
        oscOutputA = 0; oscOutputB = 0; oscOutputC = 0
        svfLow = 0
        svfBand = 0
        feedbackSample = 0
    }

    // MARK: - Render

    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        advanceEnvelope()
        guard envValue > 0.0001 else {
            if envPhase == 0 || envPhase == 2 {
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
        matrixParam += (matrixTarget - matrixParam) * paramSmooth
        filterParam += (filterTarget - filterParam) * paramSmooth
        feedbackParam += (feedbackTarget - feedbackParam) * paramSmooth
        filterFBParam += (filterFBTarget - filterFBParam) * paramSmooth
        attackParam += (attackTarget - attackParam) * paramSmooth
        decayParam += (decayTarget - decayParam) * paramSmooth
        warmthParam += (warmthTarget - warmthParam) * paramSmooth

        // Smooth matrix weights
        let matrixSmooth = 0.001
        wAB += (wABt - wAB) * matrixSmooth
        wAC += (wACt - wAC) * matrixSmooth
        wBA += (wBAt - wBA) * matrixSmooth
        wBC += (wBCt - wBC) * matrixSmooth
        wCA += (wCAt - wCA) * matrixSmooth
        wCB += (wCBt - wCB) * matrixSmooth

        // Update matrix weights every 64 samples
        matrixBlockCounter += 1
        if matrixBlockCounter >= 64 {
            matrixBlockCounter = 0
            computeMatrixTargets(matrix: matrixParam)
            recomputeEnvelopeCoeffs(sampleRate: sampleRate)
        }

        // WARM pitch drift
        let driftCents = WarmProcessor.computePitchOffset(&warmState, warm: Float(warmthParam), sampleRate: Float(sampleRate))
        let driftMul = Double(powf(2.0, driftCents / 1200.0))

        let baseFreq = frequency * driftMul

        // Step 1: Compute tune ratios (smooth power curves)
        let t2 = tuneParam * tuneParam
        let ratioB = pow(7.3, t2)
        let ratioC = pow(11.7, t2)

        // Step 2: Coupling depth (pitch-independent, quadratic)
        let coupleDepth = matrixParam * matrixParam * 800.0

        // Step 3: Filter feedback injection
        let filterFeedback = svfBand * filterFBParam * filterFBParam

        // Step 4: Feedback injection scale
        let fbInject = matrixParam * 0.5

        // Step 5: Compute modulated frequencies using CLEAN previous sines
        var freqA = baseFreq
            + coupleDepth * (oscCleanB * wAB + oscCleanC * wAC + filterFeedback)
            + feedbackSample * fbInject * 800.0
        var freqB = baseFreq * ratioB
            + coupleDepth * (oscCleanA * wBA + oscCleanC * wBC + filterFeedback)
            + feedbackSample * fbInject * 800.0
        var freqC = baseFreq * ratioC
            + coupleDepth * (oscCleanA * wCA + oscCleanB * wCB + filterFeedback)
            + feedbackSample * fbInject * 800.0

        // Step 6: Clamp frequencies
        let maxFreq = 0.48 * sampleRate
        freqA = max(0.1, min(maxFreq, freqA))
        freqB = max(0.1, min(maxFreq, freqB))
        freqC = max(0.1, min(maxFreq, freqC))

        // Step 7: Advance phases
        oscPhaseA += freqA / sampleRate
        oscPhaseA -= Double(Int(oscPhaseA))
        oscPhaseB += freqB / sampleRate
        oscPhaseB -= Double(Int(oscPhaseB))
        oscPhaseC += freqC / sampleRate
        oscPhaseC -= Double(Int(oscPhaseC))

        // Step 8: Generate raw sines
        let rawA = sin(2.0 * .pi * oscPhaseA)
        let rawB = sin(2.0 * .pi * oscPhaseB)
        let rawC = sin(2.0 * .pi * oscPhaseC)

        // Step 9: Store clean outputs for next-sample coupling
        oscCleanA = rawA
        oscCleanB = rawB
        oscCleanC = rawC

        // Step 10: Waveshape the sines for timbre
        oscOutputA = waveshape(rawA, character: characterParam, prevX: &prevInputA)
        oscOutputB = waveshape(rawB, character: characterParam, prevX: &prevInputB)
        oscOutputC = waveshape(rawC, character: characterParam, prevX: &prevInputC)

        // Step 11: Mix waveshaped outputs
        var mix = (oscOutputA + oscOutputB + oscOutputC) / 3.0

        // Step 12: SVF filter (Chamberlin)
        let filterCutoff = filterCutoffFromParam()
        let filterEnvCutoff = filterCutoff * (1.0 + filterEnvValue * 2.0)
        let clampedCutoff = min(filterEnvCutoff, 0.48 * sampleRate)
        let f = 2.0 * sin(.pi * clampedCutoff / sampleRate)
        // Q tied to feedback param — feedback adds resonance
        let q = max(0.15, 1.0 - feedbackParam * 0.85)

        svfLow += f * svfBand
        let high = mix - svfLow - q * svfBand
        svfBand += f * high

        mix = svfLow

        // Step 13: Filter envelope decay
        filterEnvValue *= filterDecayCoeff

        // Step 14: Feedback path (DC block → tanh → scale)
        let dcIn = mix
        let dcOut = dcIn - dcPrevIn + 0.995 * dcPrevOut
        dcPrevIn = dcIn
        dcPrevOut = dcOut

        let fbScaled = feedbackParam * feedbackParam * 0.98
        feedbackSample = tanh(dcOut) * fbScaled

        // Step 15: Apply AD envelope, output linearly (no per-voice tanh)
        let envOut = mix * envValue * velocity
        var output = Float(envOut)

        // WARM processing
        output = WarmProcessor.processSample(&warmState, sample: output,
                                              warm: Float(warmthParam), sampleRate: Float(sampleRate))

        return output
    }

    // MARK: - ADAA Waveshaping

    /// Continuous waveshaping: sine → ADAA saturation → sinusoidal fold.
    @inline(__always)
    private func waveshape(_ x: Double, character: Double, prevX: inout Double) -> Double {
        if character < 0.01 {
            prevX = x
            return x
        }

        if character < 0.5 {
            // Blend sine → ADAA asymmetric saturation
            let s = character * 2.0
            let driven = x * (1.0 + s * 2.0)

            // First-order ADAA
            let diff = driven - prevX
            let result: Double
            if abs(diff) < 1e-10 {
                result = saturate(driven)
            } else {
                result = (saturateAntideriv(driven) - saturateAntideriv(prevX)) / diff
            }
            prevX = driven

            let blend = character / 0.5
            return x * (1.0 - blend) + result * blend
        } else {
            // Blend saturation → sinusoidal fold
            let foldBlend = (character - 0.5) * 2.0
            let sat = saturate(x * 2.0)
            let gain = 1.0 + foldBlend * 3.0
            let folded = sin(.pi * 0.5 * x * gain)
            prevX = x
            return sat * (1.0 - foldBlend) + folded * foldBlend
        }
    }

    /// Asymmetric saturation: positive x/(1+x), negative x/(1-0.8x).
    @inline(__always)
    private func saturate(_ x: Double) -> Double {
        if x >= 0 {
            return x / (1.0 + x)
        } else {
            return x / (1.0 - 0.8 * x)
        }
    }

    /// Antiderivative of asymmetric saturation for ADAA.
    /// Positive: F(x) = x - ln(1+x)
    /// Negative: F(x) = -1.5625·ln(1-0.8x) - 1.25x
    @inline(__always)
    private func saturateAntideriv(_ x: Double) -> Double {
        if x >= 0 {
            return x - log(1.0 + x)
        } else {
            return -1.5625 * log(1.0 - 0.8 * x) - 1.25 * x
        }
    }

    // MARK: - Matrix Coupling Topology

    /// Compute 6 coupling weight targets from MATRIX parameter.
    /// 5 waypoints with raised-cosine interpolation.
    private mutating func computeMatrixTargets(matrix: Double) {
        // Waypoints: [None, Symmetric, FM Chain, Asymmetric, Full]
        //            A←B   A←C   B←A   B←C   C←A   C←B
        // 0.00 None:  0     0     0     0     0     0
        // 0.25 Sym:   0.5   0.5   0.5   0.5   0.5   0.5
        // 0.50 FM:    1.0   0.0   0.0   1.0   0.0   0.0
        // 0.75 Asym:  1.0   0.3   0.0   1.0   0.7   0.0
        // 1.00 Full:  1.0   1.0   1.0   1.0   1.0   1.0

        let seg = matrix * 4.0
        let idx = min(3, Int(seg))
        let t = seg - Double(idx)
        let blend = 0.5 - 0.5 * cos(.pi * t)

        // Waypoint values per weight [AB, AC, BA, BC, CA, CB]
        switch idx {
        case 0: // None → Symmetric
            wABt = 0.5 * blend
            wACt = 0.5 * blend
            wBAt = 0.5 * blend
            wBCt = 0.5 * blend
            wCAt = 0.5 * blend
            wCBt = 0.5 * blend
        case 1: // Symmetric → FM Chain
            wABt = 0.5 * (1 - blend) + 1.0 * blend
            wACt = 0.5 * (1 - blend) + 0.0 * blend
            wBAt = 0.5 * (1 - blend) + 0.0 * blend
            wBCt = 0.5 * (1 - blend) + 1.0 * blend
            wCAt = 0.5 * (1 - blend) + 0.0 * blend
            wCBt = 0.5 * (1 - blend) + 0.0 * blend
        case 2: // FM Chain → Asymmetric
            wABt = 1.0 * (1 - blend) + 1.0 * blend
            wACt = 0.0 * (1 - blend) + 0.3 * blend
            wBAt = 0.0 * (1 - blend) + 0.0 * blend
            wBCt = 1.0 * (1 - blend) + 1.0 * blend
            wCAt = 0.0 * (1 - blend) + 0.7 * blend
            wCBt = 0.0 * (1 - blend) + 0.0 * blend
        default: // Asymmetric → Full
            wABt = 1.0 * (1 - blend) + 1.0 * blend
            wACt = 0.3 * (1 - blend) + 1.0 * blend
            wBAt = 0.0 * (1 - blend) + 1.0 * blend
            wBCt = 1.0 * (1 - blend) + 1.0 * blend
            wCAt = 0.7 * (1 - blend) + 1.0 * blend
            wCBt = 0.0 * (1 - blend) + 1.0 * blend
        }
    }

    // MARK: - Filter Cutoff

    /// Map filter parameter (0–1) to frequency (60Hz–18kHz, exponential).
    @inline(__always)
    private func filterCutoffFromParam() -> Double {
        return 60.0 * pow(300.0, filterParam)  // 60 * 300^1 = 18000
    }

    // MARK: - Envelope

    private mutating func recomputeEnvelopeCoeffs(sampleRate: Double) {
        let attackSec = 0.001 * pow(500.0, attackParam)
        let decaySec = 0.05 * pow(100.0, decayParam)
        attackCoeff = 1.0 - exp(-1.0 / (attackSec * sampleRate))
        decayCoeff = exp(-1.0 / (decaySec * sampleRate))
    }

    private mutating func advanceEnvelope() {
        switch envPhase {
        case 1: // Attack (one-pole toward 1.0)
            envValue += (1.0 - envValue) * attackCoeff
            if envValue >= 0.999 {
                envValue = 1.0
                envPhase = 2 // → decay (one-shot)
            }
        case 2: // Decay (multiplicative, one-shot — ignores note-off)
            envValue *= decayCoeff
            if envValue < 0.0001 {
                envValue = 0
                envPhase = 0
                isActive = false
            }
        case 3: // Fast release (note-off during attack)
            envValue -= stealFadeRate
            if envValue <= 0.001 {
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
