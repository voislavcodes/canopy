import Foundation

/// Shared Schmitt trigger oscillator circuit — used by both FUSE and VOLT engines.
/// Zero-size enum namespace. All methods are `@inline(__always) static` for audio-thread safety.
///
/// The capacitor charges toward supply and discharges toward ground,
/// switching at hysteresis thresholds. The waveform EMERGES from this.
enum SchmittCircuit {

    /// Render one sample of a Schmitt trigger oscillator circuit.
    ///
    /// - Parameters:
    ///   - capVoltage: Capacitor voltage state (mutated in place)
    ///   - switchState: true = charging, false = discharging (mutated in place)
    ///   - supplyV: Supply voltage powering the circuit
    ///   - targetFreq: Target oscillation frequency in Hz
    ///   - soul: Operating point / hysteresis width (0–1)
    ///   - tolerance: Component tolerance offsets (rCharge, rDischarge, cap, thresholdBias)
    ///   - warm: WARM amount scaling tolerance influence (0–1)
    ///   - couplingInput: External frequency modulation input
    ///   - keyTracking: true = TRACK mode (exact RC), false = FREE mode (pitch-dependent character)
    ///   - sampleRate: Audio sample rate
    /// - Returns: (triangleOut, squareOut, current) — normalized waveforms and current draw
    @inline(__always)
    static func render(
        capVoltage: inout Float,
        switchState: inout Bool,
        supplyV: Float,
        targetFreq: Float,
        soul: Float,
        tolerance: (rCharge: Float, rDischarge: Float, cap: Float, thresholdBias: Float),
        warm: Float,
        couplingInput: Float,
        keyTracking: Bool = false,
        sampleRate: Float = 48000
    ) -> (triangleOut: Float, squareOut: Float, current: Float) {

        // === Threshold calculation from Soul ===
        let hysteresisWidth = 0.8 - soul * 0.6  // 0.8 at Soul=0 → 0.2 at Soul=100
        let centerBias = 0.5 + tolerance.thresholdBias * warm

        let vThreshHigh = centerBias + hysteresisWidth * 0.5
        let vThreshLow = centerBias - hysteresisWidth * 0.5

        // Clamp thresholds to valid range (Rule 2: no singularities)
        let vth = min(max(vThreshHigh, 0.15), 0.95)
        let vtl = max(min(vThreshLow, vth - 0.05), 0.05)

        // === Charge/discharge rates ===
        let asymmetry = 1.0 + soul * 0.4 + tolerance.rDischarge * warm

        let chargeRate: Float
        let dischargeRate: Float

        if keyTracking {
            // TRACK mode: exact RC physics solving.
            let effectiveSupply = max(supplyV, vth + 0.01)
            let lnCharge = logf(max((effectiveSupply - vtl) / max(effectiveSupply - vth, 0.001), 1.001))
            let lnDischarge = logf(max(vth / max(vtl, 0.001), 1.001))
            let periodSamples = sampleRate / max(targetFreq + couplingInput, 0.1)
            let masterRate = (lnCharge + lnDischarge * asymmetry) / max(periodSamples * (1.0 + asymmetry), 1.0)
            chargeRate = masterRate * (1.0 + asymmetry)
            dischargeRate = masterRate * (1.0 + asymmetry) / max(asymmetry, 0.01)
        } else {
            // FREE mode: original approximate rate calculation.
            let threshRatio = max(vth / max(vtl, 0.01), 1.01)
            let chargeRatio = max(supplyV / max(supplyV - vth + vtl, 0.01), 1.01)

            let totalPeriod = 1.0 / max(targetFreq + couplingInput, 0.1)
            let tChargeFraction = 1.0 / (1.0 + asymmetry)
            let tDischargeFraction = asymmetry / (1.0 + asymmetry)

            chargeRate = logf(chargeRatio) / max(totalPeriod * tChargeFraction * sampleRate, 1)
            dischargeRate = logf(threshRatio) / max(totalPeriod * tDischargeFraction * sampleRate, 1)
        }

        // Apply component tolerance
        let adjChargeRate = chargeRate * (1.0 + tolerance.rCharge * warm)
        let adjDischargeRate = dischargeRate * (1.0 + tolerance.rDischarge * warm)

        // === Circuit simulation ===
        var current: Float = 0

        if switchState {
            // CHARGING: capacitor approaches supply voltage
            let delta = (supplyV - capVoltage) * adjChargeRate
            capVoltage += delta
            current = delta

            if capVoltage >= vth {
                switchState = false
                let overshoot = capVoltage - vth
                capVoltage = vth + overshoot * 0.3
            }
        } else {
            // DISCHARGING: capacitor approaches ground
            let delta = capVoltage * adjDischargeRate
            capVoltage -= delta
            current = -delta

            if capVoltage <= vtl {
                switchState = true
                let undershoot = vtl - capVoltage
                capVoltage = vtl - undershoot * 0.3
            }
        }

        // === Output signals ===
        let triangleCenter = (vth + vtl) * 0.5
        let triangleRange = max((vth - vtl) * 0.5, 0.01)
        let triangleOut = (capVoltage - triangleCenter) / triangleRange

        let squareOut: Float = switchState ? 1.0 : -1.0

        return (triangleOut, squareOut, abs(current))
    }
}
