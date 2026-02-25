import Foundation

/// Parameters broadcast to all SCHMYNTH voices from the audio thread.
struct SchmynthParams {
    var waveform: Int = 0          // 0=SAW, 1=SQR, 2=TRI, 3=SINE
    var cutoff: Float = 8000       // Hz, 20-20000
    var resonance: Float = 0       // 0-1
    var filterMode: Int = 0        // 0=LP, 1=BP, 2=HP
    var attack: Float = 0.01       // seconds
    var decay: Float = 0.1
    var sustain: Float = 0.7       // 0-1
    var release: Float = 0.3
    var warm: Float = 0.3          // 0-1
}

/// Per-voice component tolerance — each voice is a unique physical circuit.
struct SchmynthTolerance {
    // Oscillator
    var rCharge: Float = 0
    var rDischarge: Float = 0
    var cap: Float = 0
    var thresholdBias: Float = 0

    // SCF: per-stage RC offset
    var scfRC0: Float = 0
    var scfRC1: Float = 0
    var scfRC2: Float = 0
    var scfRC3: Float = 0

    // SCF: per-stage gain offset
    var scfGain0: Float = 0
    var scfGain1: Float = 0
    var scfGain2: Float = 0
    var scfGain3: Float = 0

    // Envelope cap offset
    var envCapOffset: Float = 0
}

/// SCF (Schmitt Cascade Filter) state — 4 capacitor voltages + hysteresis states.
struct SchmynthSCFState {
    var stageCap: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var stageOutput: (Float, Float, Float, Float) = (0, 0, 0, 0)
    var stageHyst: (Bool, Bool, Bool, Bool) = (false, false, false, false)
}

/// RC circuit ADSR envelope state.
struct SchmynthEnvState {
    var capVoltage: Float = 0
    var stage: SchmynthEnvStage = .idle
    var gateOn: Bool = false
}

enum SchmynthEnvStage {
    case idle, attack, decay, sustain, release
}

/// Per-voice DSP for SCHMYNTH circuit-modeled subtractive synthesis.
/// Capacitor-reset oscillator → Schmitt Cascade Filter → RC envelope.
/// Zero allocations, pure value type, audio-thread safe.
struct SchmynthVoice {
    // MARK: - Oscillator state (via SchmittCircuit)
    var capVoltage: Float = 0.3
    var switchState: Bool = true
    var integratorCap: Float = 0       // for triangle output tap
    var comparatorTrack: Float = 0     // for square slew tracking

    // MARK: - SCF state
    var scf = SchmynthSCFState()

    // MARK: - Envelope
    var env = SchmynthEnvState()

    // MARK: - Pitch
    var noteFreq: Float = 440
    var velocity: Float = 0

    // MARK: - Voice state
    var gate: Bool = false
    private(set) var isActive: Bool = false

    // MARK: - Tolerance
    var tolerance = SchmynthTolerance()

    // MARK: - WARM state
    var warmState = WarmVoiceState()

    // MARK: - Smoothed parameters
    var cutoffSmooth: Float = 8000
    var resonanceSmooth: Float = 0

    /// Envelope level for voice stealing.
    var envelopeLevel: Float { env.capVoltage }

    // MARK: - Note Control

    mutating func noteOn(pitch: Int, velocity: Float, sampleRate: Float) {
        self.noteFreq = Float(MIDIUtilities.frequency(forNote: pitch))
        self.velocity = velocity
        self.gate = true
        self.isActive = true

        // Retrigger envelope
        env.stage = .attack
        env.gateOn = true

        // Cold start: initialize oscillator
        if env.capVoltage < 0.001 {
            capVoltage = 0.3
            switchState = true
            integratorCap = 0
            comparatorTrack = 0
        }
    }

    mutating func noteOff() {
        gate = false
        env.stage = .release
        env.gateOn = false
    }

    mutating func kill() {
        gate = false
        isActive = false
        env = SchmynthEnvState()
        capVoltage = 0.3
        switchState = true
        integratorCap = 0
        comparatorTrack = 0
        scf = SchmynthSCFState()
    }

    // MARK: - Render

    mutating func renderSample(sampleRate: Float, params: SchmynthParams) -> Float {
        guard isActive else { return 0 }

        let warm = params.warm

        // === Smooth cutoff/resonance (Rule 5) ===
        let smoothRate: Float = 0.002
        cutoffSmooth += (params.cutoff - cutoffSmooth) * smoothRate
        resonanceSmooth += (params.resonance - resonanceSmooth) * smoothRate

        // === RC Envelope ===
        let envLevel = renderEnvelope(
            attack: params.attack, decay: params.decay,
            sustain: params.sustain, release: params.release,
            warm: warm, sampleRate: sampleRate
        )

        if !isActive { return 0 }

        // === Oscillator (SchmittCircuit core) ===
        let tol = tolerance
        let oscTol = (rCharge: tol.rCharge, rDischarge: tol.rDischarge,
                      cap: tol.cap, thresholdBias: tol.thresholdBias)
        let (triOut, sqOut, _) = SchmittCircuit.render(
            capVoltage: &capVoltage,
            switchState: &switchState,
            supplyV: 1.0,
            targetFreq: noteFreq,
            soul: 0.4,                    // fixed operating point for subtractive
            tolerance: oscTol,
            warm: warm,
            couplingInput: 0,
            keyTracking: true,
            sampleRate: sampleRate
        )

        // === Output tap selection ===
        let oscOut: Float
        switch params.waveform {
        case 0: // SAW — use triangleOut remapped as ramp
            // SchmittCircuit triangleOut is a triangle shape from cap voltage.
            // For saw, remap to a rising ramp: (capVoltage normalized to bipolar)
            oscOut = triOut
        case 1: // SQUARE — comparator output with slew
            let targetLevel: Float = sqOut
            let slewRate: Float = 0.15 + (1.0 - warm * 0.1)
            comparatorTrack += (targetLevel - comparatorTrack) * slewRate
            oscOut = comparatorTrack
        case 2: // TRIANGLE — integration of square
            let integrationRate = noteFreq * 4.0 / sampleRate
            let maxStep: Float = 0.1
            let step = min(abs(sqOut * integrationRate), maxStep) * (sqOut > 0 ? 1.0 : -1.0)
            integratorCap += step
            integratorCap = max(-1.0, min(1.0, integratorCap))
            oscOut = integratorCap
        case 3: // SINE — waveshaped triangle
            let integrationRate = noteFreq * 4.0 / sampleRate
            let maxStep: Float = 0.1
            let step = min(abs(sqOut * integrationRate), maxStep) * (sqOut > 0 ? 1.0 : -1.0)
            integratorCap += step
            integratorCap = max(-1.0, min(1.0, integratorCap))
            oscOut = SchmynthVoice.diodeWaveshape(integratorCap)
        default:
            oscOut = triOut
        }

        // === Schmitt Cascade Filter ===
        let filtered = renderSCF(
            input: oscOut,
            cutoff: cutoffSmooth,
            resonance: resonanceSmooth,
            mode: params.filterMode,
            warm: warm,
            sampleRate: sampleRate
        )

        // === Apply envelope + velocity ===
        let amped = filtered * envLevel * velocity

        // === Output limiter (Rule 6) ===
        return tanhf(amped * 2.0)
    }

    // MARK: - SCF (Schmitt Cascade Filter)

    /// Process one sample through 4 Schmitt trigger stages with resonance feedback.
    private mutating func renderSCF(
        input: Float,
        cutoff: Float,
        resonance: Float,
        mode: Int,
        warm: Float,
        sampleRate: Float
    ) -> Float {
        let clampedCutoff = min(max(cutoff, 20.0), 0.48 * sampleRate)
        let rcCoeff = 2.0 * Float.pi * clampedCutoff / sampleRate
        let g = rcCoeff / (1.0 + rcCoeff) // trapezoidal integration coefficient

        let tol = tolerance

        // Resonance feedback (Stage 4 → Stage 1 input)
        let fbAmount = resonance * 4.0
        let fbSignal = scf.stageOutput.3
        let inputWithFeedback = input - fbSignal * fbAmount

        // Stage 1
        let g0 = g * (1.0 + tol.scfRC0 * warm * 0.02)
        scf.stageCap.0 += (inputWithFeedback - scf.stageCap.0) * g0
        scf.stageOutput.0 = SchmynthVoice.schmittTransfer(
            scf.stageCap.0,
            hysteresisState: &scf.stageHyst.0,
            hysteresisWidth: 0.05 + warm * 0.03,
            gain: 1.0 + tol.scfGain0 * warm * 0.01
        )

        // Stage 2
        let g1 = g * (1.0 + tol.scfRC1 * warm * 0.02)
        scf.stageCap.1 += (scf.stageOutput.0 - scf.stageCap.1) * g1
        scf.stageOutput.1 = SchmynthVoice.schmittTransfer(
            scf.stageCap.1,
            hysteresisState: &scf.stageHyst.1,
            hysteresisWidth: 0.05 + warm * 0.03,
            gain: 1.0 + tol.scfGain1 * warm * 0.01
        )

        // Stage 3
        let g2 = g * (1.0 + tol.scfRC2 * warm * 0.02)
        scf.stageCap.2 += (scf.stageOutput.1 - scf.stageCap.2) * g2
        scf.stageOutput.2 = SchmynthVoice.schmittTransfer(
            scf.stageCap.2,
            hysteresisState: &scf.stageHyst.2,
            hysteresisWidth: 0.05 + warm * 0.03,
            gain: 1.0 + tol.scfGain2 * warm * 0.01
        )

        // Stage 4
        let g3 = g * (1.0 + tol.scfRC3 * warm * 0.02)
        scf.stageCap.3 += (scf.stageOutput.2 - scf.stageCap.3) * g3
        scf.stageOutput.3 = SchmynthVoice.schmittTransfer(
            scf.stageCap.3,
            hysteresisState: &scf.stageHyst.3,
            hysteresisWidth: 0.05 + warm * 0.03,
            gain: 1.0 + tol.scfGain3 * warm * 0.01
        )

        // Clamp all cap values (Rule 4)
        scf.stageCap.0 = max(-4.0, min(4.0, scf.stageCap.0))
        scf.stageCap.1 = max(-4.0, min(4.0, scf.stageCap.1))
        scf.stageCap.2 = max(-4.0, min(4.0, scf.stageCap.2))
        scf.stageCap.3 = max(-4.0, min(4.0, scf.stageCap.3))

        // Mode output selection
        switch mode {
        case 0: return scf.stageOutput.3                                    // LP
        case 1: return scf.stageOutput.1 - scf.stageOutput.3               // BP
        case 2: return input - scf.stageOutput.3                            // HP
        default: return scf.stageOutput.3
        }
    }

    // MARK: - Schmitt Transfer Function

    /// Schmitt trigger transfer function for filter stage.
    /// Soft-limiting gain stage with hysteresis.
    @inline(__always)
    static func schmittTransfer(
        _ input: Float,
        hysteresisState: inout Bool,
        hysteresisWidth: Float,
        gain: Float
    ) -> Float {
        let upperThresh = hysteresisWidth
        let lowerThresh = -hysteresisWidth

        if input > upperThresh {
            hysteresisState = true
        } else if input < lowerThresh {
            hysteresisState = false
        }

        let scaled = input * gain
        let limited = tanhf(scaled * 1.5) / 1.5
        let hystBias: Float = hysteresisState ? hysteresisWidth * 0.3 : -hysteresisWidth * 0.3

        return limited + hystBias
    }

    // MARK: - RC Envelope

    /// Capacitor-based ADSR — exponential curves from RC physics.
    private mutating func renderEnvelope(
        attack: Float, decay: Float, sustain: Float, release: Float,
        warm: Float, sampleRate: Float
    ) -> Float {
        switch env.stage {
        case .idle:
            env.capVoltage = 0

        case .attack:
            let target: Float = 1.0 + warm * 0.05
            let rate = 1.0 / max(attack * sampleRate, 1)
            env.capVoltage += (target - env.capVoltage) * rate
            if env.capVoltage >= 0.999 {
                env.capVoltage = 1.0
                env.stage = .decay
            }

        case .decay:
            let rate = 1.0 / max(decay * sampleRate, 1)
            env.capVoltage += (sustain - env.capVoltage) * rate
            if abs(env.capVoltage - sustain) < 0.001 {
                env.stage = .sustain
            }

        case .sustain:
            let leakRate = warm * 0.00001
            env.capVoltage -= leakRate
            env.capVoltage = max(env.capVoltage, sustain * 0.9)

        case .release:
            let rate = 1.0 / max(release * sampleRate, 1)
            env.capVoltage += (0 - env.capVoltage) * rate
            if env.capVoltage < 0.0001 {
                env.capVoltage = 0
                env.stage = .idle
                isActive = false
            }
        }

        return env.capVoltage
    }

    // MARK: - Diode Waveshaper

    /// Progressive soft clipping: rounds triangle peaks into ~sine shape.
    @inline(__always)
    static func diodeWaveshape(_ x: Float) -> Float {
        let abs_x = abs(x)
        let sign_x: Float = x >= 0 ? 1.0 : -1.0

        let shaped: Float
        if abs_x < 0.6 {
            shaped = abs_x
        } else if abs_x < 0.8 {
            let excess = abs_x - 0.6
            shaped = 0.6 + excess * (1.0 - excess * 2.5)
        } else {
            let excess = abs_x - 0.8
            shaped = 0.775 + excess * (1.0 - excess * 5.0) * 0.5
        }

        return sign_x * min(shaped, 0.785) / 0.785
    }

    // MARK: - Tolerance Seeding

    /// Deterministic hash from voice index — each voice is a unique physical circuit.
    static func seedTolerance(voiceIndex: Int, warm: Float) -> SchmynthTolerance {
        var hash = UInt64(truncatingIfNeeded: voiceIndex &* 2654435761)

        func hashFloat(_ h: inout UInt64) -> Float {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return Float(h >> 33) / Float(UInt64(1) << 31)
        }

        let scale = warm

        return SchmynthTolerance(
            rCharge:       (hashFloat(&hash) - 0.5) * 0.06 * scale,
            rDischarge:    (hashFloat(&hash) - 0.5) * 0.08 * scale,
            cap:           (hashFloat(&hash) - 0.5) * 0.05 * scale,
            thresholdBias: (hashFloat(&hash) - 0.5) * 0.10 * scale,
            scfRC0:        (hashFloat(&hash) - 0.5) * 0.04 * scale,
            scfRC1:        (hashFloat(&hash) - 0.5) * 0.04 * scale,
            scfRC2:        (hashFloat(&hash) - 0.5) * 0.04 * scale,
            scfRC3:        (hashFloat(&hash) - 0.5) * 0.04 * scale,
            scfGain0:      (hashFloat(&hash) - 0.5) * 0.03 * scale,
            scfGain1:      (hashFloat(&hash) - 0.5) * 0.03 * scale,
            scfGain2:      (hashFloat(&hash) - 0.5) * 0.03 * scale,
            scfGain3:      (hashFloat(&hash) - 0.5) * 0.03 * scale,
            envCapOffset:  (hashFloat(&hash) - 0.5) * 0.02 * scale
        )
    }
}
