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

    // Pink noise floor (Paul Kellet 3-stage approximation)
    var pinkState0: Float = 0
    var pinkState1: Float = 0
    var pinkState2: Float = 0
    var noiseRNG: UInt32 = 54321

    // HF rolloff (one-pole lowpass)
    var hfStateL: Float = 0
    var hfStateR: Float = 0
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
///   pitch drift (control rate) → asymmetric saturation (ADAA) → DC block → pink noise → HF rolloff
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

        // RNG seeds (ensure non-zero)
        h = h &* 1664525 &+ 1013904223
        state.driftRNG = h | 1
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

    /// Process a single mono sample through the WARM chain:
    ///   saturation (ADAA) → DC block → pink noise → HF rolloff.
    /// WARM=0 returns input unchanged (true bypass).
    @inline(__always)
    static func processSample(
        _ state: inout WarmVoiceState, sample: Float,
        warm: Float, sampleRate: Float
    ) -> Float {
        guard warm > 0.001 else { return sample }

        var x = sample
        let w2 = warm * warm
        let w3 = w2 * warm

        // --- 1. Asymmetric saturation with first-order ADAA ---
        let drive: Float = 1.0 + warm * 3.0   // linear: 1→4
        let wetMix = w2                         // quadratic onset

        let driven = x * drive + state.satBiasOffset * w2
        let saturated = adaaSaturate(&state, sample: driven, isLeft: true)
        x = x * (1.0 - wetMix) + saturated * wetMix

        // Gain offset (component tolerance, quadratic)
        x *= 1.0 + state.gainOffset * w2

        // --- 2. DC blocker ---
        let dcOut = x - state.dcPrevInL + 0.995 * state.dcPrevOutL
        state.dcPrevInL = x
        state.dcPrevOutL = dcOut
        x = dcOut

        // --- 3. Pink noise floor (cubic scaling — inaudible until WARM > 50%) ---
        x += pinkNoise(&state) * w3 * 0.0005

        // --- 4. HF rolloff (one-pole lowpass, linear cutoff 22kHz→12kHz) ---
        let cutoff = 22000.0 - warm * 10000.0
        let cutoffVar = cutoff * (1.0 + state.hfCutoffOffset * w2)
        let hfCoeff = 1.0 - expf(-2.0 * .pi * cutoffVar / sampleRate)
        state.hfStateL += (x - state.hfStateL) * hfCoeff
        x = state.hfStateL

        return x
    }

    // MARK: - Sample Processing (Stereo)

    /// Process a stereo pair through the WARM chain.
    /// Each channel gets independent ADAA state and DC blocking.
    @inline(__always)
    static func processStereo(
        _ state: inout WarmVoiceState, sampleL: Float, sampleR: Float,
        warm: Float, sampleRate: Float
    ) -> (Float, Float) {
        guard warm > 0.001 else { return (sampleL, sampleR) }

        var xL = sampleL
        var xR = sampleR
        let w2 = warm * warm
        let w3 = w2 * warm

        // --- 1. Asymmetric saturation with ADAA ---
        let drive: Float = 1.0 + warm * 3.0
        let wetMix = w2

        let drivenL = xL * drive + state.satBiasOffset * w2
        let drivenR = xR * drive + state.satBiasOffset * w2
        let satL = adaaSaturate(&state, sample: drivenL, isLeft: true)
        let satR = adaaSaturate(&state, sample: drivenR, isLeft: false)
        xL = xL * (1.0 - wetMix) + satL * wetMix
        xR = xR * (1.0 - wetMix) + satR * wetMix

        // Gain offset
        let gainMul = 1.0 + state.gainOffset * w2
        xL *= gainMul
        xR *= gainMul

        // --- 2. DC blocker (L) ---
        let dcOutL = xL - state.dcPrevInL + 0.995 * state.dcPrevOutL
        state.dcPrevInL = xL
        state.dcPrevOutL = dcOutL
        xL = dcOutL

        // DC blocker (R)
        let dcOutR = xR - state.dcPrevInR + 0.995 * state.dcPrevOutR
        state.dcPrevInR = xR
        state.dcPrevOutR = dcOutR
        xR = dcOutR

        // --- 3. Pink noise floor ---
        let noiseScale = w3 * 0.0005
        xL += pinkNoise(&state) * noiseScale
        xR += pinkNoise(&state) * noiseScale

        // --- 4. HF rolloff ---
        let cutoff = 22000.0 - warm * 10000.0
        let cutoffVar = cutoff * (1.0 + state.hfCutoffOffset * w2)
        let hfCoeff = 1.0 - expf(-2.0 * .pi * cutoffVar / sampleRate)
        state.hfStateL += (xL - state.hfStateL) * hfCoeff
        xL = state.hfStateL
        state.hfStateR += (xR - state.hfStateR) * hfCoeff
        xR = state.hfStateR

        return (xL, xR)
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

    // MARK: - Private: Saturation

    /// Asymmetric soft-clip with first-order ADAA (anti-derivative anti-aliasing).
    /// Positive: x/(1+x) — soft knee, odd harmonics dominant.
    /// Negative: x/(1-0.8x) — harder knee, generates even harmonics.
    /// The asymmetry creates even+odd harmonic content like real analog circuits.
    @inline(__always)
    private static func adaaSaturate(
        _ state: inout WarmVoiceState, sample x: Float, isLeft: Bool
    ) -> Float {
        let prevX = isLeft ? state.prevSampleL : state.prevSampleR
        let diff = x - prevX

        let result: Float
        if abs(diff) < 1e-5 {
            // Near-zero difference: use direct evaluation (avoids division by ~0)
            result = saturate(x)
        } else {
            // First-order ADAA: (F(x) - F(x_prev)) / (x - x_prev)
            result = (saturateAntideriv(x) - saturateAntideriv(prevX)) / diff
        }

        if isLeft {
            state.prevSampleL = x
        } else {
            state.prevSampleR = x
        }

        return result
    }

    /// Asymmetric saturation function.
    /// Positive: x/(1+x) — asymptotes to 1.
    /// Negative: x/(1-0.8x) — asymptotes to -1.25 (harder clip).
    @inline(__always)
    private static func saturate(_ x: Float) -> Float {
        if x >= 0 {
            return x / (1.0 + x)
        } else {
            return x / (1.0 - 0.8 * x)
        }
    }

    /// Antiderivative of the asymmetric saturation function.
    /// Positive: F(x) = x - ln(1+x)
    /// Negative: F(x) = -1.5625·ln(1-0.8x) - 1.25x
    /// Both branches are continuous and equal at x=0 (F(0)=0).
    @inline(__always)
    private static func saturateAntideriv(_ x: Float) -> Float {
        if x >= 0 {
            return x - logf(1.0 + x)
        } else {
            return -1.5625 * logf(1.0 - 0.8 * x) - 1.25 * x
        }
    }

    // MARK: - Private: Pink Noise

    /// Pink noise via Paul Kellet's 3-stage approximation.
    /// Uses per-voice xorshift LCG for decorrelated noise across voices.
    @inline(__always)
    private static func pinkNoise(_ state: inout WarmVoiceState) -> Float {
        // White noise source (LCG)
        state.noiseRNG = state.noiseRNG &* 1664525 &+ 1013904223
        let white = Float(Int32(bitPattern: state.noiseRNG)) / Float(Int32.max)

        // Paul Kellet's pink noise filter (3 one-pole stages)
        state.pinkState0 = 0.99886 * state.pinkState0 + white * 0.0555179
        state.pinkState1 = 0.99332 * state.pinkState1 + white * 0.0750759
        state.pinkState2 = 0.96900 * state.pinkState2 + white * 0.1538520

        let pink = state.pinkState0 + state.pinkState1 + state.pinkState2 + white * 0.5362
        return pink * 0.2  // normalize to roughly ±1
    }
}
