import Foundation

/// Per-grain state for the SPORE engine's 64-grain pool.
/// Each grain is a short sine burst with a raised cosine envelope.
struct SporeGrain {
    var phase: Double = 0           // oscillator phase
    var freq: Double = 0            // grain frequency in Hz
    var amplitude: Float = 0        // grain amplitude
    var envelopePhase: Float = 0    // 0–1 position in grain envelope
    var envelopeRate: Float = 0     // increment per sample
    var pan: Float = 0              // -1 to +1
    var active: Bool = false        // is this grain sounding?
}

/// Per-voice DSP for the SPORE engine.
/// 64 grains fired by a Poisson clock. Each grain's frequency is drawn from a
/// probability landscape shaped by harmonic weighting, Gaussian scatter, and
/// uniform blending. The landscape slowly evolves under smoothed random walks.
///
/// CRITICAL: Grains and harmonic weights stored as tuples, NOT arrays.
/// Tuple storage is fully inline (zero heap, zero refcount, zero CoW).
struct SporeVoice {
    // MARK: - Constants

    static let grainCount = 64
    static let controlBlockSize = 64
    static let harmonicCount = 64
    static let gaussianTableSize = 1024

    // MARK: - Grains (inline tuple — NO heap, NO CoW, audio-thread safe)

    var grains: (SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain,
                 SporeGrain, SporeGrain, SporeGrain, SporeGrain)

    // MARK: - Harmonic weights (inline tuple)

    var harmonicWeights: (Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double,
                          Double, Double, Double, Double, Double, Double, Double, Double)

    // MARK: - Control inputs (smoothed toward targets)

    var densityParam: Double = 0.5
    var densityTarget: Double = 0.5
    var focusParam: Double = 0.5
    var focusTarget: Double = 0.5
    var grainParam: Double = 0.4
    var grainTarget: Double = 0.4
    var evolveParam: Double = 0.3
    var evolveTarget: Double = 0.3
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

    // Steal-fade
    private var pendingPitch: Int = -1
    private var pendingVelocity: Double = 0
    private var stealFadeRate: Double = 0
    private var cachedSampleRate: Double = 48000

    /// Whether this voice uses imprint amplitudes from the manager.
    var useImprint: Bool = false

    // MARK: - Poisson clock state

    private var samplesUntilNextGrain: Int = 0

    // MARK: - Evolution state (random walks, clamped)

    private var focusModulation: Double = 0
    private var densityModulation: Double = 0
    private var centroidShift: Double = 0
    private var panModulation: Double = 0
    private var grainSizeModulation: Double = 0

    // MARK: - Control-rate state

    private var controlCounter: Int = 0

    // MARK: - Noise state (xorshift RNG)

    var noiseState: UInt32 = 12345       // grain drawing
    private var evolveNoiseState: UInt32 = 54321  // evolution

    // MARK: - Init

    init() {
        let g = SporeGrain()
        grains = (g, g, g, g, g, g, g, g, g, g, g, g, g, g, g, g,
                  g, g, g, g, g, g, g, g, g, g, g, g, g, g, g, g,
                  g, g, g, g, g, g, g, g, g, g, g, g, g, g, g, g,
                  g, g, g, g, g, g, g, g, g, g, g, g, g, g, g, g)

        // Default harmonic weights: 1/h falloff
        var w: (Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double,
                Double, Double, Double, Double, Double, Double, Double, Double)
        = (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
           1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1)
        withUnsafeMutablePointer(to: &w) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: Self.harmonicCount) { p in
                for i in 0..<Self.harmonicCount {
                    p[i] = 1.0 / Double(i + 1)
                }
            }
        }
        harmonicWeights = w
    }

    // MARK: - Note Control

    /// Trigger a note. If voice is already active, enter 5ms steal-fade.
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
        self.releaseRate = 1.0 / max(1, 0.15 * sampleRate)
        self.controlCounter = 0
        self.pendingPitch = -1
        self.samplesUntilNextGrain = 0

        // Reset evolution
        focusModulation = 0
        densityModulation = 0
        centroidShift = 0
        panModulation = 0
        grainSizeModulation = 0

        // Kill all active grains
        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                for i in 0..<Self.grainCount {
                    p[i].active = false
                }
            }
        }
    }

    /// Release: begin envelope decay.
    mutating func release(sampleRate: Double) {
        if envPhase != 0 {
            envPhase = 3
            releaseRate = 1.0 / max(1, 0.15 * sampleRate)
        }
    }

    /// Kill immediately.
    mutating func kill() {
        isActive = false
        envPhase = 0
        envValue = 0
        envelopeLevel = 0
        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                for i in 0..<Self.grainCount {
                    p[i].active = false
                }
            }
        }
    }

    // MARK: - Render

    /// Render one stereo sample.
    mutating func renderSample(sampleRate: Double) -> (Float, Float) {
        guard isActive else { return (0, 0) }

        advanceEnvelope()
        guard envValue > 0.0001 else {
            if envPhase == 3 || envPhase == 0 {
                isActive = false
                envelopeLevel = 0
            }
            return (0, 0)
        }
        envelopeLevel = Float(envValue)

        // Smooth control parameters (per-sample, coeff 0.001 = Rule 5)
        let paramSmooth = 0.001
        densityParam += (densityTarget - densityParam) * paramSmooth
        focusParam += (focusTarget - focusParam) * paramSmooth
        grainParam += (grainTarget - grainParam) * paramSmooth
        evolveParam += (evolveTarget - evolveParam) * paramSmooth
        warmthParam += (warmthTarget - warmthParam) * paramSmooth

        // Control-rate: evolution (every 64 samples)
        controlCounter += 1
        if controlCounter >= Self.controlBlockSize {
            controlCounter = 0
            advanceEvolution(sampleRate: sampleRate)
        }

        // Poisson clock: check if it's time to fire a grain
        samplesUntilNextGrain -= 1
        if samplesUntilNextGrain <= 0 {
            let effectiveDensity = max(0, min(1, densityParam + densityModulation))
            let effectiveFocus = max(0, min(1, focusParam + focusModulation))
            let effectiveGrain = max(0, min(1, grainParam + grainSizeModulation))
            fireGrain(f0: frequency, focus: effectiveFocus, grain: effectiveGrain,
                      density: effectiveDensity, sampleRate: sampleRate)
            scheduleNextGrain(density: effectiveDensity, sampleRate: sampleRate)
        }

        // Render all active grains → stereo
        var mixL: Float = 0
        var mixR: Float = 0
        let invSR = 1.0 / sampleRate
        let nyquist = sampleRate * 0.5 - 100

        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                for i in 0..<Self.grainCount {
                    guard p[i].active else { continue }

                    // Advance grain envelope
                    p[i].envelopePhase += p[i].envelopeRate
                    if p[i].envelopePhase >= 1.0 {
                        p[i].active = false
                        continue
                    }

                    // Nyquist guard
                    guard p[i].freq < nyquist && p[i].freq > 20 else {
                        p[i].active = false
                        continue
                    }

                    // Raised cosine envelope: 0.5 * (1 - cos(2π * phase))
                    let envVal = 0.5 * (1.0 - cosf(2.0 * .pi * p[i].envelopePhase))

                    // Sine oscillator
                    let sample = sinf(Float(2.0 * .pi * p[i].phase)) * p[i].amplitude * envVal

                    // Advance phase
                    p[i].phase += p[i].freq * invSR
                    p[i].phase -= Double(Int(p[i].phase))

                    // Pan to stereo (constant-power)
                    let panAngle = Double((p[i].pan + 1) * 0.5) * .pi * 0.5
                    let gL = Float(cos(panAngle))
                    let gR = Float(sin(panAngle))
                    mixL += sample * gL
                    mixR += sample * gR
                }
            }
        }

        // Density compensation: 1/sqrt(rate/50) to prevent amplitude spikes
        let effectiveDensity = max(0.001, min(1, densityParam + densityModulation))
        let rate = densityToRate(effectiveDensity)
        let compensation = Float(1.0 / sqrt(max(1, rate / 50.0)))
        mixL *= compensation
        mixR *= compensation

        // Apply voice envelope and velocity
        let envVel = Float(envValue * velocity)
        mixL *= envVel
        mixR *= envVel

        // Per-voice warmth tanh (Rule 6)
        let drive = Float(0.3 + warmthParam * 1.2)
        mixL = tanh(mixL * drive) / drive
        mixR = tanh(mixR * drive) / drive

        return (mixL, mixR)
    }

    // MARK: - Grain Firing

    /// Fire a new grain: draw frequency, amplitude, pan from the probability landscape.
    private mutating func fireGrain(f0: Double, focus: Double, grain: Double,
                                     density: Double, sampleRate: Double) {
        // Find an inactive grain slot
        var slotIndex = -1
        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                for i in 0..<Self.grainCount {
                    if !p[i].active {
                        slotIndex = i
                        break
                    }
                }
            }
        }
        guard slotIndex >= 0 else { return }

        // Draw frequency from probability landscape
        let freq = drawFrequency(f0: f0, focus: focus, sampleRate: sampleRate)

        // Draw amplitude: slight random variation around a base
        let ampBase: Float = 0.15
        let ampVar = Float(xorshiftNorm()) * 0.05
        let amp = max(0.01, ampBase + ampVar)

        // Draw pan: centered with some spread, modulated by evolution
        let panBase = Float(centroidShift * 0.5)
        let panSpread = Float(xorshiftNorm()) * 0.4 * Float(1.0 - focus)
        let panVal = max(-1, min(1, panBase + panSpread + Float(panModulation * 0.3)))

        // Grain duration: maps 0–1 to 5ms–100ms
        let grainDurSec = 0.005 + grain * 0.095
        let grainDurSamples = max(1.0, grainDurSec * sampleRate)
        let envRate = Float(1.0 / grainDurSamples)

        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                p[slotIndex].phase = 0
                p[slotIndex].freq = freq
                p[slotIndex].amplitude = amp
                p[slotIndex].envelopePhase = 0
                p[slotIndex].envelopeRate = envRate
                p[slotIndex].pan = panVal
                p[slotIndex].active = true
            }
        }
    }

    /// Draw a frequency from the probability landscape.
    /// Blends weighted harmonic selection + Gaussian scatter + uniform noise.
    private mutating func drawFrequency(f0: Double, focus: Double, sampleRate: Double) -> Double {
        let nyquist = sampleRate * 0.5 - 100

        // Determine number of usable harmonics
        var numHarmonics = Self.harmonicCount
        for h in 1...Self.harmonicCount {
            if f0 * Double(h) >= nyquist {
                numHarmonics = h - 1
                break
            }
        }
        numHarmonics = max(1, numHarmonics)

        // Focus controls the blend between harmonic and noise
        // focus=1 → pure weighted harmonic
        // focus=0 → uniform random frequency
        let harmonicBlend = focus * focus  // quadratic for more dramatic control

        if xorshiftUnit() < harmonicBlend {
            // Draw from weighted harmonic series + small Gaussian scatter
            let harmonic = drawWeightedHarmonic(numHarmonics: numHarmonics)
            let harmonicFreq = f0 * Double(harmonic)

            // Add Gaussian scatter proportional to (1-focus)
            let scatter = gaussianRandom() * f0 * 0.05 * (1.0 - focus)
            let centroidOffset = centroidShift * f0 * 0.5

            return max(20, min(nyquist, harmonicFreq + scatter + centroidOffset))
        } else {
            // Uniform random in audible range around f0
            let lowBound = max(20, f0 * 0.5)
            let highBound = min(nyquist, f0 * Double(numHarmonics))
            let range = highBound - lowBound
            return lowBound + xorshiftUnit() * range
        }
    }

    /// Draw a harmonic number using cumulative distribution sampling.
    private mutating func drawWeightedHarmonic(numHarmonics: Int) -> Int {
        // Build cumulative weights
        var totalWeight = 0.0
        withUnsafePointer(to: &harmonicWeights) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: Self.harmonicCount) { p in
                for i in 0..<numHarmonics {
                    totalWeight += p[i]
                }
            }
        }

        guard totalWeight > 0 else { return 1 }

        let target = xorshiftUnit() * totalWeight
        var cumulative = 0.0
        var selected = 1

        withUnsafePointer(to: &harmonicWeights) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: Self.harmonicCount) { p in
                for i in 0..<numHarmonics {
                    cumulative += p[i]
                    if cumulative >= target {
                        selected = i + 1
                        break
                    }
                }
            }
        }

        return selected
    }

    // MARK: - Poisson Clock

    /// Schedule the next grain using exponential random inter-arrival time.
    private mutating func scheduleNextGrain(density: Double, sampleRate: Double) {
        let rate = densityToRate(density)
        // Exponential random: -ln(U) / rate, where U is uniform (0,1]
        let u = max(1e-10, xorshiftUnit())
        let intervalSec = -log(u) / rate
        let intervalSamples = max(1, Int(intervalSec * sampleRate))
        samplesUntilNextGrain = intervalSamples
    }

    /// Map density 0–1 to grain rate: 0.5 * pow(8000, density) grains/sec.
    func densityToRate(_ density: Double) -> Double {
        return 0.5 * pow(8000.0, density)
    }

    // MARK: - Evolution

    /// Advance random walks on modulation accumulators (control-rate).
    private mutating func advanceEvolution(sampleRate: Double) {
        let evolve = evolveParam
        let blockDur = Double(Self.controlBlockSize) / sampleRate

        // Random walk step size scales with evolve parameter
        let step = evolve * blockDur * 2.0

        focusModulation += evolveXorshiftNorm() * step * 0.3
        focusModulation *= 0.995  // decay toward zero
        focusModulation = max(-0.3, min(0.3, focusModulation))

        densityModulation += evolveXorshiftNorm() * step * 0.2
        densityModulation *= 0.995
        densityModulation = max(-0.2, min(0.2, densityModulation))

        centroidShift += evolveXorshiftNorm() * step * 0.4
        centroidShift *= 0.99
        centroidShift = max(-1.0, min(1.0, centroidShift))

        panModulation += evolveXorshiftNorm() * step * 0.3
        panModulation *= 0.99
        panModulation = max(-0.5, min(0.5, panModulation))

        grainSizeModulation += evolveXorshiftNorm() * step * 0.2
        grainSizeModulation *= 0.995
        grainSizeModulation = max(-0.2, min(0.2, grainSizeModulation))
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

    // MARK: - Noise Generation

    /// Xorshift RNG for grain drawing. Returns -1 to +1.
    private mutating func xorshiftNorm() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    /// Xorshift RNG for grain drawing. Returns 0 to 1.
    private mutating func xorshiftUnit() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(noiseState) / Double(UInt32.max)
    }

    /// Separate xorshift for evolution (Rule 10: decorrelated streams).
    private mutating func evolveXorshiftNorm() -> Double {
        evolveNoiseState ^= evolveNoiseState << 13
        evolveNoiseState ^= evolveNoiseState >> 17
        evolveNoiseState ^= evolveNoiseState << 5
        return Double(Int32(bitPattern: evolveNoiseState)) / Double(Int32.max)
    }

    /// Box-Muller Gaussian using two uniform samples from xorshift.
    private mutating func gaussianRandom() -> Double {
        let u1 = max(1e-10, xorshiftUnit())
        let u2 = xorshiftUnit()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }

    /// Set evolution noise seed (called by manager for per-voice decorrelation).
    mutating func setEvolveSeed(_ seed: UInt32) {
        evolveNoiseState = seed
    }
}

// MARK: - sinf/cosf helpers (avoid Foundation overhead on audio thread)
@inline(__always)
private func sinf(_ x: Float) -> Float {
    return Float(sin(Double(x)))
}

@inline(__always)
private func cosf(_ x: Float) -> Float {
    return Float(cos(Double(x)))
}
