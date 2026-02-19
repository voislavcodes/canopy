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
/// Zero heap allocation after init, pure value type, audio-thread safe.
struct FlowVoice {
    // MARK: - Constants

    static let partialCount = 64
    static let controlBlockSize = 64
    static let eddyScaleCount = 6

    // MARK: - Partials

    var partials: [FlowPartial]

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

    // MARK: - Note state

    var frequency: Double = 440
    var velocity: Double = 0
    var isActive: Bool = false
    var envelopeLevel: Float = 0
    private var envPhase: Int = 0        // 0=idle, 1=attack, 2=sustain, 3=release
    private var envValue: Double = 0
    private var attackRate: Double = 0
    private var releaseRate: Double = 0

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
    private var noiseState: UInt32 = 12345  // xorshift RNG state

    // MARK: - Init

    init() {
        partials = [FlowPartial](repeating: FlowPartial(), count: Self.partialCount)
    }

    // MARK: - Note Control

    /// Trigger a note: initialize partials as harmonic series, begin envelope attack.
    mutating func trigger(pitch: Int, velocity: Double, sampleRate: Double) {
        self.frequency = MIDIUtilities.frequency(forNote: pitch)
        self.velocity = velocity
        self.isActive = true
        self.envPhase = 1 // attack
        self.envValue = 0
        // 5ms attack ramp
        self.attackRate = 1.0 / max(1, 0.005 * sampleRate)
        // 100ms release
        self.releaseRate = 1.0 / max(1, 0.1 * sampleRate)
        self.controlCounter = 0

        // Initialize partials as harmonic series (1/n^1.5 rolloff — steeper than
        // classic 1/n to leave headroom when modulation inflates upper partials)
        for i in 0..<Self.partialCount {
            let harmonic = Double(i + 1)
            partials[i].baseFreq = frequency * harmonic
            partials[i].baseAmp = 1.0 / pow(harmonic, 1.5)
            // Don't reset phase on retrigger for smoother legato
            partials[i].freqOffset = 0
            partials[i].freqOffsetTarget = 0
            partials[i].freqOffsetStep = 0
            partials[i].ampScale = 1
            partials[i].ampScaleTarget = 1
            partials[i].ampScaleStep = 0
            partials[i].pmDepth = 0
            partials[i].pmDepthTarget = 0
            partials[i].pmDepthStep = 0
            partials[i].vorticity = 0
            partials[i].laminarPhase = Double(i) * 0.1 // stagger drift
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
        for i in 0..<Self.partialCount {
            partials[i].vorticity = 0
            partials[i].phase = 0
            partials[i].pmPhase = 0
        }
    }

    // MARK: - Render

    /// Render one sample: advance envelope, interpolate params, sum 64 oscillators.
    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        // Advance envelope
        advanceEnvelope()
        guard envValue > 0.0001 else {
            if envPhase == 3 || envPhase == 0 {
                isActive = false
                envelopeLevel = 0
            }
            return 0
        }
        envelopeLevel = Float(envValue)

        // Control-rate update every 64 samples
        controlCounter += 1
        if controlCounter >= Self.controlBlockSize {
            controlCounter = 0
            updateControlRate(sampleRate: sampleRate)
        }

        // Smooth control parameters (per-sample)
        let paramSmooth = 0.001
        currentParam += (currentTarget - currentParam) * paramSmooth
        viscosityParam += (viscosityTarget - viscosityParam) * paramSmooth
        obstacleParam += (obstacleTarget - obstacleParam) * paramSmooth
        channelParam += (channelTarget - channelParam) * paramSmooth
        densityParam += (densityTarget - densityParam) * paramSmooth

        // Render all partials
        var mix: Double = 0
        let invSR = 1.0 / sampleRate
        let nyquist = sampleRate * 0.5 - 100

        for i in 0..<Self.partialCount {
            // Interpolate per-sample
            partials[i].freqOffset += partials[i].freqOffsetStep
            partials[i].ampScale += partials[i].ampScaleStep
            partials[i].pmDepth += partials[i].pmDepthStep

            // Compute actual frequency (Rule 7: clamp to safe range)
            let freq = min(max(partials[i].baseFreq + partials[i].freqOffset, 20), nyquist)

            // Phase modulation
            let pm = sin(2.0 * .pi * partials[i].pmPhase) * partials[i].pmDepth
            partials[i].pmPhase += freq * 1.001 * invSR // slightly detuned PM carrier
            if partials[i].pmPhase > 1e6 { partials[i].pmPhase -= Double(Int(partials[i].pmPhase)) }

            // Main oscillator
            let sample = sin(2.0 * .pi * partials[i].phase + pm)
            partials[i].phase += freq * invSR
            if partials[i].phase > 1e6 { partials[i].phase -= Double(Int(partials[i].phase)) }

            // Amplitude: base * scale (Rule 2: use exp for multiplicative modulation)
            let amp = partials[i].baseAmp * max(partials[i].ampScale, 0)
            mix += sample * amp
        }

        // Normalize: harmonic series H(64) ≈ 4.74 unmodulated peak.
        // With modulation headroom (~2x worst case), use 1/10 to keep signal
        // in the linear region of tanh under normal conditions.
        mix *= 0.1

        // Apply envelope and velocity
        mix *= envValue * Double(velocity)

        // Rule 5: tanh as safety net only (no drive — signal should already be < 1)
        let output = tanh(mix)

        return Float(output)
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
            break // hold at current level
        case 3: // Release
            envValue -= envValue * releaseRate
            if envValue < 0.0001 {
                envValue = 0
                envPhase = 0
                isActive = false
            }
        default:
            break
        }
    }

    // MARK: - Control Rate Update

    /// Every 64 samples: compute Reynolds number, regime weights,
    /// run 3 regime layers, set per-partial interpolation targets.
    private mutating func updateControlRate(sampleRate: Double) {
        let blockSize = Double(Self.controlBlockSize)
        let invBlock = 1.0 / blockSize

        // Compute Reynolds number: Re = (current * density * channel) / viscosity
        // All params 0–1, so scale to meaningful ranges
        let currentScaled = max(currentParam * 10.0, 0.001)  // Rule 1
        let viscosityScaled = max(viscosityParam * 5.0, 0.001)
        let obstacleScaled = max(obstacleParam, 0.001)
        let channelScaled = max(channelParam * 2.0, 0.001)
        let densityScaled = max(densityParam * 2.0, 0.001)

        reynoldsNumber = (currentScaled * densityScaled * channelScaled) / viscosityScaled

        // Regime blend weights (smooth crossfade regions)
        // Re < 10: fully laminar
        // 10 < Re < 50: laminar → transition blend
        // 50 < Re < 200: transition
        // 200 < Re < 500: transition → turbulent blend
        // Re > 500: fully turbulent
        if reynoldsNumber < 10 {
            laminarWeight = 1.0
            transitionWeight = 0.0
            turbulentWeight = 0.0
        } else if reynoldsNumber < 50 {
            let t = (reynoldsNumber - 10) / 40.0
            laminarWeight = 1.0 - t
            transitionWeight = t
            turbulentWeight = 0.0
        } else if reynoldsNumber < 200 {
            laminarWeight = 0.0
            transitionWeight = 1.0
            turbulentWeight = 0.0
        } else if reynoldsNumber < 500 {
            let t = (reynoldsNumber - 200) / 300.0
            laminarWeight = 0.0
            transitionWeight = 1.0 - t
            turbulentWeight = t
        } else {
            laminarWeight = 0.0
            transitionWeight = 0.0
            turbulentWeight = 1.0
        }

        // Advance shedding oscillator (Strouhal frequency)
        // St ≈ 0.2, so f_shed = 0.2 * U / D
        let sheddingFreq = 0.2 * currentScaled / obstacleScaled
        let sheddingInc = sheddingFreq / max(sampleRate / blockSize, 0.001)
        sheddingPhase += sheddingInc
        if sheddingPhase > 1.0 { sheddingPhase -= Double(Int(sheddingPhase)) }
        let sheddingSin = sin(2.0 * .pi * sheddingPhase)
        let sheddingCos = cos(2.0 * .pi * sheddingPhase)

        // Generate multi-scale noise for turbulence
        let noises = generateEddyNoise()

        // Apply 3 regime layers to each partial
        for i in 0..<Self.partialCount {
            let harmonic = Double(i + 1)
            var freqTarget = 0.0
            var ampTarget = 1.0
            var pmTarget = 0.0

            // Layer 1: LAMINAR — subtle sinusoidal drift
            if laminarWeight > 0.001 {
                partials[i].laminarPhase += 0.01 * (1.0 + Double(i) * 0.02)
                let drift = sin(partials[i].laminarPhase) * 0.5 // ±0.5 Hz drift
                freqTarget += drift * laminarWeight
                // Very slight amplitude shimmer
                let shimmer = 1.0 + sin(partials[i].laminarPhase * 0.7) * 0.02
                ampTarget *= (1.0 - laminarWeight) + laminarWeight * shimmer
            }

            // Layer 2: VORTEX SHEDDING — alternating vortex modulation
            if transitionWeight > 0.001 {
                // Even partials get sin, odd get cos (alternating vortices)
                let vortexMod = (i % 2 == 0) ? sheddingSin : sheddingCos

                // Frequency modulation: partials shift based on vortex
                let freqMod = vortexMod * 2.0 * harmonic * transitionWeight
                freqTarget += freqMod

                // Amplitude modulation via vortex (keep depth mild to avoid sum inflation)
                let ampMod = exp(vortexMod * 0.12 * transitionWeight) // Rule 2
                ampTarget *= ampMod

                // Phase modulation depth increases with transition
                pmTarget += abs(vortexMod) * 0.15 * transitionWeight

                // Accumulate vorticity with decay (Rule 3: clamp)
                partials[i].vorticity += vortexMod * 0.1 * transitionWeight
                partials[i].vorticity *= 0.95  // decay
                partials[i].vorticity = min(max(partials[i].vorticity, -1.0), 1.0)

                // Feed vorticity back into frequency
                freqTarget += partials[i].vorticity * 3.0
            }

            // Layer 3: TURBULENCE — multi-scale correlated noise (Kolmogorov cascade)
            if turbulentWeight > 0.001 {
                // Which eddy scale affects this partial?
                // Lower partials → larger eddies, higher → smaller eddies
                // Kolmogorov energy spectrum: E(k) ∝ k^(-5/3)
                let scaleIndex = min(i / (Self.partialCount / Self.eddyScaleCount), Self.eddyScaleCount - 1)
                let noiseVal = getEddyNoise(noises, scale: scaleIndex)

                // Energy follows k^(-5/3)
                let k = harmonic
                let energy = pow(k, -5.0 / 3.0)

                // Viscosity controls dissipation cutoff
                // Higher viscosity → less turbulence on higher partials
                let dissipation = exp(-harmonic * viscosityParam * 0.1)

                // Cascade onset delay: lower partials get turbulence first
                let onsetDelay = max(0, 1.0 - harmonic * 0.02)

                let turbStrength = energy * dissipation * onsetDelay * turbulentWeight

                // Frequency jitter
                freqTarget += noiseVal * 5.0 * turbStrength * harmonic

                // Amplitude modulation (reduced depth — 64 partials compound fast)
                ampTarget *= exp(noiseVal * 0.15 * turbStrength)  // Rule 2

                // Phase modulation
                pmTarget += abs(noiseVal) * 0.2 * turbStrength
            }

            // Set interpolation targets (Rule 4: linear interpolation)
            partials[i].freqOffsetTarget = freqTarget
            partials[i].freqOffsetStep = (freqTarget - partials[i].freqOffset) * invBlock

            partials[i].ampScaleTarget = ampTarget
            partials[i].ampScaleStep = (ampTarget - partials[i].ampScale) * invBlock

            partials[i].pmDepthTarget = pmTarget
            partials[i].pmDepthStep = (pmTarget - partials[i].pmDepth) * invBlock
        }
    }

    // MARK: - Noise Generation

    /// Xorshift32 RNG — audio-thread safe, no allocations.
    private mutating func xorshift() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        // Map to -1...1
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    /// Generate correlated noise for 6 eddy scales.
    /// One-pole filtered white noise per scale (larger eddies = lower cutoff).
    private mutating func generateEddyNoise() -> (Double, Double, Double, Double, Double, Double) {
        // Filter coefficients: larger eddies → lower cutoff → smoother noise
        let coeffs: (Double, Double, Double, Double, Double, Double) = (0.99, 0.95, 0.9, 0.8, 0.6, 0.3)

        let n0 = xorshift()
        let n1 = xorshift()
        let n2 = xorshift()
        let n3 = xorshift()
        let n4 = xorshift()
        let n5 = xorshift()

        eddyState.0 = eddyState.0 * coeffs.0 + n0 * (1 - coeffs.0)
        eddyState.1 = eddyState.1 * coeffs.1 + n1 * (1 - coeffs.1)
        eddyState.2 = eddyState.2 * coeffs.2 + n2 * (1 - coeffs.2)
        eddyState.3 = eddyState.3 * coeffs.3 + n3 * (1 - coeffs.3)
        eddyState.4 = eddyState.4 * coeffs.4 + n4 * (1 - coeffs.4)
        eddyState.5 = eddyState.5 * coeffs.5 + n5 * (1 - coeffs.5)

        return eddyState
    }

    /// Get noise value for a specific eddy scale.
    private func getEddyNoise(_ noises: (Double, Double, Double, Double, Double, Double), scale: Int) -> Double {
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
