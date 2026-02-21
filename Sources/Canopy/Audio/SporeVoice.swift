import Foundation

/// Per-grain state for the SPORE engine's 64-grain pool.
/// Each grain has a waveform, frequency sweep, and shaped envelope.
struct SporeGrain {
    var phase: Double = 0           // oscillator phase
    var freq: Double = 0            // grain start frequency in Hz
    var freqEnd: Double = 0         // grain end frequency for chirp interpolation
    var amplitude: Float = 0        // grain amplitude
    var envelopePhase: Float = 0    // 0–1 position in grain envelope
    var envelopeRate: Float = 0     // increment per sample
    var pan: Float = 0              // -1 to +1
    var formValue: Float = 0        // per-grain waveform selector (0–1)
    var fmModPhase: Double = 0      // FM modulator phase for form > 0.6
    var active: Bool = false        // is this grain sounding?
}

/// Per-voice DSP for the SPORE engine.
/// 64 grains fired by a Poisson clock. Each grain's frequency is drawn from a
/// 3-mode probability landscape (free spectrum / inharmonic / harmonic).
/// Grains morph through waveforms (sine→tri→saw→FM→noise) and can chirp.
///
/// Signal chain per grain:
///   waveform(phase, form) → pitch sweep (chirp) → shaped envelope → pan → voice sum
///   → SVF lowpass → warmth tanh → voice envelope → output
///
/// CRITICAL: Grains and harmonic weights stored as tuples, NOT arrays.
/// Tuple storage is fully inline (zero heap, zero refcount, zero CoW).
struct SporeVoice {
    // MARK: - Constants

    static let grainCount = 64
    static let controlBlockSize = 64
    static let harmonicCount = 64
    static let gaussianTableSize = 1024

    /// 16 inharmonic frequency ratios (Bessel zeros, irrational numbers).
    /// These produce bell/metal/glass textures when used as frequency multipliers.
    static let inharmonicRatios: (Double, Double, Double, Double, Double, Double, Double, Double,
                                   Double, Double, Double, Double, Double, Double, Double, Double)
        = (1.414, 1.618, 1.732, 2.236, 2.449, 2.646, 3.162, 3.317,
           3.606, 3.832, 4.123, 4.359, 4.796, 5.292, 5.831, 6.415)

    /// Per-voice detune ratios for natural chorus/width.
    static let detuneRatios: (Double, Double, Double, Double, Double, Double, Double, Double)
        = (1.0, 1.002, 0.998, 1.004, 0.996, 1.001, 0.999, 1.003)

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
    var formParam: Double = 0.0
    var formTarget: Double = 0.0
    var focusParam: Double = 0.5
    var focusTarget: Double = 0.5
    var sizeParam: Double = 0.4
    var sizeTarget: Double = 0.4
    var chirpParam: Double = 0.0
    var chirpTarget: Double = 0.0
    var evolveParam: Double = 0.3
    var evolveTarget: Double = 0.3
    var snapParam: Double = 0.0
    var snapTarget: Double = 0.0
    var syncParam: Bool = false
    var filterParam: Double = 1.0
    var filterTarget: Double = 1.0
    var filterModeParam: Int = 0       // 0=LP, 1=BP, 2=HP
    var widthParam: Double = 0.5
    var widthTarget: Double = 0.5
    var attackParam: Double = 0.01
    var attackTarget: Double = 0.01
    var decayParam: Double = 0.3
    var decayTarget: Double = 0.3
    var warmthParam: Double = 0.3
    var warmthTarget: Double = 0.3

    // MARK: - Function generator state

    var funcShapeRaw: Int = 0           // 0=off, 1=sine, 2=tri, 3=rampDown, 4=rampUp, 5=square, 6=S&H
    var funcAmountParam: Double = 0.0
    var funcAmountTarget: Double = 0.0
    var funcRateParam: Double = 0.3     // 0–1: maps to 0.05–10 Hz
    var funcSyncEnabled: Bool = false
    var funcDivBeats: Double = 4.0
    var bpm: Double = 120
    var funcPhase: Double = 0           // free-running accumulator
    var funcLevel: Double = 1.0         // smoothed output
    var funcSHValue: Double = 1.0
    var funcPrevPhase: Double = 0

    // MARK: - Scale state (for SNAP pitch quantization)

    var scaleIntervals: (Int, Int, Int, Int, Int, Int, Int, Int,
                         Int, Int, Int, Int) = (0, 2, 4, 5, 7, 9, 11, 0, 0, 0, 0, 0)
    var scaleCount: Int = 7
    var rootSemitone: Int = 0

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

    /// Per-voice detune ratio (set by manager at init).
    var detuneRatio: Double = 1.0

    // MARK: - Poisson clock state

    private var samplesUntilNextGrain: Int = 0

    // MARK: - Evolution state (random walks, clamped)

    private var focusModulation: Double = 0
    private var densityModulation: Double = 0
    private var centroidShift: Double = 0
    private var panModulation: Double = 0
    private var grainSizeModulation: Double = 0
    private var formModulation: Double = 0
    private var chirpModulation: Double = 0
    private var filterModulation: Double = 0

    // MARK: - SVF filter state (Chamberlin per-voice lowpass)

    private var svfLowL: Double = 0
    private var svfBandL: Double = 0
    private var svfLowR: Double = 0
    private var svfBandR: Double = 0

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
        self.frequency = MIDIUtilities.frequency(forNote: pitch) * detuneRatio
        self.velocity = velocity
        self.isActive = true
        self.envPhase = 1
        self.envValue = 0
        self.cachedSampleRate = sampleRate

        // ATK/DCY voice envelope: attack 1ms–500ms, decay 50ms–5000ms (exponential)
        let atkNorm = max(0, min(1, attackParam))
        let dcyNorm = max(0, min(1, decayParam))
        let attackSec = 0.001 * pow(500.0, atkNorm)
        let releaseSec = 0.05 * pow(100.0, dcyNorm)
        self.attackRate = 1.0 / max(1, attackSec * sampleRate)
        self.releaseRate = 1.0 / max(1, releaseSec * sampleRate)

        self.controlCounter = 0
        self.pendingPitch = -1
        self.samplesUntilNextGrain = 0

        // Reset evolution
        focusModulation = 0
        densityModulation = 0
        centroidShift = 0
        panModulation = 0
        grainSizeModulation = 0
        formModulation = 0
        chirpModulation = 0
        filterModulation = 0

        // SVF filter state: do NOT hard-reset. The steal-fade already brought
        // the signal to near-zero, so filter state is negligible. Resetting
        // snaps accumulated resonance/DC to zero → audible click.

        // Reset func gen phase (but smooth funcLevel — no discontinuity)
        funcPhase = 0
        funcPrevPhase = 0
        funcSHValue = 1.0

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
            // ATK/DCY voice envelope decay: 50ms–5000ms
            let dcyNorm = max(0, min(1, decayParam))
            let releaseSec = 0.05 * pow(100.0, dcyNorm)
            releaseRate = 1.0 / max(1, releaseSec * sampleRate)
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

        // Smooth control parameters (per-sample, coeff 0.001)
        let paramSmooth = 0.001
        densityParam += (densityTarget - densityParam) * paramSmooth
        formParam += (formTarget - formParam) * paramSmooth
        focusParam += (focusTarget - focusParam) * paramSmooth
        snapParam += (snapTarget - snapParam) * paramSmooth
        sizeParam += (sizeTarget - sizeParam) * paramSmooth
        chirpParam += (chirpTarget - chirpParam) * paramSmooth
        evolveParam += (evolveTarget - evolveParam) * paramSmooth
        filterParam += (filterTarget - filterParam) * paramSmooth
        widthParam += (widthTarget - widthParam) * paramSmooth
        attackParam += (attackTarget - attackParam) * paramSmooth
        decayParam += (decayTarget - decayParam) * paramSmooth
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
            let effectiveSize = max(0, min(1, sizeParam + grainSizeModulation))
            let effectiveForm = max(0, min(1, formParam + formModulation))
            let effectiveChirp = max(-1, min(1, chirpParam + chirpModulation))
            fireGrain(f0: frequency, focus: effectiveFocus, size: effectiveSize,
                      density: effectiveDensity, form: effectiveForm,
                      chirp: effectiveChirp, sampleRate: sampleRate)
            scheduleNextGrain(density: effectiveDensity, sampleRate: sampleRate)
        }

        // Render all active grains → stereo
        var mixL: Float = 0
        var mixR: Float = 0
        let invSR = 1.0 / sampleRate
        let nyquist = sampleRate * 0.5 - 100
        let effectiveSizeForEnv = Float(max(0, min(1, sizeParam + grainSizeModulation)))

        // Copy noise state out to avoid overlapping access (self.noiseState vs self.grains)
        var localNoiseState = noiseState

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

                    // Chirp: interpolate frequency from start to end
                    let t = Double(p[i].envelopePhase)
                    let currentFreq = p[i].freq * pow(p[i].freqEnd / max(1.0, p[i].freq), t)

                    // Nyquist guard
                    guard currentFreq < nyquist && currentFreq > 20 else {
                        p[i].active = false
                        continue
                    }

                    // SIZE-dependent grain envelope shape
                    let envVal = SporeVoice.grainEnvelope(phase: p[i].envelopePhase, size: effectiveSizeForEnv)

                    // Waveform generator (continuous morph based on formValue)
                    let sample = SporeVoice.renderGrainWaveform(grain: &p[i], invSR: invSR, currentFreq: currentFreq, noiseState: &localNoiseState) * p[i].amplitude * envVal

                    // Advance phase
                    p[i].phase += currentFreq * invSR
                    p[i].phase -= Double(Int(p[i].phase))

                    // Advance FM modulator phase (for FM waveform region)
                    p[i].fmModPhase += currentFreq * 1.414 * invSR
                    p[i].fmModPhase -= Double(Int(p[i].fmModPhase))

                    // Pan to stereo (constant-power)
                    let panAngle = Double((p[i].pan + 1) * 0.5) * .pi * 0.5
                    let gL = Float(cos(panAngle))
                    let gR = Float(sin(panAngle))
                    mixL += sample * gL
                    mixR += sample * gR
                }
            }
        }

        // Copy noise state back
        noiseState = localNoiseState

        // Density compensation: 1/sqrt(rate/50) to prevent amplitude spikes
        let effectiveDensity = max(0.001, min(1, densityParam + densityModulation))
        let rate = densityToRate(effectiveDensity)
        let compensation = Float(1.0 / sqrt(max(1, rate / 50.0)))
        mixL *= compensation
        mixR *= compensation

        // Function generator amplitude modulation (before SVF filter)
        let funcGain = computeFuncGen(sampleRate: sampleRate)
        mixL *= Float(funcGain)
        mixR *= Float(funcGain)

        // Per-voice SVF filter (LP/BP/HP selectable)
        let effectiveFilter = max(0, min(1, filterParam + filterModulation))
        if effectiveFilter < 0.99 {
            let cutoff = 200.0 * pow(80.0, effectiveFilter)  // 200Hz to 16kHz
            let effectiveForm = max(0, min(1, formParam + formModulation))
            let resonance = 0.5 + effectiveForm * 1.5  // couples with FORM
            let f = 2.0 * sin(.pi * cutoff / sampleRate)
            let q = 1.0 / max(0.5, resonance)

            // Left channel
            svfLowL += f * svfBandL
            let highL = Double(mixL) - svfLowL - q * svfBandL
            svfBandL += f * highL

            // Right channel
            svfLowR += f * svfBandR
            let highR = Double(mixR) - svfLowR - q * svfBandR
            svfBandR += f * highR

            // Select filter output by mode
            switch filterModeParam {
            case 1: // Bandpass
                mixL = Float(svfBandL)
                mixR = Float(svfBandR)
            case 2: // Highpass
                mixL = Float(highL)
                mixR = Float(highR)
            default: // Lowpass
                mixL = Float(svfLowL)
                mixR = Float(svfLowR)
            }
        }

        // Apply voice envelope and velocity
        let envVel = Float(envValue * velocity)
        mixL *= envVel
        mixR *= envVel

        // Per-voice warmth tanh
        let drive = Float(0.3 + warmthParam * 1.2)
        mixL = tanhf(mixL * drive) / drive
        mixR = tanhf(mixR * drive) / drive

        return (mixL, mixR)
    }

    // MARK: - Waveform Generator

    /// Render a single sample for a grain based on its formValue.
    /// Continuous morph: 0=sine, 0.25=tri, 0.5=saw, 0.75=FM, 1.0=noise.
    /// Static to avoid overlapping access when called from within grain tuple closure.
    @inline(__always)
    private static func renderGrainWaveform(grain: inout SporeGrain, invSR: Double, currentFreq: Double, noiseState: inout UInt32) -> Float {
        let form = grain.formValue

        if form < 0.2 {
            // Pure sine
            return sinf(Float(2.0 * .pi * grain.phase))
        } else if form < 0.4 {
            // Sine → Triangle crossfade
            let blend = (form - 0.2) / 0.2
            let sine = sinf(Float(2.0 * .pi * grain.phase))
            let tri = Float(4.0 * abs(grain.phase - 0.5) - 1.0)
            return sine * (1.0 - blend) + tri * blend
        } else if form < 0.6 {
            // Triangle → Saw crossfade (polyBLEP anti-aliased)
            let blend = (form - 0.4) / 0.2
            let tri = Float(4.0 * abs(grain.phase - 0.5) - 1.0)
            var saw = Float(2.0 * grain.phase - 1.0)
            // PolyBLEP anti-aliasing
            let dt = Float(currentFreq * invSR)
            let t = Float(grain.phase)
            if t < dt {
                let x = t / dt
                saw -= x + x - x * x - 1.0
            } else if t > 1.0 - dt {
                let x = (t - 1.0 + dt) / dt
                saw -= x * x + x + x - 1.0
            }
            return tri * (1.0 - blend) + saw * blend
        } else if form < 0.8 {
            // Saw → FM crossfade
            let blend = (form - 0.6) / 0.2
            var saw = Float(2.0 * grain.phase - 1.0)
            let dt = Float(currentFreq * invSR)
            let t = Float(grain.phase)
            if t < dt {
                let x = t / dt
                saw -= x + x - x * x - 1.0
            } else if t > 1.0 - dt {
                let x = (t - 1.0 + dt) / dt
                saw -= x * x + x + x - 1.0
            }
            // FM: carrier + modulator at ratio 1.414 (metallic)
            let fmIndex = 2.0 + blend * 6.0  // index 2–8
            let fm = sinf(Float(2.0 * .pi * grain.phase + Double(fmIndex) * sin(2.0 * .pi * grain.fmModPhase)))
            return saw * (1.0 - blend) + fm * blend
        } else {
            // FM → Noise crossfade
            let blend = (form - 0.8) / 0.2
            let fmIndex: Float = 8.0
            let fm = sinf(Float(2.0 * .pi * grain.phase + Double(fmIndex) * sin(2.0 * .pi * grain.fmModPhase)))
            // Noise via xorshift (using passed-in state to avoid overlapping access)
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 17
            noiseState ^= noiseState << 5
            let noise = Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
            return fm * (1.0 - blend) + noise * blend
        }
    }

    // MARK: - Grain Envelope Shape

    /// SIZE-dependent grain envelope.
    /// Short: punchy (5% attack, 60% release).
    /// Medium: symmetric raised cosine.
    /// Long: slow attack (20%), plateau (60%), decay (20%).
    /// Static to avoid overlapping access when called from within grain tuple closure.
    @inline(__always)
    private static func grainEnvelope(phase: Float, size: Float) -> Float {
        if size < 0.3 {
            // Punchy: fast attack, long release
            let attackEnd: Float = 0.05
            let releaseStart: Float = 0.4
            if phase < attackEnd {
                return phase / attackEnd
            } else if phase < releaseStart {
                return 1.0
            } else {
                let relPhase = (phase - releaseStart) / (1.0 - releaseStart)
                return max(0, 1.0 - relPhase * relPhase)
            }
        } else if size > 0.7 {
            // Long: slow attack, plateau, moderate decay
            let attackEnd: Float = 0.2
            let decayStart: Float = 0.8
            if phase < attackEnd {
                let t = phase / attackEnd
                return 0.5 * (1.0 - cosf(.pi * t))
            } else if phase < decayStart {
                return 1.0
            } else {
                let t = (phase - decayStart) / (1.0 - decayStart)
                return 0.5 * (1.0 + cosf(.pi * t))
            }
        } else {
            // Medium: symmetric raised cosine
            return 0.5 * (1.0 - cosf(2.0 * .pi * phase))
        }
    }

    // MARK: - Grain Firing

    /// Fire a new grain: draw frequency, amplitude, pan, waveform from the probability landscape.
    private mutating func fireGrain(f0: Double, focus: Double, size: Double,
                                     density: Double, form: Double,
                                     chirp: Double, sampleRate: Double) {
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

        // Draw frequency from probability landscape (3-mode system)
        let freq = drawFrequency(f0: f0, focus: focus, sampleRate: sampleRate)

        // Chirp: compute end frequency
        let freqEnd = freq * pow(2.0, -chirp * 2.0)

        // Draw per-grain waveform (Gaussian scatter around FORM control)
        let formScatter = gaussianRandom() * 0.15
        let grainForm = max(0, min(1, form + formScatter))

        // Draw amplitude: focus-dependent distribution
        let amp: Float
        if focus > 0.6 {
            // Focused: consistent amplitude
            let ampBase: Float = 0.23
            let ampVar = Float(xorshiftNorm()) * 0.05
            amp = max(0.01, ampBase + ampVar)
        } else {
            // Unfocused: wild variation
            let ampBase: Float = 0.08
            let ampVar = Float(abs(xorshiftNorm())) * 0.25
            amp = max(0.01, ampBase + ampVar)
        }

        // Draw pan: WIDTH controls stereo spread independently from focus
        let panBase = Float(centroidShift * 0.5)
        let panSpread = Float(xorshiftNorm()) * 0.8 * Float(widthParam)
        let panVal = max(-1, min(1, panBase + panSpread + Float(panModulation * 0.3)))

        // Grain duration: maps 0–1 to 1ms–2000ms (exponential)
        let grainDurSec = 0.001 * pow(2000.0, size)
        let grainDurSamples = max(1.0, grainDurSec * sampleRate)
        let envRate = Float(1.0 / grainDurSamples)

        withUnsafeMutablePointer(to: &grains) { ptr in
            ptr.withMemoryRebound(to: SporeGrain.self, capacity: Self.grainCount) { p in
                p[slotIndex].phase = 0
                p[slotIndex].freq = freq
                p[slotIndex].freqEnd = freqEnd
                p[slotIndex].amplitude = amp
                p[slotIndex].envelopePhase = 0
                p[slotIndex].envelopeRate = envRate
                p[slotIndex].pan = panVal
                p[slotIndex].formValue = Float(grainForm)
                p[slotIndex].fmModPhase = 0
                p[slotIndex].active = true
            }
        }
    }

    /// Draw a frequency from the 3-mode probability landscape.
    /// FOCS > 0.7: harmonic series + tight scatter.
    /// FOCS 0.3–0.7: inharmonic blend (bell/metal/glass).
    /// FOCS < 0.3: free spectrum (pink-weighted 20Hz–16kHz).
    /// After drawing, apply SNAP pitch quantization toward scale degrees.
    private mutating func drawFrequency(f0: Double, focus: Double, sampleRate: Double) -> Double {
        let nyquist = sampleRate * 0.5 - 100
        var freq: Double

        if focus > 0.7 {
            // HARMONIC MODE: weighted harmonic series + tight scatter (2% of f0)
            var numHarmonics = Self.harmonicCount
            for h in 1...Self.harmonicCount {
                if f0 * Double(h) >= nyquist {
                    numHarmonics = h - 1
                    break
                }
            }
            numHarmonics = max(1, numHarmonics)

            let harmonic = drawWeightedHarmonic(numHarmonics: numHarmonics)
            let harmonicFreq = f0 * Double(harmonic)
            let scatter = gaussianRandom() * f0 * 0.02
            let centroidOffset = centroidShift * f0 * 0.5
            freq = max(20, min(nyquist, harmonicFreq + scatter + centroidOffset))

        } else if focus >= 0.3 {
            // INHARMONIC MODE: blend between harmonics and inharmonic ratios
            let inharmonicBlend = 1.0 - ((focus - 0.3) / 0.4)  // 0 at focus=0.7, 1 at focus=0.3

            if xorshiftUnit() < inharmonicBlend {
                // Draw from inharmonic ratios
                let ratio = drawInharmonicRatio()
                // Random octave shift: 0.5x, 1x, 2x, 4x
                let octaveShift = pow(2.0, Double(Int(xorshiftUnit() * 4.0)) - 1.0)
                let f = f0 * ratio * octaveShift
                let scatter = gaussianRandom() * f0 * 0.03
                freq = max(20, min(nyquist, f + scatter))
            } else {
                // Draw from harmonics
                var numHarmonics = Self.harmonicCount
                for h in 1...Self.harmonicCount {
                    if f0 * Double(h) >= nyquist {
                        numHarmonics = h - 1
                        break
                    }
                }
                numHarmonics = max(1, numHarmonics)
                let harmonic = drawWeightedHarmonic(numHarmonics: numHarmonics)
                let harmonicFreq = f0 * Double(harmonic)
                let scatter = gaussianRandom() * f0 * 0.05
                freq = max(20, min(nyquist, harmonicFreq + scatter))
            }

        } else {
            // FREE SPECTRUM MODE: pink-weighted draw across 20Hz–16kHz
            // Log-uniform = equal probability per octave
            let logLow = log2(20.0)
            let logHigh = log2(min(16000.0, nyquist))
            let logFreq = logLow + xorshiftUnit() * (logHigh - logLow)
            freq = pow(2.0, logFreq)

            // Gentle attraction toward f0's region proportional to remaining focus
            let attraction = focus / 0.3  // 0 at focus=0, 1 at focus=0.3
            if attraction > 0 {
                let pull = (f0 - freq) * attraction * 0.3
                freq += pull
            }

            freq = max(20, min(nyquist, freq))
        }

        // SNAP: pitch quantization toward nearest scale degree
        if snapParam > 0.01 {
            let snappedFreq = nearestScaleFreq(freq, f0: f0)
            freq = freq + (snappedFreq - freq) * snapParam
        }

        return freq
    }

    /// Draw an inharmonic ratio from the 16-element tuple.
    private mutating func drawInharmonicRatio() -> Double {
        let index = Int(xorshiftUnit() * 16.0) & 15
        var ratio = 1.0
        withUnsafePointer(to: Self.inharmonicRatios) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: 16) { p in
                ratio = p[index]
            }
        }
        return ratio
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

    /// Schedule the next grain. Poisson (async) or fixed interval (sync).
    private mutating func scheduleNextGrain(density: Double, sampleRate: Double) {
        let rate = densityToRate(density)
        if syncParam {
            // SYNC: fixed interval = sampleRate / rate
            let intervalSamples = max(1, Int(sampleRate / rate))
            samplesUntilNextGrain = intervalSamples
        } else {
            // Poisson: exponential random inter-arrival time
            let u = max(1e-10, xorshiftUnit())
            let intervalSec = -log(u) / rate
            let intervalSamples = max(1, Int(intervalSec * sampleRate))
            samplesUntilNextGrain = intervalSamples
        }
    }

    /// Map density 0–1 to grain rate: 0.2 * pow(60000, density) grains/sec.
    /// Gives range ~0.2 to ~12000 grains/sec.
    func densityToRate(_ density: Double) -> Double {
        return 0.2 * pow(60000.0, density)
    }

    // MARK: - Evolution

    /// Advance random walks on modulation accumulators (control-rate).
    /// Modulates ALL dimensions including form, size, chirp, filter.
    private mutating func advanceEvolution(sampleRate: Double) {
        let evolve = evolveParam
        let blockDur = Double(Self.controlBlockSize) / sampleRate

        // Random walk step size scales with evolve parameter
        let step = evolve * blockDur * 2.0

        focusModulation += evolveXorshiftNorm() * step * 0.4
        focusModulation *= 0.995
        focusModulation = max(-0.4, min(0.4, focusModulation))

        densityModulation += evolveXorshiftNorm() * step * 0.25
        densityModulation *= 0.995
        densityModulation = max(-0.25, min(0.25, densityModulation))

        centroidShift += evolveXorshiftNorm() * step * 0.4
        centroidShift *= 0.99
        centroidShift = max(-1.0, min(1.0, centroidShift))

        panModulation += evolveXorshiftNorm() * step * 0.3
        panModulation *= 0.99
        panModulation = max(-0.5, min(0.5, panModulation))

        grainSizeModulation += evolveXorshiftNorm() * step * 0.2
        grainSizeModulation *= 0.995
        grainSizeModulation = max(-0.2, min(0.2, grainSizeModulation))

        formModulation += evolveXorshiftNorm() * step * 0.3
        formModulation *= 0.995
        formModulation = max(-0.3, min(0.3, formModulation))

        chirpModulation += evolveXorshiftNorm() * step * 0.3
        chirpModulation *= 0.995
        chirpModulation = max(-0.3, min(0.3, chirpModulation))

        filterModulation += evolveXorshiftNorm() * step * 0.2
        filterModulation *= 0.995
        filterModulation = max(-0.2, min(0.2, filterModulation))
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

    /// Separate xorshift for evolution (decorrelated streams).
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

    /// Set the scale for pitch quantization (SNAP).
    mutating func setScale(rootSemitone: Int, intervals: [Int]) {
        self.rootSemitone = rootSemitone
        let count = min(12, intervals.count)
        self.scaleCount = count
        withUnsafeMutablePointer(to: &scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                for i in 0..<12 {
                    p[i] = i < count ? intervals[i] : 0
                }
            }
        }
    }

    /// Snap a frequency to the nearest scale degree.
    /// Works in MIDI-space: convert to MIDI, find nearest scale pitch, convert back.
    private func nearestScaleFreq(_ freq: Double, f0: Double) -> Double {
        guard scaleCount > 0 else { return freq }

        // freq → MIDI note number (continuous)
        let midi = 12.0 * log2(freq / 440.0) + 69.0

        // Find nearest scale degree
        var bestDist = 1000.0
        var bestMidi = midi

        withUnsafePointer(to: scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                // Search across several octaves centered on the note
                let centerOctave = Int(midi / 12.0)
                for oct in (centerOctave - 1)...(centerOctave + 1) {
                    for i in 0..<scaleCount {
                        let scaleMidi = Double(rootSemitone + p[i] + oct * 12)
                        let dist = abs(midi - scaleMidi)
                        if dist < bestDist {
                            bestDist = dist
                            bestMidi = scaleMidi
                        }
                    }
                }
            }
        }

        // MIDI → frequency
        return 440.0 * pow(2.0, (bestMidi - 69.0) / 12.0)
    }

    // MARK: - Function Generator

    /// Compute function generator amplitude modulation.
    /// Free-running or tempo-synced, same shapes as TideVoice.
    private mutating func computeFuncGen(sampleRate: Double) -> Double {
        guard funcShapeRaw != 0 else { return 1.0 }

        // Smooth amount
        funcAmountParam += (funcAmountTarget - funcAmountParam) * 0.001

        // Advance phase
        let rateHz: Double
        if funcSyncEnabled {
            // Tempo-synced: one cycle per funcDivBeats beats
            let beatsPerSec = bpm / 60.0
            rateHz = beatsPerSec / max(0.25, funcDivBeats)
        } else {
            // Free: map 0–1 to 0.05–10 Hz (exponential)
            rateHz = 0.05 * pow(200.0, funcRateParam)
        }

        funcPhase += rateHz / sampleRate
        funcPhase -= Double(Int(funcPhase)) // wrap to 0–1

        let phase = funcPhase

        // Generate waveform value in 0–1 range
        let waveValue: Double
        switch funcShapeRaw {
        case 1: // sine
            waveValue = 0.5 + 0.5 * sin(2.0 * .pi * phase)
        case 2: // triangle
            waveValue = phase < 0.5 ? phase * 2.0 : 2.0 - phase * 2.0
        case 3: // ramp down
            waveValue = 1.0 - phase
        case 4: // ramp up
            waveValue = phase
        case 5: // square
            waveValue = phase < 0.5 ? 1.0 : 0.0
        case 6: // S&H
            if phase < funcPrevPhase {
                // Phase wrapped — refresh held value from xorshift
                evolveNoiseState ^= evolveNoiseState << 13
                evolveNoiseState ^= evolveNoiseState >> 17
                evolveNoiseState ^= evolveNoiseState << 5
                funcSHValue = Double(evolveNoiseState & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
            }
            funcPrevPhase = phase
            waveValue = funcSHValue
        default:
            waveValue = 1.0
        }

        // gain = 1 - amount + amount × waveValue  → range [1-amount, 1]
        let target = 1.0 - funcAmountParam + funcAmountParam * waveValue

        // Smooth output (~0.3ms anti-click)
        funcLevel += (target - funcLevel) * 0.05
        return funcLevel
    }
}

// MARK: - sinf/cosf/tanhf helpers (avoid Foundation overhead on audio thread)
@inline(__always)
private func sinf(_ x: Float) -> Float {
    return Float(sin(Double(x)))
}

@inline(__always)
private func cosf(_ x: Float) -> Float {
    return Float(cos(Double(x)))
}

@inline(__always)
private func tanhf(_ x: Float) -> Float {
    return Float(tanh(Double(x)))
}
