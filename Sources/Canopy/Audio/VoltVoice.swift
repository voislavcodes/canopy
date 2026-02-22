import Foundation

// MARK: - Circuit State Structures

/// Bridged-T resonator state: two capacitors exchanging energy through BJT feedback.
struct ResonantCircuitState {
    var capVoltage1: Float = 0      // C1 voltage
    var capVoltage2: Float = 0      // C2 voltage
    var transistorState: Float = 0  // Q1 collector voltage (feedback state)
    var leakCharge: Float = 0       // excess charge from trigger (decays → pitch sweep)
    var triggerEnergy: Float = 0    // remaining trigger pulse energy
}

/// Transistor noise circuit state: cap discharge envelope + noise source + RC filter.
struct NoiseCircuitState {
    // Envelope capacitor chain (for clap: sequential discharge)
    var envCapVoltage: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)
    var envCapCount: Int = 1
    var currentBurst: Int = 0
    var burstTimer: Float = 0

    // Transistor junction noise source
    var noiseRNG: UInt64 = 0
    var noiseFilterState: Float = 0    // junction capacitance LP

    // RC filter network (SVF)
    var rcFilterLP: Float = 0
    var rcFilterHP: Float = 0
    var rcFilterBP: Float = 0

    // Optional tonal oscillator (Schmitt trigger, when Tone > 0)
    var toneCapVoltage: Float = 0.3
    var toneSwitchState: Bool = true
}

/// Schmitt trigger oscillator bank state for metallic percussion.
struct MetallicCircuitState {
    // Six Schmitt trigger oscillators
    var capVoltages: (Float, Float, Float, Float, Float, Float) = (0.3, 0.3, 0.3, 0.3, 0.3, 0.3)
    var switchStates: (Bool, Bool, Bool, Bool, Bool, Bool) = (true, true, true, true, true, true)

    // RC bandpass filter
    var bpfLP: Float = 0
    var bpfBP: Float = 0

    // Envelope cap (powers oscillators)
    var envCapVoltage: Float = 0
}

/// Circuit FM via coupled Schmitt triggers.
struct TonalCircuitState {
    // Carrier circuit (the sound)
    var carrierCap: Float = 0.3
    var carrierSwitch: Bool = true

    // Modulator circuit (FM source)
    var modCap: Float = 0.3
    var modSwitch: Bool = true

    // Envelope cap (powers both circuits)
    var envCapVoltage: Float = 0

    // Pitch bend cap
    var bendCapVoltage: Float = 0
}

/// Unified circuit state covering all four topologies per layer.
struct VoltCircuitState {
    var resonant = ResonantCircuitState()
    var noise = NoiseCircuitState()
    var metallic = MetallicCircuitState()
    var tonal = TonalCircuitState()
}

/// Per-voice component tolerance — seeded deterministically from voice index.
struct VoltTolerance {
    var pitchOffset: Float = 0      // ±cents
    var decayBias: Float = 0        // ±% decay time
    var filterOffset: Float = 0     // ±% filter cutoff
    var saturationBias: Float = 0   // asymmetry in nonlinear stages
    var triggerJitter: Float = 0    // ±samples trigger timing variation
    var gainOffset: Float = 0       // ±dB

    static func seed(voiceIndex: Int, warm: Float) -> VoltTolerance {
        var hash = UInt64(truncatingIfNeeded: voiceIndex &* 2654435761)

        func hashFloat(_ h: inout UInt64) -> Float {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return Float(h >> 33) / Float(UInt64(1) << 31)
        }

        let scale = warm
        return VoltTolerance(
            pitchOffset:     (hashFloat(&hash) - 0.5) * 4.0 * scale,
            decayBias:       (hashFloat(&hash) - 0.5) * 0.06 * scale,
            filterOffset:    (hashFloat(&hash) - 0.5) * 0.08 * scale,
            saturationBias:  (hashFloat(&hash) - 0.5) * 0.10 * scale,
            triggerJitter:   hashFloat(&hash) * 2.0 * scale,
            gainOffset:      (hashFloat(&hash) - 0.5) * 0.15 * scale
        )
    }
}

// MARK: - Shared Parameters

/// Parameters broadcast to all VOLT voices from the audio thread.
struct VoltParams {
    var layerATopology: Int = 0     // 0=resonant, 1=noise, 2=metallic, 3=tonal
    var layerBTopology: Int = -1    // -1 = off
    var mix: Float = 0.5

    // Resonant
    var resPitch: Float = 0.3
    var resSweep: Float = 0.25
    var resDecay: Float = 0.4
    var resDrive: Float = 0.2
    var resPunch: Float = 0.4

    // Noise
    var noiseColor: Float = 0.5
    var noiseSnap: Float = 0.5
    var noiseBody: Float = 0.3
    var noiseClap: Float = 0.0
    var noiseTone: Float = 0.0
    var noiseFilter: Float = 0.0

    // Metallic
    var metSpread: Float = 0.3
    var metTune: Float = 0.5
    var metRing: Float = 0.3
    var metBand: Float = 0.35
    var metDensity: Float = 1.0

    // Tonal
    var tonPitch: Float = 0.4
    var tonFM: Float = 0.3
    var tonShape: Float = 0.25
    var tonBend: Float = 0.2
    var tonDecay: Float = 0.3

    // Output
    var warm: Float = 0.3
}

// MARK: - VoltVoice

/// Per-voice DSP for VOLT analog circuit drum synthesis.
/// Two layer slots, each with independent circuit state for all 4 topologies.
/// Pure value type, zero allocations, audio-thread safe.
struct VoltVoice {
    // Layer A state
    var layerA = VoltCircuitState()
    // Layer B state
    var layerB = VoltCircuitState()

    // Voice state
    var velocity: Float = 0
    var noteFreq: Float = 440
    private(set) var isActive: Bool = false
    var rng: UInt64 = 0

    // Per-voice circuit personality
    var tolerance = VoltTolerance()
    var warmState = WarmVoiceState()

    // Smoothed mix
    var mixSmoothed: Float = 0.5

    /// Envelope level for voice stealing — Layer A's envelope cap voltage.
    var envelopeLevel: Float {
        // Return the highest envelope level across active topologies
        max(layerA.resonant.capVoltage1 * layerA.resonant.capVoltage1 + layerA.resonant.capVoltage2 * layerA.resonant.capVoltage2,
            max(layerAEnvCap, layerBEnvCap))
    }

    private var layerAEnvCap: Float {
        max(max(layerA.noise.envCapVoltage.0, layerA.metallic.envCapVoltage),
            max(layerA.tonal.envCapVoltage, abs(layerA.resonant.capVoltage1) + abs(layerA.resonant.capVoltage2)))
    }

    private var layerBEnvCap: Float {
        max(max(layerB.noise.envCapVoltage.0, layerB.metallic.envCapVoltage),
            max(layerB.tonal.envCapVoltage, abs(layerB.resonant.capVoltage1) + abs(layerB.resonant.capVoltage2)))
    }

    // MARK: - Note Control

    mutating func noteOn(pitch: Int, velocity: Float, sampleRate: Float) {
        self.noteFreq = Float(MIDIUtilities.frequency(forNote: pitch))
        self.velocity = velocity
        self.isActive = true
    }

    mutating func noteOff() {
        // Drums don't gate — they decay naturally from cap discharge.
        // noteOff is essentially a no-op for VOLT.
    }

    mutating func kill() {
        isActive = false
        velocity = 0
        layerA = VoltCircuitState()
        layerB = VoltCircuitState()
    }

    // MARK: - Render

    /// Render one sample through the full VOLT signal chain.
    mutating func renderSample(sampleRate: Float, params: VoltParams) -> Float {
        guard isActive else { return 0 }

        // Smooth mix (Rule 5)
        let mixTarget = params.mix
        mixSmoothed += (mixTarget - mixSmoothed) * 0.002

        let warm = params.warm

        // Render Layer A (copy out to avoid overlapping access to self)
        var aState = layerA
        let a = renderLayer(
            state: &aState,
            topology: params.layerATopology,
            params: params,
            warm: warm,
            sampleRate: sampleRate
        )
        layerA = aState

        // Render Layer B (if active)
        var output: Float
        if params.layerBTopology >= 0 {
            var bState = layerB
            let b = renderLayer(
                state: &bState,
                topology: params.layerBTopology,
                params: params,
                warm: warm,
                sampleRate: sampleRate
            )
            layerB = bState
            output = a * (1.0 - mixSmoothed) + b * mixSmoothed
        } else {
            output = a
        }

        // Check if voice has decayed to silence (before WARM — don't feed dead signal into DC blocker)
        if envelopeLevel < 0.0001 {
            isActive = false
            return 0
        }

        // Apply WARM processing
        if warm > 0.01 {
            output = WarmProcessor.processSample(&warmState, sample: output, warm: warm, sampleRate: sampleRate)
        }

        // Apply per-voice gain tolerance
        output *= (1.0 + tolerance.gainOffset * warm)

        return output
    }

    // MARK: - Trigger (called from noteOn context within render)

    /// Trigger all circuits for the active topologies on both layers.
    mutating func trigger(params: VoltParams) {
        var aState = layerA
        triggerLayer(state: &aState, topology: params.layerATopology, params: params)
        layerA = aState
        if params.layerBTopology >= 0 {
            var bState = layerB
            triggerLayer(state: &bState, topology: params.layerBTopology, params: params)
            layerB = bState
        }
    }

    private mutating func triggerLayer(state: inout VoltCircuitState, topology: Int, params: VoltParams) {
        switch topology {
        case 0: triggerResonant(state: &state.resonant, params: params)
        case 1: triggerNoise(state: &state.noise, params: params)
        case 2: triggerMetallic(state: &state.metallic)
        case 3: triggerTonal(state: &state.tonal, params: params)
        default: break
        }
    }

    // MARK: - Layer Render Dispatch

    private mutating func renderLayer(
        state: inout VoltCircuitState,
        topology: Int,
        params: VoltParams,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        switch topology {
        case 0: return renderResonant(state: &state.resonant, params: params, warm: warm, sampleRate: sampleRate)
        case 1: return renderNoise(state: &state.noise, params: params, warm: warm, sampleRate: sampleRate)
        case 2: return renderMetallic(state: &state.metallic, params: params, warm: warm, sampleRate: sampleRate)
        case 3: return renderTonal(state: &state.tonal, params: params, warm: warm, sampleRate: sampleRate)
        default: return 0
        }
    }

    // MARK: - RESONANT Topology

    private mutating func triggerResonant(state: inout ResonantCircuitState, params: VoltParams) {
        let punch = params.resPunch
        let sweep = params.resSweep
        let triggerVoltage = (0.3 + punch * 0.7) * (0.5 + velocity * 0.5)
        state.triggerEnergy = triggerVoltage
        state.leakCharge = triggerVoltage * sweep * (1.0 + velocity * 0.5)
    }

    private mutating func renderResonant(
        state: inout ResonantCircuitState,
        params: VoltParams,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        let pitch = params.resPitch
        let sweep = params.resSweep
        let decay = params.resDecay
        let drive = params.resDrive
        let punch = params.resPunch

        // Map pitch param to Hz: 30–500 Hz exponential
        let pitchHz = 30.0 * powf(500.0 / 30.0, pitch)

        // Trigger pulse injection (short burst of energy into C1)
        if state.triggerEnergy > 0.001 {
            let punchWidth = 0.002 + punch * 0.003  // 2-5ms pulse
            let punchDecay = powf(0.001, 1.0 / (punchWidth * sampleRate))
            state.capVoltage1 += state.triggerEnergy * 0.1
            state.triggerEnergy *= punchDecay  // Rule 3
        }

        // Pitch sweep from voltage leakage
        let leakRate = 0.001 + (1.0 - sweep) * 0.05
        state.leakCharge *= (1.0 - leakRate)  // Rule 3

        // Effective pitch: base + offset from excess charge
        let pitchOffset = state.leakCharge * 4.0  // max ~4 octaves of sweep
        let effectivePitch = pitchHz * (1.0 + pitchOffset)
        let tolerancedPitch = effectivePitch * (1.0 + tolerance.pitchOffset * warm / 1200.0)
        let clampedPitch = min(max(tolerancedPitch, 10.0), 0.48 * sampleRate)  // Rule 8

        // Angular frequency for this sample
        let omega = 2.0 * Float.pi * clampedPitch / sampleRate

        // Feedback gain from Q1: controls how long the oscillation rings
        let decayTolerance = 1.0 + tolerance.decayBias * warm
        let feedbackGain = 0.9 + decay * 0.0999 * decayTolerance  // 0.9 to ~1.0

        // BJT feedback with asymmetric saturation
        let fbInput = state.transistorState * feedbackGain
        let driveAmount = 1.0 + drive * 8.0
        let driven = fbInput * driveAmount
        let satBias = 0.1 + tolerance.saturationBias * warm * 0.2
        let saturated = VoltVoice.transistorSaturate(driven, bias: satBias, drive: drive)

        // Bridged-T coupled oscillation (symplectic Euler):
        // C2 is pushed by C1, C1 is pulled by -C2.
        // This creates rotational energy exchange = oscillation at freq ~clampedPitch.
        state.capVoltage2 += omega * state.capVoltage1
        state.capVoltage1 -= omega * state.capVoltage2

        // BJT feedback injects energy into C1 (sustains/drives the oscillation)
        state.capVoltage1 += saturated * omega

        // Per-sample damping: energy lost each cycle
        let damping = 1.0 - (1.0 - feedbackGain) * omega
        state.capVoltage1 *= damping
        state.capVoltage2 *= damping

        // Clamp to prevent runaway (Rule 4)
        state.capVoltage1 = max(-8.0, min(8.0, state.capVoltage1))
        state.capVoltage2 = max(-8.0, min(8.0, state.capVoltage2))

        // Transistor follows C2 with slew
        let transistorSlew = 0.1 + (1.0 - drive) * 0.3
        state.transistorState += (state.capVoltage2 - state.transistorState) * transistorSlew

        // Output from C2 (bridged-T output node)
        return tanhf(state.capVoltage2 * 2.0)  // Rule 6
    }

    // MARK: - NOISE Topology

    private mutating func triggerNoise(state: inout NoiseCircuitState, params: VoltParams) {
        let clap = params.noiseClap
        let triggerVoltage: Float = 0.5 + velocity * 0.5

        // Seed noise RNG from voice RNG (xorshift64(0) = 0 forever)
        state.noiseRNG = rng | 1  // ensure non-zero seed
        rng = rng &* 6364136223846793005 &+ 1442695040888963407  // advance voice RNG

        let burstCount = 1 + Int(clap * 5)  // 1–6 caps
        state.envCapCount = burstCount
        state.currentBurst = 0

        // Charge first cap immediately
        withUnsafeMutablePointer(to: &state.envCapVoltage) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 6) { caps in
                caps[0] = triggerVoltage
            }
        }

        // Pre-charge subsequent caps at decreasing voltages
        if burstCount > 1 {
            withUnsafeMutablePointer(to: &state.envCapVoltage) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 6) { caps in
                    for i in 1..<burstCount {
                        let decay = Float(burstCount - i) / Float(burstCount)
                        caps[i] = triggerVoltage * decay * (0.8 + VoltVoice.randomFloat(&rng) * 0.4)
                    }
                }
            }
            let gapMs = 8.0 + VoltVoice.randomFloat(&rng) * 25.0
            state.burstTimer = gapMs / 1000.0 * 48000
        }
    }

    private mutating func renderNoise(
        state: inout NoiseCircuitState,
        params: VoltParams,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        let color = params.noiseColor
        let body = params.noiseBody
        let tone = params.noiseTone
        let filterRes = params.noiseFilter

        // Envelope: cap discharge
        let bodySeconds = 0.005 + body * body * 1.995
        let dischargeRate = powf(0.001, 1.0 / (bodySeconds * sampleRate))

        var envVoltage: Float = 0
        withUnsafeMutablePointer(to: &state.envCapVoltage) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 6) { caps in
                if state.currentBurst < state.envCapCount {
                    caps[state.currentBurst] *= dischargeRate  // Rule 3
                    envVoltage = caps[state.currentBurst]
                }

                // Multi-burst: fire next cap when timer expires
                if state.envCapCount > 1 && state.currentBurst < state.envCapCount - 1 {
                    state.burstTimer -= 1
                    if state.burstTimer <= 0 {
                        state.currentBurst += 1
                        let gapMs = 8.0 + VoltVoice.randomFloat(&rng) * 25.0
                        state.burstTimer = gapMs / 1000.0 * sampleRate
                        envVoltage += caps[state.currentBurst] * 0.7
                    }
                }
            }
        }

        // Transistor junction noise source
        let rawNoise = VoltVoice.bipolarRandom(&state.noiseRNG)

        // Junction capacitance: gentle 1-pole LP on noise
        let junctionCutoff: Float = 15000 + warm * (-5000)
        let junctionCoeff = expf(-2.0 * Float.pi * junctionCutoff / sampleRate)
        state.noiseFilterState = rawNoise * (1.0 - junctionCoeff) + state.noiseFilterState * junctionCoeff
        let junctionNoise = state.noiseFilterState

        // RC filter network
        let filterCutoff = 100.0 + color * color * 15900.0
        let tolerancedCutoff = filterCutoff * (1.0 + tolerance.filterOffset * warm)
        let clampedCutoff = min(tolerancedCutoff, 0.48 * sampleRate)

        let f = 2.0 * sinf(Float.pi * clampedCutoff / sampleRate)
        let q = 1.0 - filterRes * 0.95

        state.rcFilterLP += f * state.rcFilterBP
        let hp = junctionNoise - state.rcFilterLP - q * state.rcFilterBP
        state.rcFilterBP += f * hp

        // Clamp SVF states (Rule 4)
        state.rcFilterLP = max(-4.0, min(4.0, state.rcFilterLP))
        state.rcFilterBP = max(-4.0, min(4.0, state.rcFilterBP))

        // Color determines output: dark = LP, mid = BP, bright = HP
        let filteredNoise: Float
        if color < 0.3 {
            filteredNoise = state.rcFilterLP
        } else if color < 0.7 {
            let t = (color - 0.3) / 0.4
            filteredNoise = state.rcFilterLP * (1.0 - t) + state.rcFilterBP * t
        } else {
            let t = (color - 0.7) / 0.3
            filteredNoise = state.rcFilterBP * (1.0 - t) + hp * t
        }

        // VCA transistor (nonlinear gain from envelope cap voltage)
        let vcaGain = envVoltage * envVoltage  // quadratic: quieter tails are also darker

        var output = filteredNoise * vcaGain

        // Tonal component: Schmitt trigger oscillator powered by envelope cap
        if tone > 0.01 {
            let toneFreq = 100.0 + color * 600.0
            let clampedToneFreq = min(toneFreq, 0.48 * sampleRate)
            let (triOut, _, _) = SchmittCircuit.render(
                capVoltage: &state.toneCapVoltage,
                switchState: &state.toneSwitchState,
                supplyV: envVoltage,
                targetFreq: clampedToneFreq,
                soul: 0.3,
                tolerance: (tolerance.pitchOffset * 0.01, tolerance.decayBias * 0.01,
                           tolerance.filterOffset * 0.01, tolerance.saturationBias * 0.01),
                warm: warm,
                couplingInput: 0
            )
            let toneOut = triOut * envVoltage
            output = output * (1.0 - tone) + toneOut * tone
        }

        return tanhf(output * 3.0)  // Rule 6
    }

    // MARK: - METALLIC Topology

    private mutating func triggerMetallic(state: inout MetallicCircuitState) {
        state.envCapVoltage = 0.5 + velocity * 0.5
    }

    private mutating func renderMetallic(
        state: inout MetallicCircuitState,
        params: VoltParams,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        let spread = params.metSpread
        let tune = params.metTune
        let ring = params.metRing
        let band = params.metBand
        let densityParam = params.metDensity

        // Map tune param to Hz: 200–16000 Hz exponential
        let tuneHz = 200.0 * powf(16000.0 / 200.0, tune)

        // 808-inspired frequency ratios
        let ratios: (Float, Float, Float, Float, Float, Float) = (
            1.0,
            1.0 + 0.46 * spread,
            1.0 + 0.81 * spread,
            1.0 + 1.16 * spread,
            1.0 + 1.56 * spread,
            1.0 + 1.87 * spread
        )

        // Density: 2–6 oscillators
        let oscCount = 2 + Int(densityParam * 4)
        let clampedOscCount = min(max(oscCount, 2), 6)
        // Fixed supply for oscillation — envelope controls VCA only (real 808 pattern)
        let supplyV: Float = 1.0

        // Render each Schmitt trigger oscillator
        var sum: Float = 0

        withUnsafeMutablePointer(to: &state.capVoltages) { capPtr in
            capPtr.withMemoryRebound(to: Float.self, capacity: 6) { caps in
                withUnsafeMutablePointer(to: &state.switchStates) { swPtr in
                    swPtr.withMemoryRebound(to: Bool.self, capacity: 6) { switches in
                        withUnsafePointer(to: ratios) { rPtr in
                            rPtr.withMemoryRebound(to: Float.self, capacity: 6) { ratioVals in
                                for i in 0..<clampedOscCount {
                                    let freq = tuneHz * ratioVals[i]
                                    let clampedFreq = min(freq, 0.48 * sampleRate)

                                    let (triOut, sqOut, _) = SchmittCircuit.render(
                                        capVoltage: &caps[i],
                                        switchState: &switches[i],
                                        supplyV: supplyV,
                                        targetFreq: clampedFreq,
                                        soul: 0.75,
                                        tolerance: (
                                            tolerance.pitchOffset * 0.01,
                                            tolerance.decayBias * 0.01,
                                            tolerance.filterOffset * 0.01,
                                            tolerance.saturationBias * 0.01
                                        ),
                                        warm: warm,
                                        couplingInput: 0
                                    )

                                    sum += sqOut * 0.8 + triOut * 0.2
                                }
                            }
                        }
                    }
                }
            }
        }
        sum /= Float(clampedOscCount)

        // RC bandpass filter
        let bpCutoff = tuneHz * (1.0 + tolerance.filterOffset * warm)
        let clampedBpCutoff = min(bpCutoff, 0.48 * sampleRate)
        let f = 2.0 * sinf(Float.pi * clampedBpCutoff / sampleRate)
        let q = 1.0 / (0.5 + band * 20.0)

        state.bpfLP += f * state.bpfBP
        let hp = sum - state.bpfLP - q * state.bpfBP
        state.bpfBP += f * hp

        // Clamp SVF states (Rule 4)
        state.bpfLP = max(-4.0, min(4.0, state.bpfLP))
        state.bpfBP = max(-4.0, min(4.0, state.bpfBP))

        // Envelope cap discharge
        let ringSeconds = 0.005 + ring * ring * 4.995
        let ringWithVelocity = ringSeconds * (1.0 + velocity * 0.5)
        let envDecay = powf(0.001, 1.0 / max(ringWithVelocity * sampleRate, 1))
        state.envCapVoltage *= envDecay  // Rule 3

        let vcaGain = state.envCapVoltage * state.envCapVoltage

        return tanhf(state.bpfBP * vcaGain * 3.0)  // Rule 6
    }

    // MARK: - TONAL Topology

    private mutating func triggerTonal(state: inout TonalCircuitState, params: VoltParams) {
        let bend = params.tonBend
        state.envCapVoltage = 0.5 + velocity * 0.5
        state.bendCapVoltage = bend * (0.5 + velocity * 0.5)
    }

    private mutating func renderTonal(
        state: inout TonalCircuitState,
        params: VoltParams,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        let pitch = params.tonPitch
        let fm = params.tonFM
        let shape = params.tonShape
        let bend = params.tonBend
        let decay = params.tonDecay

        // Map pitch param to Hz: 20–2000 Hz exponential
        // Also respond to MIDI note for melodic use
        let basePitchHz = 20.0 * powf(2000.0 / 20.0, pitch)
        // Blend base pitch with MIDI frequency (MIDI wins at higher velocity)
        let pitchHz = basePitchHz

        // Pitch bend from capacitor leakage
        let bendLeakRate: Float = 0.003 + (1.0 - bend) * 0.02
        state.bendCapVoltage *= (1.0 - bendLeakRate)  // Rule 3

        let effectivePitch = pitchHz * (1.0 + state.bendCapVoltage * 3.0)
        let tolerancedPitch = effectivePitch * (1.0 + tolerance.pitchOffset * warm / 1200.0)

        // Modulator circuit (2× carrier for musical FM)
        let modFreq = min(tolerancedPitch * 2.0, 0.48 * sampleRate)

        let (modTri, _, _) = SchmittCircuit.render(
            capVoltage: &state.modCap,
            switchState: &state.modSwitch,
            supplyV: 1.0,  // Fixed supply — envelope controls VCA only
            targetFreq: modFreq,
            soul: 0.5,
            tolerance: (
                tolerance.pitchOffset * 0.01,
                tolerance.decayBias * 0.01,
                tolerance.filterOffset * 0.01,
                tolerance.saturationBias * 0.01
            ),
            warm: warm,
            couplingInput: 0
        )

        // FM coupling: modulator → carrier frequency (quadratic for usable range)
        let fmDepth = fm * fm * tolerancedPitch * 4.0
        let fmModulation = modTri * fmDepth

        // Carrier circuit
        let carrierFreq = min(max(tolerancedPitch + fmModulation, 10.0), 0.48 * sampleRate)

        let (carrierTri, carrierSq, _) = SchmittCircuit.render(
            capVoltage: &state.carrierCap,
            switchState: &state.carrierSwitch,
            supplyV: 1.0,  // Fixed supply — envelope controls VCA only
            targetFreq: carrierFreq,
            soul: shape,  // Shape IS Soul
            tolerance: (
                tolerance.pitchOffset * 0.01,
                tolerance.decayBias * 0.01,
                tolerance.filterOffset * 0.01,
                tolerance.saturationBias * 0.01
            ),
            warm: warm,
            couplingInput: fmModulation / max(tolerancedPitch, 1.0)
        )

        let blend = shape  // Linear blend for full range control
        let carrierOut = carrierTri * (1.0 - blend) + carrierSq * blend

        // Envelope cap discharge
        let decaySeconds = 0.005 + decay * decay * 4.995
        let envDecay = powf(0.001, 1.0 / max(decaySeconds * sampleRate, 1))
        state.envCapVoltage *= envDecay  // Rule 3

        return tanhf(carrierOut * state.envCapVoltage * 3.0)  // Rule 6
    }

    // MARK: - Utilities

    /// BJT-style asymmetric saturation.
    @inline(__always)
    static func transistorSaturate(_ x: Float, bias: Float, drive: Float) -> Float {
        if x >= 0 {
            return tanhf(x * (1.0 + bias))
        } else {
            let sharpness: Float = 1.5 + drive * 2.0
            return -tanhf(abs(x) * sharpness * (1.0 - bias))
        }
    }

    /// Fast bipolar random (-1 to +1) from xorshift64.
    @inline(__always)
    static func bipolarRandom(_ state: inout UInt64) -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Int64(bitPattern: state)) / Float(Int64.max)
    }

    /// Fast unipolar random (0 to 1) from xorshift64.
    @inline(__always)
    static func randomFloat(_ state: inout UInt64) -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 33) / Float(UInt64(1) << 31)
    }
}
