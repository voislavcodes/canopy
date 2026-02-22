import Foundation

/// Parameters broadcast to all FUSE voices from the audio thread.
/// All values 0–1, matching FuseConfig ranges.
struct FuseParams {
    var soul: Float = 0.25
    var tune: Float = 0.05
    var couple: Float = 0.08
    var body: Float = 0.15
    var color: Float = 0.35
    var warm: Float = 0.3
    var keyTracking: Bool = true
}

/// Component-level tolerance — each voice is a DIFFERENT physical circuit.
/// Seeded deterministically from voice index so each voice has unique character.
struct FuseCircuitTolerance {
    // Circuit A components
    var rChargeA: Float = 0           // charge resistor offset (affects pitch + timbre)
    var rDischargeA: Float = 0        // discharge resistor offset (affects asymmetry)
    var capA: Float = 0               // capacitance offset (affects pitch)
    var thresholdBiasA: Float = 0     // threshold asymmetry (affects waveform shape)

    // Circuit B components
    var rChargeB: Float = 0
    var rDischargeB: Float = 0
    var capB: Float = 0
    var thresholdBiasB: Float = 0

    // Body
    var bodyFreqOffset: Float = 0     // resonant frequency offset
    var bodyQOffset: Float = 0        // Q offset

    // Coupling
    var couplingAsymmetry: Float = 0  // A→B vs B→A coupling imbalance
    var crossCapacitance: Float = 0   // parasitic capacitance between circuits
}

/// Coupling state between the two circuits within a voice.
struct FuseCouplingState {
    var sagCapacitor: Float = 0       // shared power supply sag (slow)
    var crosstalkLP: Float = 0        // crosstalk lowpass state
    var bleedAccum: Float = 0         // accumulated bleed energy
}

/// Per-voice DSP for FUSE virtual analog circuit synthesis.
/// Two Schmitt trigger oscillator circuits coupled through electrical interaction.
/// Supply voltage IS the envelope. Zero allocations, pure value type, audio-thread safe.
struct FuseVoice {
    // MARK: - Circuit A state
    var capVoltageA: Float = 0.3      // capacitor voltage (THE waveform)
    var switchStateA: Bool = true      // true = charging, false = discharging
    var prevOutputA: Float = 0         // previous sample output (for coupling, ADAA)
    var currentA: Float = 0            // current draw this sample

    // MARK: - Circuit B state
    var capVoltageB: Float = 0.3
    var switchStateB: Bool = true
    var prevOutputB: Float = 0
    var currentB: Float = 0

    // MARK: - Supply voltage (envelope)
    var supplyVoltage: Float = 0       // current Vcc — THIS is the envelope
    var supplyTarget: Float = 0        // target Vcc (>0 when gate on, 0 when off)
    var sagVoltage: Float = 0          // voltage drop from current draw

    // MARK: - Coupling
    var couplingState = FuseCouplingState()

    // MARK: - Resonant body state (SVF)
    var bodyStateLP: Float = 0
    var bodyStateBP: Float = 0

    // MARK: - Pitch
    var noteFreq: Float = 440
    var glideFreq: Float = 440

    // MARK: - Per-voice circuit "personality"
    var tolerance = FuseCircuitTolerance()

    // MARK: - WARM state
    var warmState = WarmVoiceState()

    // MARK: - Smoothed parameters
    var soulSmooth: Float = 0.25
    var tuneSmooth: Float = 0.05
    var coupleSmooth: Float = 0.08
    var bodySmooth: Float = 0.15
    var colorSmooth: Float = 0.35

    // MARK: - Voice state
    var velocity: Float = 0
    var gate: Bool = false
    private(set) var isActive: Bool = false

    /// Envelope level for voice stealing — supply voltage IS energy.
    var envelopeLevel: Float { supplyVoltage }

    // MARK: - Note Control

    mutating func noteOn(pitch: Int, velocity: Float, sampleRate: Float) {
        self.noteFreq = Float(MIDIUtilities.frequency(forNote: pitch))
        self.velocity = velocity
        self.gate = true
        self.isActive = true
        // Don't reset cap voltages — allows re-triggering during decay for legato
        // The circuit continues from its current state, supply ramps up
        if supplyVoltage < 0.001 {
            // Cold start: initialize caps to mid-threshold so oscillation begins immediately
            capVoltageA = 0.3
            capVoltageB = 0.3
            switchStateA = true
            switchStateB = true
        }
        glideFreq = noteFreq
    }

    mutating func noteOff() {
        gate = false
        // Supply will drain exponentially in renderSample
    }

    mutating func kill() {
        gate = false
        isActive = false
        supplyVoltage = 0
        supplyTarget = 0
        capVoltageA = 0.3
        capVoltageB = 0.3
        switchStateA = true
        switchStateB = true
        prevOutputA = 0
        prevOutputB = 0
        currentA = 0
        currentB = 0
        sagVoltage = 0
        couplingState = FuseCouplingState()
        bodyStateLP = 0
        bodyStateBP = 0
    }

    // MARK: - Render

    /// Render one sample through the full FUSE signal chain.
    mutating func renderSample(sampleRate: Float, params: FuseParams) -> Float {
        guard isActive else { return 0 }

        // === Smooth parameters (Rule 5) ===
        let smoothRate: Float = 0.002
        soulSmooth += (params.soul - soulSmooth) * smoothRate
        coupleSmooth += (params.couple - coupleSmooth) * smoothRate
        bodySmooth += (params.body - bodySmooth) * smoothRate
        colorSmooth += (params.color - colorSmooth) * smoothRate
        tuneSmooth += (params.tune - tuneSmooth) * 0.0005  // slower for pitch

        let soul = soulSmooth
        let couple = coupleSmooth
        let body = bodySmooth
        let color = colorSmooth
        let tune = tuneSmooth
        let warm = params.warm

        // === Supply voltage (THE envelope) ===
        let maxSupply: Float = 0.3 + velocity * 0.7

        if gate {
            supplyTarget = maxSupply
            let chargeSpeed: Float = 0.01 + soul * 0.02
            supplyVoltage += (supplyTarget - supplyVoltage) * chargeSpeed
        } else {
            supplyTarget = 0
            let drainRate: Float = 0.9997 - soul * 0.0003
            supplyVoltage *= drainRate
            if supplyVoltage < 0.001 {
                supplyVoltage = 0
                isActive = false
                return 0
            }
        }

        // === Power sag (shared between circuits) ===
        let effectiveSupply = max(supplyVoltage - sagVoltage, 0)
        if effectiveSupply < 0.001 { return 0 }

        // === Frequency calculation ===
        let baseFreq = glideFreq
        let (ratioA, ratioB) = FuseVoice.fuseRatios(tune: tune)

        let tol = tolerance
        let keyTracking = params.keyTracking
        let freqTolScale: Float = keyTracking ? 0.0 : 1.0
        let freqA = baseFreq * ratioA * (1.0 + tol.capA * warm * freqTolScale) * (1.0 + tol.rChargeA * warm * freqTolScale)
        let freqB = baseFreq * ratioB * (1.0 + tol.capB * warm * freqTolScale) * (1.0 + tol.rChargeB * warm * freqTolScale)

        // === Coupling computation ===
        let (freqModA, freqModB, sagAmount) = FuseVoice.computeCoupling(
            outputA: prevOutputA,
            outputB: prevOutputB,
            currentA: currentA,
            currentB: currentB,
            couple: couple,
            tolerance: tol,
            warm: warm,
            state: &couplingState
        )
        sagVoltage = sagAmount

        // Apply coupling to frequencies
        let coupledFreqA = max(freqA + freqModA * freqA * couple * 2.0, 0.1)
        let coupledFreqB = max(freqB + freqModB * freqB * couple * 2.0, 0.1)

        // Clamp (Rule 8)
        let clampedFreqA = min(coupledFreqA, 0.48 * sampleRate)
        let clampedFreqB = min(coupledFreqB, 0.48 * sampleRate)

        // === Render Circuit A ===
        let (triA, sqA, curA) = FuseVoice.renderSchmittCircuit(
            capVoltage: &capVoltageA,
            switchState: &switchStateA,
            supplyV: effectiveSupply,
            targetFreq: clampedFreqA,
            soul: soul,
            tolerance: (tol.rChargeA, tol.rDischargeA, tol.capA, tol.thresholdBiasA),
            warm: warm,
            couplingInput: freqModA * couple,
            keyTracking: keyTracking,
            sampleRate: sampleRate
        )
        currentA = curA

        // === Render Circuit B ===
        let (triB, sqB, curB) = FuseVoice.renderSchmittCircuit(
            capVoltage: &capVoltageB,
            switchState: &switchStateB,
            supplyV: effectiveSupply,
            targetFreq: clampedFreqB,
            soul: soul,
            tolerance: (tol.rChargeB, tol.rDischargeB, tol.capB, tol.thresholdBiasB),
            warm: warm,
            couplingInput: freqModB * couple,
            keyTracking: keyTracking,
            sampleRate: sampleRate
        )
        currentB = curB

        // === Color blend (triangle ↔ square) ===
        let blend = color * color  // quadratic
        let outA = triA * (1.0 - blend) + sqA * blend
        let outB = triB * (1.0 - blend) + sqB * blend

        // === ADAA on the waveshape blend ===
        let adaaOutA = FuseVoice.adaaBlend(current: outA, previous: prevOutputA)
        let adaaOutB = FuseVoice.adaaBlend(current: outB, previous: prevOutputB)

        prevOutputA = outA
        prevOutputB = outB

        // === Mix circuits ===
        let circuitMix = (adaaOutA + adaaOutB) * 0.5

        // === Scale by supply voltage (amplitude IS supply) ===
        let envMix = circuitMix * effectiveSupply

        // === Resonant Body ===
        let bodyOut = FuseVoice.processBody(
            input: envMix,
            body: body,
            color: color,
            noteFreq: baseFreq,
            tolerance: tol,
            warm: warm,
            lpState: &bodyStateLP,
            bpState: &bodyStateBP,
            sampleRate: sampleRate
        )

        // === Body/direct blend ===
        let bodyBlend = body * body  // quadratic: mostly direct at low values
        let mixed = envMix * (1.0 - bodyBlend) + bodyOut * bodyBlend

        // === Output limiting (Rule 6) ===
        return tanhf(mixed * 2.0)
    }

    // MARK: - Schmitt Trigger Oscillator

    /// Render one sample of a Schmitt trigger oscillator circuit.
    /// Forwards to `SchmittCircuit.render()` — the shared implementation used by FUSE and VOLT.
    @inline(__always)
    static func renderSchmittCircuit(
        capVoltage: inout Float,
        switchState: inout Bool,
        supplyV: Float,
        targetFreq: Float,
        soul: Float,
        tolerance: (rCharge: Float, rDischarge: Float, cap: Float, thresholdBias: Float),
        warm: Float,
        couplingInput: Float,
        keyTracking: Bool,
        sampleRate: Float
    ) -> (triangleOut: Float, squareOut: Float, current: Float) {
        SchmittCircuit.render(
            capVoltage: &capVoltage,
            switchState: &switchState,
            supplyV: supplyV,
            targetFreq: targetFreq,
            soul: soul,
            tolerance: tolerance,
            warm: warm,
            couplingInput: couplingInput,
            keyTracking: keyTracking,
            sampleRate: sampleRate
        )
    }

    // MARK: - Coupling Model

    /// Compute coupling between circuits through four physical mechanisms:
    /// 1. Power supply sag (always present)
    /// 2. Capacitive crosstalk (HF bleed)
    /// 3. Ground noise bleed (quadratic onset)
    /// 4. Direct FM (cubic onset above 30%)
    @inline(__always)
    static func computeCoupling(
        outputA: Float,
        outputB: Float,
        currentA: Float,
        currentB: Float,
        couple: Float,
        tolerance: FuseCircuitTolerance,
        warm: Float,
        state: inout FuseCouplingState
    ) -> (freqModA: Float, freqModB: Float, sagAmount: Float) {

        // Layer 1: Power Supply Sag
        let totalCurrent = currentA + currentB
        let sagTarget = totalCurrent * 0.05 * (warm * 0.5 + couple * 0.5)
        state.sagCapacitor += (sagTarget - state.sagCapacitor) * 0.001
        let sagAmount = state.sagCapacitor

        // Layer 2: Capacitive Crosstalk
        let crosstalkStrength = tolerance.crossCapacitance * warm + couple * 0.05
        let crosstalkA = outputB * crosstalkStrength
        let crosstalkB = outputA * crosstalkStrength

        // Layer 3: Ground Noise Bleed (quadratic onset)
        let bleedStrength = couple * couple * 0.3
        let bleedA = outputB * bleedStrength * (1.0 + tolerance.couplingAsymmetry * warm)
        let bleedB = outputA * bleedStrength * (1.0 - tolerance.couplingAsymmetry * warm)

        // Layer 4: Direct FM (cubic onset above 30%)
        let fmStrength = max(couple - 0.3, 0) / 0.7
        let fmDepth = fmStrength * fmStrength * fmStrength
        let fmModA = outputB * fmDepth * 2.0
        let fmModB = outputA * fmDepth * 2.0

        // Combined
        let totalModA = crosstalkA + bleedA + fmModA
        let totalModB = crosstalkB + bleedB + fmModB

        return (totalModA, totalModB, sagAmount)
    }

    // MARK: - Resonant Body

    /// SVF resonator tuned to note frequency (or harmonic via Color).
    /// Models a resonant body that both circuits excite.
    @inline(__always)
    static func processBody(
        input: Float,
        body: Float,
        color: Float,
        noteFreq: Float,
        tolerance: FuseCircuitTolerance,
        warm: Float,
        lpState: inout Float,
        bpState: inout Float,
        sampleRate: Float
    ) -> Float {
        let bodyFreqMultiple = 1.0 + color * 3.0
        let bodyFreq = noteFreq * bodyFreqMultiple * (1.0 + tolerance.bodyFreqOffset * warm)
        let clampedBodyFreq = min(bodyFreq, 0.48 * sampleRate)

        let bodyQ = 0.5 + body * body * 20.0
        let adjustedQ = bodyQ * (1.0 + tolerance.bodyQOffset * warm)

        let f = 2.0 * sinf(.pi * clampedBodyFreq / sampleRate)
        let q = 1.0 / max(adjustedQ, 0.5)

        lpState += f * bpState
        let hp = input - lpState - q * bpState
        bpState += f * hp

        // Clamp SVF states to prevent blowup (Rule 4)
        lpState = max(-4.0, min(4.0, lpState))
        bpState = max(-4.0, min(4.0, bpState))

        return bpState * 0.7 + lpState * 0.3
    }

    // MARK: - ADAA

    /// First-order anti-derivative antialiasing for the color blend transition.
    @inline(__always)
    static func adaaBlend(current: Float, previous: Float) -> Float {
        let diff = current - previous
        if abs(diff) < 1e-6 {
            return current
        }
        // First-order ADAA: average of current and previous
        return (current + previous) * 0.5
    }

    // MARK: - Tune Curve

    /// Piecewise frequency ratio mapping from Tune parameter (0–1).
    /// 0–10%: unison detune (±7 cents)
    /// 10–25%: unison to fifth (1.0 to 1.5)
    /// 25–50%: fifth to octave to 3× (1.5 to 3.0)
    /// 50–75%: enharmonic ratios (3.0 to 7.0)
    /// 75–100%: extreme spread (7.0 to 17.0)
    @inline(__always)
    static func fuseRatios(tune: Float) -> (ratioA: Float, ratioB: Float) {
        let ratioB: Float
        if tune < 0.10 {
            // Unison detune: ±7 cents
            let detuneCents = (tune / 0.10) * 7.0
            ratioB = powf(2.0, detuneCents / 1200.0)
        } else if tune < 0.25 {
            // Unison to fifth
            let t = (tune - 0.10) / 0.15
            ratioB = 1.0 + t * 0.5  // 1.0 → 1.5
        } else if tune < 0.50 {
            // Fifth to 3×
            let t = (tune - 0.25) / 0.25
            ratioB = 1.5 + t * 1.5  // 1.5 → 3.0
        } else if tune < 0.75 {
            // Enharmonic: 3× to 7×
            let t = (tune - 0.50) / 0.25
            ratioB = 3.0 + t * 4.0  // 3.0 → 7.0
        } else {
            // Extreme spread: 7× to 17×
            let t = (tune - 0.75) / 0.25
            ratioB = 7.0 + t * 10.0 // 7.0 → 17.0
        }
        return (1.0, ratioB)
    }

    // MARK: - Tolerance Seeding

    /// Deterministic hash from voice index — each voice is a unique physical circuit.
    static func seedTolerance(voiceIndex: Int, warm: Float) -> FuseCircuitTolerance {
        var hash = UInt64(truncatingIfNeeded: voiceIndex &* 2654435761)

        func hashFloat(_ h: inout UInt64) -> Float {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return Float(h >> 33) / Float(UInt64(1) << 31)
        }

        let scale = warm

        return FuseCircuitTolerance(
            rChargeA:         (hashFloat(&hash) - 0.5) * 0.06 * scale,
            rDischargeA:      (hashFloat(&hash) - 0.5) * 0.08 * scale,
            capA:             (hashFloat(&hash) - 0.5) * 0.05 * scale,
            thresholdBiasA:   (hashFloat(&hash) - 0.5) * 0.10 * scale,
            rChargeB:         (hashFloat(&hash) - 0.5) * 0.06 * scale,
            rDischargeB:      (hashFloat(&hash) - 0.5) * 0.08 * scale,
            capB:             (hashFloat(&hash) - 0.5) * 0.05 * scale,
            thresholdBiasB:   (hashFloat(&hash) - 0.5) * 0.10 * scale,
            bodyFreqOffset:   (hashFloat(&hash) - 0.5) * 0.04 * scale,
            bodyQOffset:      (hashFloat(&hash) - 0.5) * 0.06 * scale,
            couplingAsymmetry:(hashFloat(&hash) - 0.5) * 0.15 * scale,
            crossCapacitance: hashFloat(&hash) * 0.002 * scale
        )
    }
}
