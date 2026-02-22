import Foundation

/// Per-voice analog warmth state. Flat struct — no heap, no ARC.
/// All scalar fields, embedded directly in each voice struct.
/// Audio-thread safe: zero allocations, zero reference counting.
struct WarmVoiceState {
    // Component tolerance (fixed at voice init, unique per voice)
    var pitchOffsetCents: Float = 0    // ±3 cents max
    var gainOffset: Float = 0          // ±0.17 linear (≈ ±1.5 dB)
    var satBiasOffset: Float = 0       // ±0.01 DC bias into saturation
    var hfCutoffOffset: Float = 0      // ±0.1 relative cutoff variation

    // Oscillator drift (3-band 1/f noise via one-pole filters)
    var driftState0: Float = 0         // slow (~0.1 Hz), ±5 cents
    var driftState1: Float = 0         // medium (~1 Hz), ±2 cents
    var driftState2: Float = 0         // fast (~5 Hz), ±1 cent
    var driftRNG: UInt32 = 12345

    // Cached drift multiplier (updated at control rate)
    var cachedDriftMul: Float = 1.0

    // Saturation ADAA (first-order anti-derivative anti-aliasing)
    var prevSampleL: Float = 0
    var prevSampleR: Float = 0

    // DC blocker state (y[n] = x[n] - x[n-1] + 0.995 * y[n-1])
    var dcPrevInL: Float = 0
    var dcPrevOutL: Float = 0
    var dcPrevInR: Float = 0
    var dcPrevOutR: Float = 0

    // HF rolloff (one-pole lowpass)
    var hfStateL: Float = 0
    var hfStateR: Float = 0

    // 2x oversampling state for saturation anti-aliasing
    var oversamplePrevL: Float = 0
    var oversamplePrevR: Float = 0

    // Pink noise floor (thermal noise simulation)
    var noiseRNG: UInt32 = 54321
    var pinkState0: Float = 0    // slow band (~1 Hz corner)
    var pinkState1: Float = 0    // mid band (~5 Hz corner)
    var pinkState2: Float = 0    // fast band (~25 Hz corner)
}

/// Per-manager (node-level) analog warmth state for inter-voice power sag.
/// Simulates power supply droop under heavy polyphonic load.
struct WarmNodeState {
    var sagEnvelope: Float = 0
}

/// Central WARM DSP processor. All static functions — no instances, no state.
/// Every function takes state as `inout` for audio-thread safety.
///
/// Signal chain per voice:
///   pitch drift (control rate) → 2x oversampled [asymmetric saturation (ADAA) → DC block → pink noise → HF rolloff]
///
/// Signal chain per manager (post voice sum):
///   power sag → safety tanh
enum WarmProcessor {

    // MARK: - Voice Seeding

    /// Deterministic hash of voice index → unique tolerance offsets + RNG seeds.
    /// Called once during manager init. Each voice gets a unique analog "character."
    static func seedVoice(_ state: inout WarmVoiceState, voiceIndex: Int) {
        var h = UInt32(voiceIndex) &* 2654435761 // golden ratio hash
        h ^= h >> 16

        // pitchOffsetCents: ±3 cents
        h = h &* 1664525 &+ 1013904223
        state.pitchOffsetCents = Float(Int32(bitPattern: h)) / Float(Int32.max) * 3.0

        // gainOffset: ±1.5 dB ≈ ±0.17 linear
        h = h &* 1664525 &+ 1013904223
        state.gainOffset = Float(Int32(bitPattern: h)) / Float(Int32.max) * 0.17

        // satBiasOffset: ±0.01 (subtle asymmetry variation per voice)
        h = h &* 1664525 &+ 1013904223
        state.satBiasOffset = Float(Int32(bitPattern: h)) / Float(Int32.max) * 0.01

        // hfCutoffOffset: ±0.1 (relative cutoff frequency variation)
        h = h &* 1664525 &+ 1013904223
        state.hfCutoffOffset = Float(Int32(bitPattern: h)) / Float(Int32.max) * 0.1

        // Drift RNG seed (ensure non-zero)
        h = h &* 1664525 &+ 1013904223
        state.driftRNG = h | 1

        // Noise RNG seed (different sequence from drift)
        h = h &* 1664525 &+ 1013904223
        state.noiseRNG = h | 1
    }

    // MARK: - Pitch Drift

    /// Compute pitch offset in cents (tolerance + 3-band drift).
    /// Call at control rate (~every 64 samples). Convert result to frequency multiplier:
    ///   `multiplier = powf(2.0, cents / 1200.0)`
    ///
    /// Scaling: tolerance = quadratic (w²), drift = cubic (w³).
    @inline(__always)
    static func computePitchOffset(_ state: inout WarmVoiceState, warm: Float, sampleRate: Float) -> Float {
        guard warm > 0.001 else { return 0 }

        let w2 = warm * warm
        let w3 = w2 * warm

        // Tolerance: fixed per voice, quadratic scaling
        let toleranceCents = state.pitchOffsetCents * w2

        // 3-band drift: one-pole lowpass filters on white noise at different cutoffs
        let controlRate = sampleRate / 64.0
        let coeff0 = 1.0 - expf(-2.0 * .pi * 0.1 / controlRate)  // ~0.1 Hz
        let coeff1 = 1.0 - expf(-2.0 * .pi * 1.0 / controlRate)  // ~1 Hz
        let coeff2 = 1.0 - expf(-2.0 * .pi * 5.0 / controlRate)  // ~5 Hz

        // White noise source
        state.driftRNG = state.driftRNG &* 1664525 &+ 1013904223
        let noise = Float(Int32(bitPattern: state.driftRNG)) / Float(Int32.max)

        state.driftState0 += (noise - state.driftState0) * coeff0
        state.driftState1 += (noise - state.driftState1) * coeff1
        state.driftState2 += (noise - state.driftState2) * coeff2

        // Sum bands with different cent ranges, cubic scaling
        let driftCents = (state.driftState0 * 5.0
                        + state.driftState1 * 2.0
                        + state.driftState2 * 1.0) * w3

        return toleranceCents + driftCents
    }

    // MARK: - Sample Processing (Mono)

    /// Process a single mono sample through the 2x oversampled WARM chain:
    ///   saturation (ADAA) → DC block → HF rolloff.
    /// The entire chain runs at 2x rate to suppress aliasing from saturation harmonics.
    /// WARM=0 returns input unchanged (true bypass).
    @inline(__always)
    static func processSample(
        _ state: inout WarmVoiceState, sample: Float,
        warm: Float, sampleRate: Float
    ) -> Float {
        guard warm > 0.001 else { return sample }

        let w2 = warm * warm
        let drive: Float = 1.0 + warm * 3.0
        let wetMix = w2
        let gainMul = 1.0 + state.gainOffset * w2
        let noiseLevel = w2 * warm * 0.003  // cubic, ~-50dB at max

        // HF rolloff coefficient at 2x rate
        let cutoff = 22000.0 - warm * 10000.0
        let cutoffVar = cutoff * (1.0 + state.hfCutoffOffset * w2)
        let hfCoeff = 1.0 - expf(-2.0 * .pi * cutoffVar / (sampleRate * 2.0))

        // 2x oversample: interpolate midpoint, process full chain twice, average
        let mid = (state.oversamplePrevL + sample) * 0.5
        state.oversamplePrevL = sample

        let out1 = warmChainMono(
            &state, sample: mid,
            drive: drive, wetMix: wetMix, gainMul: gainMul,
            w2: w2, noiseLevel: noiseLevel, hfCoeff: hfCoeff
        )
        let out2 = warmChainMono(
            &state, sample: sample,
            drive: drive, wetMix: wetMix, gainMul: gainMul,
            w2: w2, noiseLevel: noiseLevel, hfCoeff: hfCoeff
        )

        return (out1 + out2) * 0.5
    }

    // MARK: - Sample Processing (Stereo)

    /// Process a stereo pair through the 2x oversampled WARM chain.
    /// Each channel gets independent ADAA state and DC blocking.
    @inline(__always)
    static func processStereo(
        _ state: inout WarmVoiceState, sampleL: Float, sampleR: Float,
        warm: Float, sampleRate: Float
    ) -> (Float, Float) {
        guard warm > 0.001 else { return (sampleL, sampleR) }

        let w2 = warm * warm
        let drive: Float = 1.0 + warm * 3.0
        let wetMix = w2
        let gainMul = 1.0 + state.gainOffset * w2
        let noiseLevel = w2 * warm * 0.003  // cubic, ~-50dB at max

        // HF rolloff coefficient at 2x rate
        let cutoff = 22000.0 - warm * 10000.0
        let cutoffVar = cutoff * (1.0 + state.hfCutoffOffset * w2)
        let hfCoeff = 1.0 - expf(-2.0 * .pi * cutoffVar / (sampleRate * 2.0))

        // 2x oversample: interpolate midpoints, process full chain twice, average
        let midL = (state.oversamplePrevL + sampleL) * 0.5
        let midR = (state.oversamplePrevR + sampleR) * 0.5
        state.oversamplePrevL = sampleL
        state.oversamplePrevR = sampleR

        let (outL1, outR1) = warmChainStereo(
            &state, sampleL: midL, sampleR: midR,
            drive: drive, wetMix: wetMix, gainMul: gainMul,
            w2: w2, noiseLevel: noiseLevel, hfCoeff: hfCoeff
        )
        let (outL2, outR2) = warmChainStereo(
            &state, sampleL: sampleL, sampleR: sampleR,
            drive: drive, wetMix: wetMix, gainMul: gainMul,
            w2: w2, noiseLevel: noiseLevel, hfCoeff: hfCoeff
        )

        return ((outL1 + outL2) * 0.5, (outR1 + outR2) * 0.5)
    }

    // MARK: - Power Sag (Stereo)

    /// Energy follower → gain reduction. Called after voice sum, before safety tanh.
    /// Simulates power supply droop under heavy polyphonic load.
    /// Quadratic depth scaling — negligible until mid-range WARM.
    @inline(__always)
    static func applyPowerSag(
        _ state: inout WarmNodeState, sampleL: Float, sampleR: Float,
        warm: Float
    ) -> (Float, Float) {
        guard warm > 0.15 else { return (sampleL, sampleR) }

        let w2 = warm * warm

        // Peak energy follower (fast attack, slow release)
        let energy = max(abs(sampleL), abs(sampleR))
        if energy > state.sagEnvelope {
            state.sagEnvelope += (energy - state.sagEnvelope) * 0.01    // fast attack
        } else {
            state.sagEnvelope += (energy - state.sagEnvelope) * 0.0001  // slow release
        }

        // Gain reduction: max ~3dB at full warm + heavy signal
        let sagGain = 1.0 / (1.0 + state.sagEnvelope * 0.3 * w2)

        return (sampleL * sagGain, sampleR * sagGain)
    }

    // MARK: - Power Sag (Mono)

    /// Mono variant of power sag for engines with mono voice sum.
    @inline(__always)
    static func applyPowerSagMono(
        _ state: inout WarmNodeState, sample: Float,
        warm: Float
    ) -> Float {
        guard warm > 0.15 else { return sample }

        let w2 = warm * warm
        let energy = abs(sample)
        if energy > state.sagEnvelope {
            state.sagEnvelope += (energy - state.sagEnvelope) * 0.01
        } else {
            state.sagEnvelope += (energy - state.sagEnvelope) * 0.0001
        }

        let sagGain = 1.0 / (1.0 + state.sagEnvelope * 0.3 * w2)
        return sample * sagGain
    }

    // MARK: - Private: Oversampled Chain

    /// Full inner chain for one mono sample: saturation ADAA → DC block → pink noise → HF rolloff.
    /// Called twice per output sample for 2x oversampling.
    @inline(__always)
    private static func warmChainMono(
        _ state: inout WarmVoiceState, sample: Float,
        drive: Float, wetMix: Float, gainMul: Float,
        w2: Float, noiseLevel: Float, hfCoeff: Float
    ) -> Float {
        var x = sample

        // Asymmetric saturation with ADAA
        let driven = x * drive + state.satBiasOffset * w2
        let saturated = adaaSaturate(&state, sample: driven, isLeft: true)
        x = x * (1.0 - wetMix) + saturated * wetMix

        // Gain offset
        x *= gainMul

        // DC blocker
        let dcOut = x - state.dcPrevInL + 0.995 * state.dcPrevOutL
        state.dcPrevInL = x
        state.dcPrevOutL = dcOut
        x = dcOut

        // Pink noise floor (thermal noise — dithers saturation, tamed by HF rolloff)
        x += pinkNoise(&state) * noiseLevel

        // HF rolloff
        state.hfStateL += (x - state.hfStateL) * hfCoeff
        x = state.hfStateL

        return x
    }

    /// Full inner chain for one stereo pair: saturation ADAA → DC block → pink noise → HF rolloff.
    /// Called twice per output sample for 2x oversampling.
    @inline(__always)
    private static func warmChainStereo(
        _ state: inout WarmVoiceState, sampleL: Float, sampleR: Float,
        drive: Float, wetMix: Float, gainMul: Float,
        w2: Float, noiseLevel: Float, hfCoeff: Float
    ) -> (Float, Float) {
        var xL = sampleL
        var xR = sampleR

        // Asymmetric saturation with ADAA
        let drivenL = xL * drive + state.satBiasOffset * w2
        let drivenR = xR * drive + state.satBiasOffset * w2
        let satL = adaaSaturate(&state, sample: drivenL, isLeft: true)
        let satR = adaaSaturate(&state, sample: drivenR, isLeft: false)
        xL = xL * (1.0 - wetMix) + satL * wetMix
        xR = xR * (1.0 - wetMix) + satR * wetMix

        // Gain offset
        xL *= gainMul
        xR *= gainMul

        // DC blocker (L)
        let dcOutL = xL - state.dcPrevInL + 0.995 * state.dcPrevOutL
        state.dcPrevInL = xL
        state.dcPrevOutL = dcOutL
        xL = dcOutL

        // DC blocker (R)
        let dcOutR = xR - state.dcPrevInR + 0.995 * state.dcPrevOutR
        state.dcPrevInR = xR
        state.dcPrevOutR = dcOutR
        xR = dcOutR

        // Pink noise floor (same sample for both channels — decorrelation
        // not perceptible at -50dB, saves 3 filter states per voice)
        let noise = pinkNoise(&state) * noiseLevel
        xL += noise
        xR += noise

        // HF rolloff
        state.hfStateL += (xL - state.hfStateL) * hfCoeff
        xL = state.hfStateL
        state.hfStateR += (xR - state.hfStateR) * hfCoeff
        xR = state.hfStateR

        return (xL, xR)
    }

    // MARK: - Private: Pink Noise

    /// 3-stage Voss-McCartney pink noise approximation.
    /// Three one-pole lowpass filters at different cutoffs (~1, 5, 25 Hz corners)
    /// sum with a white component to produce a roughly 1/f spectrum.
    /// Models thermal noise from semiconductor junctions.
    @inline(__always)
    private static func pinkNoise(_ state: inout WarmVoiceState) -> Float {
        // LCG white noise source
        state.noiseRNG = state.noiseRNG &* 1664525 &+ 1013904223
        let white = Float(Int32(bitPattern: state.noiseRNG)) / Float(Int32.max)

        // Three-stage pink approximation
        state.pinkState0 += (white - state.pinkState0) * 0.004
        state.pinkState1 += (white - state.pinkState1) * 0.02
        state.pinkState2 += (white - state.pinkState2) * 0.1

        return (state.pinkState0 + state.pinkState1 + state.pinkState2 + white * 0.5) * 0.25
    }

    // MARK: - Private: Saturation

    /// Asymmetric soft-clip with first-order ADAA (anti-derivative anti-aliasing).
    /// Positive: x/(1+x) — soft knee, odd harmonics dominant.
    /// Negative: x/(1-0.8x) — harder knee, generates even harmonics.
    /// The asymmetry creates even+odd harmonic content like real analog circuits.
    ///
    /// Uses Double precision for the ADAA computation to eliminate Float32
    /// cancellation noise — subtracting two close antiderivative values in Float
    /// destroys precision and produces audible crackle.
    @inline(__always)
    private static func adaaSaturate(
        _ state: inout WarmVoiceState, sample x: Float, isLeft: Bool
    ) -> Float {
        let prevX = isLeft ? state.prevSampleL : state.prevSampleR

        let result: Float
        if x == prevX {
            result = saturate(x)
        } else {
            // Double-precision ADAA: (F(x) - F(prev)) / (x - prev)
            // Float32 only has ~7 digits — subtracting close F values destroys
            // precision and creates noise. Double's ~15 digits eliminates this.
            let dx = Double(x)
            let dprev = Double(prevX)
            let dResult = (saturateAntiderivD(dx) - saturateAntiderivD(dprev)) / (dx - dprev)
            result = Float(dResult)
        }

        if isLeft {
            state.prevSampleL = x
        } else {
            state.prevSampleR = x
        }

        return result
    }

    /// Asymmetric saturation function (Float, for fallback when x == prev).
    @inline(__always)
    private static func saturate(_ x: Float) -> Float {
        if x >= 0 {
            return x / (1.0 + x)
        } else {
            return x / (1.0 - 0.8 * x)
        }
    }

    /// Double-precision antiderivative of the asymmetric saturation.
    /// Positive: F(x) = x - ln(1+x)
    /// Negative: F(x) = -1.5625·ln(1-0.8x) - 1.25x
    /// Uses log1p for precision with small values near zero.
    @inline(__always)
    private static func saturateAntiderivD(_ x: Double) -> Double {
        if x >= 0 {
            return x - log1p(x)
        } else {
            return -1.5625 * log1p(-0.8 * x) - 1.25 * x
        }
    }

}
