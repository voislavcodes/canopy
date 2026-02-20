import Foundation

/// State-variable filter (SVF) bandpass state — 2 integrator variables.
/// Inline struct, zero heap allocation.
struct SVFBandState {
    var ic1eq: Double = 0
    var ic2eq: Double = 0
}

/// Per-voice DSP for the TIDE engine.
/// Rich oscillator → 16 SVF bandpass filters → VCA per band → stereo sum.
/// Band levels are cycled by an internal pattern sequencer.
///
/// CRITICAL: All tuple storage — no arrays, no heap, no CoW on audio thread.
struct TideVoice {
    // MARK: - Constants

    static let bandCount = 16
    static let controlBlockSize = 16 // update band targets every 16 samples

    /// Fixed center frequencies for 16 bands, log-spaced from ~75Hz to ~16kHz.
    static let bandFrequencies: (Double, Double, Double, Double, Double, Double, Double, Double,
                                 Double, Double, Double, Double, Double, Double, Double, Double)
        = (75, 120, 190, 300, 475, 750, 1200, 1900,
           3000, 4750, 7500, 10000, 11500, 13000, 14500, 16000)

    // MARK: - Oscillator State

    var phase: Double = 0
    var frequency: Double = 440
    var velocity: Double = 0
    var isActive: Bool = false

    // MARK: - Current parameter (oscillator richness)

    var currentParam: Double = 0.4
    var currentTarget: Double = 0.4

    // MARK: - Tide engine state

    var patternIndex: Int = 0       // which pattern (0–15)
    var position: Double = 0        // fractional position through pattern frames
    var rateParam: Double = 0.3
    var rateTarget: Double = 0.3
    var depthParam: Double = 0.6
    var depthTarget: Double = 0.6
    var warmthParam: Double = 0.3
    var warmthTarget: Double = 0.3

    // Rate sync state
    var rateSyncEnabled: Bool = false
    var rateDivisionBeats: Double = 4.0  // beats per full pattern cycle (when synced)
    var bpm: Double = 120

    // Function generator state
    var funcShapeRaw: Int = 0           // 0=off, 1=sine, 2=tri, 3=rampDown, 4=rampUp, 5=square, 6=sAndH
    var funcAmountTarget: Double = 0.0
    var funcAmount: Double = 0.0
    var funcSkewTarget: Double = 0.5
    var funcSkew: Double = 0.5
    var funcCycles: Int = 1
    var funcLevel: Double = 1.0         // smoothed output
    var funcSHValue: Double = 1.0       // S&H held value
    var funcPrevPhase: Double = 0       // for S&H wrap detection

    // MARK: - SVF filter states (16 bands as inline tuple)

    var filterStates: (SVFBandState, SVFBandState, SVFBandState, SVFBandState,
                       SVFBandState, SVFBandState, SVFBandState, SVFBandState,
                       SVFBandState, SVFBandState, SVFBandState, SVFBandState,
                       SVFBandState, SVFBandState, SVFBandState, SVFBandState)

    // MARK: - Band VCA levels (current, smoothed per-sample)

    var bandLevels: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)

    // Band level targets (set at control rate)
    var bandTargets: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)

    // Band Q values (set at control rate)
    var bandQs: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)

    // MARK: - Envelope (same state machine as FlowVoice)

    var envelopeLevel: Float = 0
    private var envPhase: Int = 0        // 0=idle, 1=attack, 2=sustain, 3=release, 4=steal-fade
    private var envValue: Double = 0
    private var attackRate: Double = 0
    private var releaseRate: Double = 0

    // Steal-fade state
    private var pendingPitch: Int = -1
    private var pendingVelocity: Double = 0
    private var stealFadeRate: Double = 0
    private var cachedSampleRate: Double = 44100

    // MARK: - Control-rate state

    private var controlCounter: Int = 0

    // Noise state (xorshift RNG) for chaos patterns + Current noise layer
    var noiseState: UInt32 = 12345

    // Cached pattern frames pointer (nil for chaos)
    private var cachedFrames: [TideFrame]?
    private var cachedFrameCount: Int = 0

    // MARK: - Init

    init() {
        let s = SVFBandState()
        filterStates = (s, s, s, s, s, s, s, s, s, s, s, s, s, s, s, s)
        bandLevels = (0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
                      0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
        bandTargets = (0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
                       0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
        bandQs = (2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5,
                  2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5)
        cachedFrames = TidePatterns.frames(for: 0)
        cachedFrameCount = cachedFrames?.count ?? 1
    }

    // MARK: - Note Control

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
        self.attackRate = 1.0 / max(1, 0.005 * sampleRate)
        self.releaseRate = 1.0 / max(1, 0.15 * sampleRate)
        self.controlCounter = 0
        self.pendingPitch = -1
        self.phase = 0
        // Don't reset position — let tide continue from where it was for organic feel
    }

    mutating func release(sampleRate: Double) {
        if envPhase != 0 {
            envPhase = 3
            releaseRate = 1.0 / max(1, 0.15 * sampleRate)
        }
    }

    mutating func kill() {
        isActive = false
        envPhase = 0
        envValue = 0
        envelopeLevel = 0
        phase = 0
        // Reset filter states to avoid clicks on next note
        let s = SVFBandState()
        filterStates = (s, s, s, s, s, s, s, s, s, s, s, s, s, s, s, s)
        // Reset function generator
        funcLevel = 1.0
        funcPrevPhase = 0
        funcSHValue = 1.0
    }

    // MARK: - Pattern Configuration

    mutating func setPattern(_ index: Int) {
        patternIndex = max(0, min(index, TidePatterns.patternCount - 1))
        if TidePatterns.isChaos(patternIndex) {
            cachedFrames = nil
            cachedFrameCount = 1
        } else {
            cachedFrames = TidePatterns.frames(for: patternIndex)
            cachedFrameCount = cachedFrames?.count ?? 1
        }
    }

    // MARK: - Function Generator

    /// Compute amplitude shaping gain (0–1). Phase is derived from the tide
    /// position so the function generator is always perfectly synced with
    /// the spectral animation.
    private mutating func computeFuncGen() -> Double {
        guard funcShapeRaw != 0 else { return 1.0 }

        // Smooth parameters
        funcAmount += (funcAmountTarget - funcAmount) * 0.001
        funcSkew += (funcSkewTarget - funcSkew) * 0.001

        // Derive phase from tide position
        let frameCount = max(1.0, Double(cachedFrameCount))
        var funcPhase = fmod(position * Double(funcCycles) / frameCount, 1.0)
        if funcPhase < 0 { funcPhase += 1.0 }

        // Apply skew warp: remap [0,skew] → [0,0.5] and [skew,1] → [0.5,1]
        let s = max(0.001, min(0.999, funcSkew))
        let warped: Double
        if funcPhase < s {
            warped = funcPhase / s * 0.5
        } else {
            warped = 0.5 + (funcPhase - s) / (1.0 - s) * 0.5
        }

        // Generate waveform value in 0–1 range
        let waveValue: Double
        switch funcShapeRaw {
        case 1: // sine
            waveValue = 0.5 + 0.5 * sin(2.0 * .pi * warped)
        case 2: // triangle
            waveValue = warped < 0.5 ? warped * 2.0 : 2.0 - warped * 2.0
        case 3: // ramp down
            waveValue = 1.0 - warped
        case 4: // ramp up
            waveValue = warped
        case 5: // square
            waveValue = warped < 0.5 ? 1.0 : 0.0
        case 6: // S&H
            if funcPhase < funcPrevPhase {
                // Phase wrapped — refresh held value from xorshift
                noiseState ^= noiseState << 13
                noiseState ^= noiseState >> 17
                noiseState ^= noiseState << 5
                funcSHValue = Double(noiseState & 0x7FFF_FFFF) / Double(0x7FFF_FFFF)
            }
            funcPrevPhase = funcPhase
            waveValue = funcSHValue
        default:
            waveValue = 1.0
        }

        // gain = 1 - amount + amount × waveValue  → range [1-amount, 1]
        let target = 1.0 - funcAmount + funcAmount * waveValue

        // Smooth output (~0.3ms anti-click)
        funcLevel += (target - funcLevel) * 0.05
        return funcLevel
    }

    // MARK: - Render

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

        // Control-rate updates
        controlCounter += 1
        if controlCounter >= Self.controlBlockSize {
            controlCounter = 0
            updateBandTargets(sampleRate: sampleRate)
        }

        // Smooth parameters per-sample
        let paramSmooth = 0.001
        currentParam += (currentTarget - currentParam) * paramSmooth
        rateParam += (rateTarget - rateParam) * paramSmooth
        depthParam += (depthTarget - depthParam) * paramSmooth
        warmthParam += (warmthTarget - warmthParam) * paramSmooth

        // Generate oscillator sample based on Current parameter
        let osc = generateCurrent(sampleRate: sampleRate)

        // Process through 16 SVF bandpass filters + VCA, sum to stereo
        let invSR = 1.0 / sampleRate
        var sumL: Double = 0
        var sumR: Double = 0

        // Smooth band levels and process filters using pointer rebinding
        withUnsafeMutablePointer(to: &bandLevels) { levelsPtr in
            levelsPtr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { levels in
                withUnsafeMutablePointer(to: &bandTargets) { targetsPtr in
                    targetsPtr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { targets in
                        withUnsafeMutablePointer(to: &bandQs) { qsPtr in
                            qsPtr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { qs in
                                withUnsafeMutablePointer(to: &filterStates) { statesPtr in
                                    statesPtr.withMemoryRebound(to: SVFBandState.self, capacity: Self.bandCount) { states in
                                        // Read band frequencies
                                        withUnsafePointer(to: Self.bandFrequencies) { freqPtr in
                                            freqPtr.withMemoryRebound(to: Double.self, capacity: Self.bandCount) { freqs in
                                                for i in 0..<Self.bandCount {
                                                    // Smooth level toward target
                                                    levels[i] += (targets[i] - levels[i]) * 0.05

                                                    // SVF bandpass processing
                                                    let freq = freqs[i]
                                                    guard freq < sampleRate * 0.48 else { continue }

                                                    let q = Double(qs[i])
                                                    let g = tan(.pi * freq * invSR)
                                                    let k = 1.0 / q
                                                    let a1 = 1.0 / (1.0 + g * (g + k))
                                                    let a2 = g * a1
                                                    let a3 = g * a2

                                                    let v3 = osc - states[i].ic2eq
                                                    let v1 = a1 * states[i].ic1eq + a2 * v3
                                                    let v2 = states[i].ic2eq + a2 * states[i].ic1eq + a3 * v3
                                                    states[i].ic1eq = 2.0 * v1 - states[i].ic1eq
                                                    states[i].ic2eq = 2.0 * v2 - states[i].ic2eq

                                                    // v1 is the bandpass output
                                                    let bandOut = v1 * Double(levels[i])

                                                    // Stereo: even bands slightly left, odd bands slightly right
                                                    if i % 2 == 0 {
                                                        sumL += bandOut * 0.7
                                                        sumR += bandOut * 0.3
                                                    } else {
                                                        sumL += bandOut * 0.3
                                                        sumR += bandOut * 0.7
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Apply function generator (amplitude shaping synced to tide position)
        let funcGain = computeFuncGen()
        sumL *= funcGain
        sumR *= funcGain

        // Apply envelope and velocity
        let env = envValue * Double(velocity)
        sumL *= env * 0.25
        sumR *= env * 0.25

        // Per-voice warmth (tanh saturation)
        let drive = 0.5 + warmthParam * 1.5
        let outL = Float(tanh(sumL * drive) / drive)
        let outR = Float(tanh(sumR * drive) / drive)

        return (outL, outR)
    }

    // MARK: - Oscillator (Current parameter crossfade)

    /// Generate the source oscillator sample. Current 0–1 crossfades:
    /// sine → triangle → saw → pulse, with noise mixed in at high values.
    private mutating func generateCurrent(sampleRate: Double) -> Double {
        let phaseInc = frequency / sampleRate
        phase += phaseInc
        phase -= Double(Int(phase))

        let p = phase
        let current = currentParam

        // Layer weights based on Current parameter
        // 0.0–0.25: sine dominates
        // 0.25–0.5: triangle rises
        // 0.5–0.75: saw rises
        // 0.75–1.0: pulse rises, noise added

        var sample: Double = 0

        if current < 0.25 {
            // Pure sine to sine+triangle
            let t = current / 0.25
            let sine = sin(2.0 * .pi * p)
            let tri = 4.0 * abs(p - 0.5) - 1.0
            sample = sine * (1.0 - t) + tri * t
        } else if current < 0.5 {
            // Triangle to saw
            let t = (current - 0.25) / 0.25
            let tri = 4.0 * abs(p - 0.5) - 1.0
            let saw = polyBLEPSaw(phase: p, phaseInc: phaseInc)
            sample = tri * (1.0 - t) + saw * t
        } else if current < 0.75 {
            // Saw to pulse
            let t = (current - 0.5) / 0.25
            let saw = polyBLEPSaw(phase: p, phaseInc: phaseInc)
            let pulse = polyBLEPPulse(phase: p, phaseInc: phaseInc, width: 0.5)
            sample = saw * (1.0 - t) + pulse * t
        } else {
            // Pulse + increasing noise
            let t = (current - 0.75) / 0.25
            let pulse = polyBLEPPulse(phase: p, phaseInc: phaseInc, width: 0.3 + t * 0.2)
            let noise = xorshift()
            sample = pulse * (1.0 - t * 0.4) + noise * t * 0.6
        }

        return sample
    }

    // MARK: - Band-limited waveforms (polyBLEP)

    private func polyBLEPSaw(phase p: Double, phaseInc dt: Double) -> Double {
        var out = 2.0 * p - 1.0
        // Transition at p=1 (wrap)
        if p < dt {
            let t = p / dt
            out -= (2.0 * t - t * t - 1.0)
        } else if p > 1.0 - dt {
            let t = (p - 1.0 + dt) / dt
            out -= (2.0 * t - t * t - 1.0)
        }
        return out
    }

    private func polyBLEPPulse(phase p: Double, phaseInc dt: Double, width: Double) -> Double {
        var out: Double = p < width ? 1.0 : -1.0
        // Transition at p=0
        if p < dt {
            let t = p / dt
            out += (2.0 * t - t * t - 1.0) * (p < width ? 1.0 : -1.0)
        } else if p > 1.0 - dt {
            let t = (p - 1.0 + dt) / dt
            out -= (2.0 * t - t * t - 1.0) * (p < width ? 1.0 : -1.0)
        }
        // Transition at p=width
        if p > width - dt && p < width + dt {
            let t = (p - width) / dt
            if t > -1 && t < 0 {
                let tn = t + 1
                out -= (2.0 * tn - tn * tn - 1.0)
            } else if t >= 0 && t < 1 {
                out += (2.0 * t - t * t - 1.0)
            }
        }
        return out
    }

    // MARK: - Noise

    private mutating func xorshift() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    // MARK: - Control Rate: Update Band Targets

    private mutating func updateBandTargets(sampleRate: Double) {
        // Advance position based on rate
        let blockSeconds = Double(Self.controlBlockSize) / sampleRate
        let positionRate: Double
        if rateSyncEnabled && bpm > 0 {
            // Synced: one full pattern cycle per rateDivisionBeats at current BPM
            let secondsPerCycle = rateDivisionBeats * 60.0 / bpm
            positionRate = Double(cachedFrameCount) / max(0.001, secondsPerCycle)
        } else {
            // Free: 0.05Hz to 5Hz cycle rate
            positionRate = 0.05 + rateParam * 4.95
        }
        position += positionRate * blockSeconds

        if TidePatterns.isChaos(patternIndex) {
            updateChaosTargets()
            return
        }

        guard let frames = cachedFrames, !frames.isEmpty else { return }
        let frameCount = Double(frames.count)

        // Wrap position
        if position >= frameCount { position -= frameCount * Double(Int(position / frameCount)) }

        // Interpolate between current and next frame
        let floorIdx = Int(position) % frames.count
        let nextIdx = (floorIdx + 1) % frames.count
        let frac = Float(position - Double(Int(position)))

        let frameA = frames[floorIdx]
        let frameB = frames[nextIdx]
        let depth = Float(depthParam)

        // Set band targets by interpolating between frames, scaled by depth
        withUnsafeMutablePointer(to: &bandTargets) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { targets in
                for i in 0..<Self.bandCount {
                    let a = TideFrame.level(frameA, at: i)
                    let b = TideFrame.level(frameB, at: i)
                    let interpolated = a + (b - a) * frac
                    // Depth controls contrast: at depth=0 all bands equal, at depth=1 full pattern
                    let baseline: Float = 0.15
                    targets[i] = baseline + interpolated * depth
                }
            }
        }

        // Update Q values from current frame
        withUnsafeMutablePointer(to: &bandQs) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { qs in
                for i in 0..<Self.bandCount {
                    let a = TideFrame.q(frameA, at: i)
                    let b = TideFrame.q(frameB, at: i)
                    qs[i] = a + (b - a) * frac
                }
            }
        }
    }

    /// Generate band targets for chaos patterns (14: Wanderer, 15: Storm).
    private mutating func updateChaosTargets() {
        let depth = Float(depthParam)
        let isStorm = patternIndex == 15
        let smoothing: Float = isStorm ? 0.3 : 0.1 // Storm is more volatile

        // Pre-generate noise values BEFORE pointer borrow to avoid exclusivity conflict
        var levelNoises: (Float, Float, Float, Float, Float, Float, Float, Float,
                          Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &levelNoises) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { p in
                for i in 0..<Self.bandCount {
                    p[i] = Float(xorshift()) * 0.5 + 0.5
                }
            }
        }

        var qNoises: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        if isStorm {
            withUnsafeMutablePointer(to: &qNoises) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { p in
                    for i in 0..<Self.bandCount {
                        p[i] = Float(xorshift()) * 0.5 + 0.5
                    }
                }
            }
        }

        // Now apply with safe pointer access
        withUnsafeMutablePointer(to: &bandTargets) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { targets in
                withUnsafePointer(to: levelNoises) { nPtr in
                    nPtr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { noises in
                        for i in 0..<Self.bandCount {
                            let target = noises[i] * depth + 0.1
                            targets[i] += (target - targets[i]) * smoothing
                        }
                    }
                }
            }
        }

        // Storm has wider Q variation
        if isStorm {
            withUnsafeMutablePointer(to: &bandQs) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { qs in
                    withUnsafePointer(to: qNoises) { nPtr in
                        nPtr.withMemoryRebound(to: Float.self, capacity: Self.bandCount) { noises in
                            for i in 0..<Self.bandCount {
                                qs[i] += (1.0 + noises[i] * 6.0 - qs[i]) * 0.15
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Envelope (identical state machine to FlowVoice)

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
}
