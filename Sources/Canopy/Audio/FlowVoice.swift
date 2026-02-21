import Foundation

/// Per-partial state for the FLOW engine's 64-sine additive/fluid model.
/// Each partial is a sine oscillator whose frequency, amplitude, and phase modulation
/// are driven by three fluid regime layers (laminar, vortex shedding, turbulence).
struct FlowPartial {
    // Oscillator state
    var phase: Double = 0
    var pmPhase: Double = 0

    // Harmonic template
    var baseFreq: Double = 0     // Hz (harmonic series frequency)
    var baseAmp: Double = 0      // amplitude weight in harmonic series

    // Feedback state
    var vorticity: Double = 0    // accumulated vortex feedback, clamped -1...1

    // Laminar drift accumulator
    var laminarPhase: Double = 0

    // Interpolation: current → target over 64 samples
    var freqOffset: Double = 0
    var freqOffsetTarget: Double = 0
    var freqOffsetStep: Double = 0

    var ampScale: Double = 1
    var ampScaleTarget: Double = 1
    var ampScaleStep: Double = 0

    var pmDepth: Double = 0
    var pmDepthTarget: Double = 0
    var pmDepthStep: Double = 0
}

/// Per-voice DSP for the FLOW engine.
/// 64 sine partials embedded in a simulated fluid where Reynolds number
/// (derived from 5 user controls) drives continuous phase transitions between
/// laminar purity, vortex shedding rhythm, and Kolmogorov turbulence.
///
/// CRITICAL: Partials stored as a tuple, NOT an array. Swift arrays are heap-allocated
/// with CoW semantics — every subscript mutation triggers an atomic refcount check.
/// Tuple storage is fully inline (zero heap, zero refcount, zero CoW).
/// Loop access via withUnsafeMutablePointer + withMemoryRebound.
struct FlowVoice {
    // MARK: - Constants

    static let partialCount = 64
    static let controlBlockSize = 64
    static let eddyScaleCount = 6

    // MARK: - Partials (inline tuple — NO heap, NO CoW, audio-thread safe)

    var partials: (FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial,
                   FlowPartial, FlowPartial, FlowPartial, FlowPartial)

    // MARK: - Control inputs (smoothed toward targets)

    var currentParam: Double = 0.2       // 0–1
    var currentTarget: Double = 0.2
    var viscosityParam: Double = 0.5
    var viscosityTarget: Double = 0.5
    var obstacleParam: Double = 0.3
    var obstacleTarget: Double = 0.3
    var channelParam: Double = 0.5
    var channelTarget: Double = 0.5
    var densityParam: Double = 0.5
    var densityTarget: Double = 0.5
    var warmthParam: Double = 0.3
    var warmthTarget: Double = 0.3

    // MARK: - Note state

    var frequency: Double = 440
    var velocity: Double = 0
    var isActive: Bool = false
    var envelopeLevel: Float = 0
    private var envPhase: Int = 0        // 0=idle, 1=attack, 2=sustain, 3=release, 4=steal-fade
    private var envValue: Double = 0
    private var attackRate: Double = 0
    private var releaseRate: Double = 0

    // Steal-fade: pending note waits while old envelope fades to zero over ~5ms.
    private var pendingPitch: Int = -1
    private var pendingVelocity: Double = 0
    private var stealFadeRate: Double = 0
    private var cachedSampleRate: Double = 48000

    // MARK: - Control-rate state

    private var controlCounter: Int = 0

    // Shedding oscillator (global per voice)
    private var sheddingPhase: Double = 0

    // Reynolds number and regime blend
    private var reynoldsNumber: Double = 0
    private var laminarWeight: Double = 1.0
    private var transitionWeight: Double = 0.0
    private var turbulentWeight: Double = 0.0

    // Multi-scale noise state (6 eddy scales)
    private var eddyState: (Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0)
    var noiseState: UInt32 = 12345  // xorshift RNG state (internal so manager can set unique seeds)

    // Control-rate cached values (computed once per 64 samples, used in render)
    private var cachedSheddingSin: Double = 0
    private var cachedSheddingCos: Double = 0
    private var cachedNoises: (Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0)
    private var doControlUpdate: Bool = false

    // MARK: - Init

    init() {
        let p = FlowPartial()
        partials = (p, p, p, p, p, p, p, p, p, p, p, p, p, p, p, p,
                    p, p, p, p, p, p, p, p, p, p, p, p, p, p, p, p,
                    p, p, p, p, p, p, p, p, p, p, p, p, p, p, p, p,
                    p, p, p, p, p, p, p, p, p, p, p, p, p, p, p, p)
    }

    // MARK: - Note Control

    /// Trigger a note. If the voice is already active, enter a 5ms steal-fade
    /// to ramp the old signal to zero before starting the new note.
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

    /// Configure and start the note.
    private mutating func beginNote(pitch: Int, velocity: Double, sampleRate: Double) {
        self.frequency = MIDIUtilities.frequency(forNote: pitch)
        self.velocity = velocity
        self.isActive = true
        self.envPhase = 1
        self.envValue = 0
        self.cachedSampleRate = sampleRate
        self.attackRate = 1.0 / max(1, 0.005 * sampleRate)
        self.releaseRate = 1.0 / max(1, 0.1 * sampleRate)
        self.controlCounter = 0
        self.pendingPitch = -1

        let freq = self.frequency
        withUnsafeMutablePointer(to: &partials) { ptr in
            ptr.withMemoryRebound(to: FlowPartial.self, capacity: Self.partialCount) { p in
                for i in 0..<Self.partialCount {
                    let harmonic = Double(i + 1)
                    p[i].baseFreq = freq * harmonic
                    p[i].baseAmp = 1.0 / pow(harmonic, 1.5)
                    p[i].phase = 0
                    p[i].pmPhase = 0
                    p[i].freqOffset = 0
                    p[i].freqOffsetTarget = 0
                    p[i].freqOffsetStep = 0
                    p[i].ampScale = 1
                    p[i].ampScaleTarget = 1
                    p[i].ampScaleStep = 0
                    p[i].pmDepth = 0
                    p[i].pmDepthTarget = 0
                    p[i].pmDepthStep = 0
                    p[i].vorticity = 0
                    p[i].laminarPhase = Double(i) * 0.1
                }
            }
        }
    }

    /// Release: begin exponential envelope decay.
    mutating func release(sampleRate: Double) {
        if envPhase != 0 {
            envPhase = 3
            releaseRate = 1.0 / max(1, 0.1 * sampleRate)
        }
    }

    /// Kill immediately.
    mutating func kill() {
        isActive = false
        envPhase = 0
        envValue = 0
        envelopeLevel = 0
        withUnsafeMutablePointer(to: &partials) { ptr in
            ptr.withMemoryRebound(to: FlowPartial.self, capacity: Self.partialCount) { p in
                for i in 0..<Self.partialCount {
                    p[i].vorticity = 0
                    p[i].phase = 0
                    p[i].pmPhase = 0
                }
            }
        }
    }

    // MARK: - Render

    /// Render one sample. Control-rate values (Reynolds, regime, shedding, noise)
    /// are computed BEFORE the pointer borrow. The pointer block then handles both
    /// control-rate partial updates and per-sample rendering in a single borrow.
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

        // Control-rate: compute everything that doesn't touch partials
        controlCounter += 1
        doControlUpdate = false
        if controlCounter >= Self.controlBlockSize {
            controlCounter = 0
            doControlUpdate = true
            computeControlRate(sampleRate: sampleRate)
        }

        // Smooth control parameters (per-sample)
        let paramSmooth = 0.001
        currentParam += (currentTarget - currentParam) * paramSmooth
        viscosityParam += (viscosityTarget - viscosityParam) * paramSmooth
        obstacleParam += (obstacleTarget - obstacleParam) * paramSmooth
        channelParam += (channelTarget - channelParam) * paramSmooth
        densityParam += (densityTarget - densityParam) * paramSmooth
        warmthParam += (warmthTarget - warmthParam) * paramSmooth

        // Single pointer borrow for ALL partial access (control update + render)
        var mix: Double = 0
        let invSR = 1.0 / sampleRate
        let nyquist = sampleRate * 0.5 - 100
        let invBlock = 1.0 / Double(Self.controlBlockSize)
        let needsControl = doControlUpdate
        let lamW = laminarWeight
        let transW = transitionWeight
        let turbW = turbulentWeight
        let visP = viscosityParam
        let shedSin = cachedSheddingSin
        let shedCos = cachedSheddingCos
        let noises = cachedNoises

        withUnsafeMutablePointer(to: &partials) { ptr in
            ptr.withMemoryRebound(to: FlowPartial.self, capacity: Self.partialCount) { p in

                // Control-rate: update per-partial targets (every 64 samples)
                if needsControl {
                    for i in 0..<Self.partialCount {
                        let harmonic = Double(i + 1)
                        var freqTarget = 0.0
                        var ampTarget = 1.0
                        var pmTarget = 0.0

                        // Layer 1: LAMINAR
                        if lamW > 0.001 {
                            p[i].laminarPhase += 0.01 * (1.0 + Double(i) * 0.02)
                            let drift = sin(p[i].laminarPhase) * 0.5
                            freqTarget += drift * lamW
                            let shimmer = 1.0 + sin(p[i].laminarPhase * 0.7) * 0.02
                            ampTarget *= (1.0 - lamW) + lamW * shimmer
                        }

                        // Layer 2: VORTEX SHEDDING
                        if transW > 0.001 {
                            let vortexMod = (i % 2 == 0) ? shedSin : shedCos
                            freqTarget += vortexMod * 2.0 * harmonic * transW
                            ampTarget *= exp(vortexMod * 0.12 * transW)
                            pmTarget += abs(vortexMod) * 0.15 * transW
                            p[i].vorticity += vortexMod * 0.1 * transW
                            p[i].vorticity *= 0.95
                            p[i].vorticity = min(max(p[i].vorticity, -1.0), 1.0)
                            freqTarget += p[i].vorticity * 3.0
                        }

                        // Layer 3: TURBULENCE
                        if turbW > 0.001 {
                            let scaleIndex = min(i / (Self.partialCount / Self.eddyScaleCount), Self.eddyScaleCount - 1)
                            let noiseVal = Self.getEddyNoise(noises, scale: scaleIndex)
                            let energy = pow(harmonic, -5.0 / 3.0)
                            let dissipation = exp(-harmonic * visP * 0.1)
                            let onsetDelay = max(0, 1.0 - harmonic * 0.02)
                            let turbStrength = energy * dissipation * onsetDelay * turbW
                            freqTarget += noiseVal * 5.0 * turbStrength * harmonic
                            ampTarget *= exp(noiseVal * 0.15 * turbStrength)
                            pmTarget += abs(noiseVal) * 0.2 * turbStrength
                        }

                        p[i].freqOffsetTarget = freqTarget
                        p[i].freqOffsetStep = (freqTarget - p[i].freqOffset) * invBlock
                        p[i].ampScaleTarget = ampTarget
                        p[i].ampScaleStep = (ampTarget - p[i].ampScale) * invBlock
                        p[i].pmDepthTarget = pmTarget
                        p[i].pmDepthStep = (pmTarget - p[i].pmDepth) * invBlock
                    }
                }

                // Per-sample: interpolate + render all partials
                for i in 0..<Self.partialCount {
                    p[i].freqOffset += p[i].freqOffsetStep
                    p[i].ampScale += p[i].ampScaleStep
                    p[i].pmDepth += p[i].pmDepthStep

                    let rawFreq = p[i].baseFreq + p[i].freqOffset
                    guard rawFreq < nyquist else { continue }
                    let freq = max(rawFreq, 20)

                    let pm = sin(2.0 * .pi * p[i].pmPhase) * p[i].pmDepth
                    p[i].pmPhase += freq * 1.001 * invSR
                    p[i].pmPhase -= Double(Int(p[i].pmPhase))

                    let sample = sin(2.0 * .pi * p[i].phase + pm)
                    p[i].phase += freq * invSR
                    p[i].phase -= Double(Int(p[i].phase))

                    let amp = p[i].baseAmp * max(p[i].ampScale, 0)
                    mix += sample * amp
                }
            }
        }

        mix *= 0.1
        mix *= envValue * Double(velocity)
        let drive = 0.3 + warmthParam * 1.2
        let shaped = tanh(mix * drive) / drive
        return Float(shaped)
    }

    // MARK: - Envelope

    private mutating func advanceEnvelope() {
        switch envPhase {
        case 1: // Attack
            envValue += attackRate
            if envValue >= 1.0 {
                envValue = 1.0
                envPhase = 2
            }
        case 2: // Sustain
            break
        case 3: // Release
            envValue -= envValue * releaseRate
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
                    beginNote(pitch: pendingPitch, velocity: pendingVelocity, sampleRate: cachedSampleRate)
                } else {
                    envPhase = 0
                    isActive = false
                }
            }
        default:
            break
        }
    }

    // MARK: - Control Rate (non-partial computation)

    /// Compute Reynolds number, regime weights, shedding oscillator, and noise.
    /// Does NOT touch partials — those are updated in the render pointer block.
    private mutating func computeControlRate(sampleRate: Double) {
        let blockSize = Double(Self.controlBlockSize)

        let currentScaled = max(currentParam * 10.0, 0.001)
        let viscosityScaled = max(0.01 * pow(500.0, viscosityParam), 0.001)
        let obstacleScaled = max(obstacleParam, 0.001)
        let channelScaled = max(channelParam * 2.0, 0.001)
        let densityScaled = max(densityParam * 2.0, 0.001)

        reynoldsNumber = (currentScaled * densityScaled * channelScaled) / viscosityScaled

        if reynoldsNumber < 10 {
            laminarWeight = 1.0; transitionWeight = 0.0; turbulentWeight = 0.0
        } else if reynoldsNumber < 50 {
            let t = (reynoldsNumber - 10) / 40.0
            laminarWeight = 1.0 - t; transitionWeight = t; turbulentWeight = 0.0
        } else if reynoldsNumber < 200 {
            laminarWeight = 0.0; transitionWeight = 1.0; turbulentWeight = 0.0
        } else if reynoldsNumber < 500 {
            let t = (reynoldsNumber - 200) / 300.0
            laminarWeight = 0.0; transitionWeight = 1.0 - t; turbulentWeight = t
        } else {
            laminarWeight = 0.0; transitionWeight = 0.0; turbulentWeight = 1.0
        }

        let sheddingFreq = 0.2 * currentScaled / obstacleScaled
        let sheddingInc = sheddingFreq / max(sampleRate / blockSize, 0.001)
        sheddingPhase += sheddingInc
        if sheddingPhase > 1.0 { sheddingPhase -= Double(Int(sheddingPhase)) }
        cachedSheddingSin = sin(2.0 * .pi * sheddingPhase)
        cachedSheddingCos = cos(2.0 * .pi * sheddingPhase)

        cachedNoises = generateEddyNoise()
    }

    // MARK: - Noise Generation

    private mutating func xorshift() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    private mutating func generateEddyNoise() -> (Double, Double, Double, Double, Double, Double) {
        let coeffs: (Double, Double, Double, Double, Double, Double) = (0.99, 0.95, 0.9, 0.8, 0.6, 0.3)
        let n0 = xorshift(); let n1 = xorshift(); let n2 = xorshift()
        let n3 = xorshift(); let n4 = xorshift(); let n5 = xorshift()
        eddyState.0 = eddyState.0 * coeffs.0 + n0 * (1 - coeffs.0)
        eddyState.1 = eddyState.1 * coeffs.1 + n1 * (1 - coeffs.1)
        eddyState.2 = eddyState.2 * coeffs.2 + n2 * (1 - coeffs.2)
        eddyState.3 = eddyState.3 * coeffs.3 + n3 * (1 - coeffs.3)
        eddyState.4 = eddyState.4 * coeffs.4 + n4 * (1 - coeffs.4)
        eddyState.5 = eddyState.5 * coeffs.5 + n5 * (1 - coeffs.5)
        return eddyState
    }

    private static func getEddyNoise(_ noises: (Double, Double, Double, Double, Double, Double), scale: Int) -> Double {
        switch scale {
        case 0: return noises.0
        case 1: return noises.1
        case 2: return noises.2
        case 3: return noises.3
        case 4: return noises.4
        case 5: return noises.5
        default: return noises.0
        }
    }
}
