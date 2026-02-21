import Foundation

/// Ghost effect — living decay where the tail transforms, not just fades.
///
/// True stereo effect with separate L/R delay buffers, allpass chains, and filter state.
/// Each pass through the feedback loop applies cumulative blur (allpass diffusion),
/// shift (frequency-dependent decay + pitch drift), and wander (stochastic modulation).
///
/// Parameters:
/// - `life`: Feedback amount (0.0–1.0). 0 = single echo, 1 = infinite decay.
/// - `blur`: Allpass diffusion amount (0.0–1.0). 0 = clean delay, 1 = reverb-like wash.
/// - `shift`: Frequency-dependent decay + pitch drift (0.0–1.0). Higher = more spectral transformation.
/// - `wander`: Stochastic modulation depth (0.0–1.0). 0 = deterministic, 1 = ghosts wander in stereo.
/// - `delayTime`: Base delay time (0.0–1.0, maps to 50ms–2000ms).
struct GhostEffect {
    // MARK: - Buffer sizes

    /// 4 seconds at 48kHz — supports up to 2s delay with headroom for modulation
    private static let bufferSize = 192_000

    /// Allpass filter delays (prime numbers for maximal diffusion)
    private static let allpassDelays = [31, 67, 113, 179]

    // MARK: - Stereo delay buffers

    private let bufferL: UnsafeMutablePointer<Float>
    private let bufferR: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0

    // MARK: - Stereo allpass chains (4 per channel)

    private let allpassBufL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let allpassIdxL: UnsafeMutablePointer<Int>
    private let allpassBufR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let allpassIdxR: UnsafeMutablePointer<Int>

    // MARK: - Stereo filter state (3-band crossover: LP at 200Hz, HP at 4kHz)

    private var lpStateL: Double = 0   // Low-pass filter state, left
    private var lpStateR: Double = 0   // Low-pass filter state, right
    private var hpStateL: Double = 0   // High-pass filter state, left
    private var hpStateR: Double = 0   // High-pass filter state, right

    // MARK: - Stereo DC blockers (one-pole HP at 5Hz)

    private var dcX1L: Double = 0
    private var dcY1L: Double = 0
    private var dcX1R: Double = 0
    private var dcY1R: Double = 0

    // MARK: - Envelope followers (fast attack / slow release, per channel)

    private var envelopeL: Float = 0
    private var envelopeR: Float = 0

    // MARK: - Shared state

    private var pitchDrift: Double = 0       // Accumulated pitch drift (cents, shared)

    // LCG seeds — separate per channel
    private var wanderSeedL: UInt32 = 1_234_567
    private var wanderSeedR: UInt32 = 7_654_321

    // Wander modulation values (smoothed)
    private var blurMod: Double = 0          // Modulates effective blur
    private var shiftMod: Double = 0         // Modulates effective shift
    private var timeJitterL: Double = 0      // Per-channel delay time jitter
    private var timeJitterR: Double = 0
    private var panModulation: Double = 0    // Stereo drift (-1 to +1)

    // Smoothed wander values (separate smoothing for wander mods)
    private var blurModSmoothed: Double = 0
    private var shiftModSmoothed: Double = 0
    private var timeJitterLSmoothed: Double = 0
    private var timeJitterRSmoothed: Double = 0
    private var panModSmoothed: Double = 0

    // Wander cycle tracking
    private var wanderPhase: Double = 0

    // MARK: - Parameter targets

    private var life: Double = 0.6
    private var blur: Double = 0.4
    private var shift: Double = 0.3
    private var wander: Double = 0.2
    private var delayTime: Double = 0.25

    // MARK: - Smoothed parameters

    private var lifeSmoothed: Double = 0.6
    private var blurSmoothed: Double = 0.4
    private var shiftSmoothed: Double = 0.3
    private var wanderSmoothed: Double = 0.2
    private var delayTimeSmoothed: Double = 0.25

    // Smoothing coefficients
    private let paramSmooth: Double = 0.001      // Control parameters
    private let delaySmooth: Double = 0.0001     // Delay time (very slow)
    private let wanderModSmooth: Double = 0.005  // Wander modulation values

    // MARK: - Init

    init() {
        // Allocate stereo delay buffers
        bufferL = .allocate(capacity: Self.bufferSize)
        bufferL.initialize(repeating: 0, count: Self.bufferSize)
        bufferR = .allocate(capacity: Self.bufferSize)
        bufferR.initialize(repeating: 0, count: Self.bufferSize)

        // Allocate stereo allpass chains
        let apCount = Self.allpassDelays.count

        allpassBufL = .allocate(capacity: apCount)
        allpassIdxL = .allocate(capacity: apCount)
        allpassBufR = .allocate(capacity: apCount)
        allpassIdxR = .allocate(capacity: apCount)

        for i in 0..<apCount {
            let delay = Self.allpassDelays[i]

            let aL = UnsafeMutablePointer<Float>.allocate(capacity: delay)
            aL.initialize(repeating: 0, count: delay)
            allpassBufL[i] = aL
            allpassIdxL[i] = 0

            let aR = UnsafeMutablePointer<Float>.allocate(capacity: delay)
            aR.initialize(repeating: 0, count: delay)
            allpassBufR[i] = aR
            allpassIdxR[i] = 0
        }
    }

    // MARK: - Mono processing (L-channel state only)

    /// Process a single mono sample. Uses L-channel state only.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        smoothParameters()

        let delaySamples = computeDelaySamples(sampleRate: sampleRate)

        // Update wander modulations
        updateWander(sampleRate: sampleRate)
        smoothWanderMods()

        // Read from L buffer with cubic Hermite interpolation + drift + jitter
        let driftOffset = pitchDrift * Double(sampleRate) / (1200.0 * 100.0)
        let readDelay = delaySamples + driftOffset + timeJitterLSmoothed * Double(sampleRate) * 0.001
        let delayed = Self.cubicRead(buffer: bufferL, writeIndex: writeIndex, delaySamples: readDelay)

        // Blur: allpass diffusion on L channel
        let effectiveBlur = Float(blurSmoothed + blurModSmoothed * wanderSmoothed * 0.3)
        let clampedBlur = max(Float(0), min(Float(1), effectiveBlur))
        var diffused = delayed
        for i in 0..<Self.allpassDelays.count {
            Self.processAllpass(input: &diffused, buf: allpassBufL[i], idx: &allpassIdxL[i],
                                delay: Self.allpassDelays[i])
        }
        var processed = delayed * (1.0 - clampedBlur) + diffused * clampedBlur

        // DC blocker L
        let dcR = 1.0 - (2.0 * .pi * 5.0 / Double(sampleRate))
        let dcOut = Double(processed) - dcX1L + dcR * dcY1L
        dcX1L = Double(processed)
        dcY1L = dcOut
        processed = Float(dcOut)

        // Shift: frequency-dependent decay
        let effectiveShift = shiftSmoothed + shiftModSmoothed * wanderSmoothed * 0.2
        let lpCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / Double(sampleRate))
        lpStateL += (Double(processed) - lpStateL) * lpCoeff
        let low = Float(lpStateL)
        let hpCoeff = 1.0 - exp(-2.0 * .pi * 4000.0 / Double(sampleRate))
        hpStateL += (Double(processed) - hpStateL) * hpCoeff
        let high = processed - Float(hpStateL)
        let mid = processed - low - high
        let lowDecay = Float(1.0 - effectiveShift * 0.002)
        let midDecay = Float(1.0 - effectiveShift * 0.005)
        let highDecay = Float(1.0 - effectiveShift * 0.015)
        processed = low * lowDecay + mid * midDecay + high * highDecay

        // Accumulate pitch drift
        updatePitchDrift()

        // Per-iteration decay: base amplitude reduction independent of shift.
        // life=0 → 0.60 (fast fade), life=1 → 0.98 (long tail, still mortal)
        let iterationDecay = Float(0.60 + lifeSmoothed * 0.38)
        processed *= iterationDecay

        // Envelope follower: track peak amplitude, apply soft gain reduction
        // Fast attack (instantaneous), slow release (~100ms at 48kHz)
        let releaseCoeff: Float = 1.0 - 1.0 / (0.1 * sampleRate) // ~100ms release
        let absLevel = abs(processed)
        envelopeL = absLevel > envelopeL ? absLevel : envelopeL * releaseCoeff

        // Soft gain reduction: ceiling at 0.7, gentle knee
        let ceiling: Float = 0.7
        let gainReduction: Float = envelopeL > ceiling
            ? ceiling / envelopeL
            : 1.0
        processed *= gainReduction

        // Feedback write: scale input contribution to prevent accumulation
        // Only a fraction of the input enters the feedback loop
        let inputFeed: Float = 0.4
        let feedback = Float(lifeSmoothed * 0.95)
        bufferL[writeIndex] = Self.tanhClip(sample * inputFeed + processed * feedback)

        // Advance write index
        writeIndex += 1
        if writeIndex >= Self.bufferSize { writeIndex = 0 }

        return processed
    }

    // MARK: - True stereo processing

    /// Process stereo samples with cross-channel wander.
    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        smoothParameters()

        let delaySamples = computeDelaySamples(sampleRate: sampleRate)

        // Update wander modulations
        updateWander(sampleRate: sampleRate)
        smoothWanderMods()

        // Pitch drift offset in samples
        let driftOffset = pitchDrift * Double(sampleRate) / (1200.0 * 100.0)

        // Read from L and R buffers with cubic Hermite + drift + per-channel jitter
        let readDelayL = delaySamples + driftOffset + timeJitterLSmoothed * Double(sampleRate) * 0.001
        let readDelayR = delaySamples + driftOffset + timeJitterRSmoothed * Double(sampleRate) * 0.001
        let delayedL = Self.cubicRead(buffer: bufferL, writeIndex: writeIndex, delaySamples: readDelayL)
        let delayedR = Self.cubicRead(buffer: bufferR, writeIndex: writeIndex, delaySamples: readDelayR)

        // Blur: allpass diffusion per channel
        let effectiveBlur = Float(blurSmoothed + blurModSmoothed * wanderSmoothed * 0.3)
        let clampedBlur = max(Float(0), min(Float(1), effectiveBlur))

        var diffusedL = delayedL
        var diffusedR = delayedR
        for i in 0..<Self.allpassDelays.count {
            Self.processAllpass(input: &diffusedL, buf: allpassBufL[i], idx: &allpassIdxL[i],
                                delay: Self.allpassDelays[i])
            Self.processAllpass(input: &diffusedR, buf: allpassBufR[i], idx: &allpassIdxR[i],
                                delay: Self.allpassDelays[i])
        }
        var procL = delayedL * (1.0 - clampedBlur) + diffusedL * clampedBlur
        var procR = delayedR * (1.0 - clampedBlur) + diffusedR * clampedBlur

        // DC blocker per channel
        let dcCoeff = 1.0 - (2.0 * .pi * 5.0 / Double(sampleRate))
        let dcOutL = Double(procL) - dcX1L + dcCoeff * dcY1L
        dcX1L = Double(procL)
        dcY1L = dcOutL
        procL = Float(dcOutL)

        let dcOutR = Double(procR) - dcX1R + dcCoeff * dcY1R
        dcX1R = Double(procR)
        dcY1R = dcOutR
        procR = Float(dcOutR)

        // Shift: frequency-dependent decay per channel
        let effectiveShift = shiftSmoothed + shiftModSmoothed * wanderSmoothed * 0.2
        let lpCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / Double(sampleRate))
        let hpCoeff = 1.0 - exp(-2.0 * .pi * 4000.0 / Double(sampleRate))
        let lowDecay = Float(1.0 - effectiveShift * 0.002)
        let midDecay = Float(1.0 - effectiveShift * 0.005)
        let highDecay = Float(1.0 - effectiveShift * 0.015)

        // L channel shift
        lpStateL += (Double(procL) - lpStateL) * lpCoeff
        let lowL = Float(lpStateL)
        hpStateL += (Double(procL) - hpStateL) * hpCoeff
        let highL = procL - Float(hpStateL)
        let midL = procL - lowL - highL
        procL = lowL * lowDecay + midL * midDecay + highL * highDecay

        // R channel shift
        lpStateR += (Double(procR) - lpStateR) * lpCoeff
        let lowR = Float(lpStateR)
        hpStateR += (Double(procR) - hpStateR) * hpCoeff
        let highR = procR - Float(hpStateR)
        let midR = procR - lowR - highR
        procR = lowR * lowDecay + midR * midDecay + highR * highDecay

        // Accumulate pitch drift (shared)
        updatePitchDrift()

        // Per-iteration decay: base amplitude reduction independent of shift.
        // life=0 → 0.60 (fast fade), life=1 → 0.98 (long tail, still mortal)
        let iterationDecay = Float(0.60 + lifeSmoothed * 0.38)
        procL *= iterationDecay
        procR *= iterationDecay

        // Stereo wander: cross-blend L/R based on panModulation
        let panAmt = Float(panModSmoothed * wanderSmoothed)
        var wanderedL = procL * (1.0 - abs(panAmt)) + procR * max(0, panAmt)
        var wanderedR = procR * (1.0 - abs(panAmt)) + procL * max(0, -panAmt)

        // Envelope followers: track peak amplitude per channel, apply soft gain reduction
        let releaseCoeff: Float = 1.0 - 1.0 / (0.1 * sampleRate) // ~100ms release
        let ceiling: Float = 0.7

        let absL = abs(wanderedL)
        envelopeL = absL > envelopeL ? absL : envelopeL * releaseCoeff
        let gainL: Float = envelopeL > ceiling ? ceiling / envelopeL : 1.0
        wanderedL *= gainL

        let absR = abs(wanderedR)
        envelopeR = absR > envelopeR ? absR : envelopeR * releaseCoeff
        let gainR: Float = envelopeR > ceiling ? ceiling / envelopeR : 1.0
        wanderedR *= gainR

        // Feedback write: scale input contribution to prevent accumulation
        let inputFeed: Float = 0.4
        let feedback = Float(lifeSmoothed * 0.95)
        bufferL[writeIndex] = Self.tanhClip(sampleL * inputFeed + wanderedL * feedback)
        bufferR[writeIndex] = Self.tanhClip(sampleR * inputFeed + wanderedR * feedback)

        // Advance write index (shared)
        writeIndex += 1
        if writeIndex >= Self.bufferSize { writeIndex = 0 }

        return (wanderedL, wanderedR)
    }

    // MARK: - Parameter smoothing

    private mutating func smoothParameters() {
        lifeSmoothed += (life - lifeSmoothed) * paramSmooth
        blurSmoothed += (blur - blurSmoothed) * paramSmooth
        shiftSmoothed += (shift - shiftSmoothed) * paramSmooth
        wanderSmoothed += (wander - wanderSmoothed) * paramSmooth
        delayTimeSmoothed += (delayTime - delayTimeSmoothed) * delaySmooth
    }

    private func computeDelaySamples(sampleRate: Float) -> Double {
        // Map delayTime (0–1) to 50ms–2000ms
        let delayMs = 50.0 + delayTimeSmoothed * 1950.0
        return delayMs / 1000.0 * Double(sampleRate)
    }

    // MARK: - Cubic Hermite interpolation

    private static func cubicRead(buffer: UnsafeMutablePointer<Float>, writeIndex: Int, delaySamples: Double) -> Float {
        let clamped = max(1.0, min(delaySamples, Double(bufferSize - 4)))
        let readPos = Double(writeIndex) - clamped
        let readPosWrapped = readPos < 0 ? readPos + Double(bufferSize) : readPos

        let idx1 = Int(readPosWrapped) % bufferSize
        let idx0 = (idx1 - 1 + bufferSize) % bufferSize
        let idx2 = (idx1 + 1) % bufferSize
        let idx3 = (idx1 + 2) % bufferSize

        let frac = Float(readPosWrapped - Double(Int(readPosWrapped)))

        let y0 = buffer[idx0]
        let y1 = buffer[idx1]
        let y2 = buffer[idx2]
        let y3 = buffer[idx3]

        // Cubic Hermite interpolation
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)

        return ((c3 * frac + c2) * frac + c1) * frac + c0
    }

    // MARK: - Allpass (static — operates on pointer-based memory, no self access)

    private static func processAllpass(input: inout Float, buf: UnsafeMutablePointer<Float>,
                                        idx: inout Int, delay: Int) {
        let delayed = buf[idx]
        let allpassCoeff: Float = 0.5
        let output = -input + delayed
        buf[idx] = input + delayed * allpassCoeff
        idx = (idx + 1) % delay
        input = output
    }

    // MARK: - Pitch drift

    private mutating func updatePitchDrift() {
        // Accumulate tiny pitch drift per sample (shared between channels)
        pitchDrift += shiftSmoothed * 0.0001
        // Gentle pull-back toward 0, cap at +/-100 cents
        pitchDrift *= 0.9998
        pitchDrift = max(-100, min(100, pitchDrift))
    }

    // MARK: - Wander (LCG stochastic modulation)

    private mutating func updateWander(sampleRate: Float) {
        // Advance wander phase — recompute modulations once per delay cycle
        let delaySamples = computeDelaySamples(sampleRate: sampleRate)
        let cycleLen = max(1.0, delaySamples)
        wanderPhase += 1.0
        if wanderPhase >= cycleLen {
            wanderPhase = 0

            // LCG: seed = seed * 1664525 + 1013904223
            wanderSeedL = wanderSeedL &* 1_664_525 &+ 1_013_904_223
            wanderSeedR = wanderSeedR &* 1_664_525 &+ 1_013_904_223

            let randL = Double(wanderSeedL) / Double(UInt32.max) * 2.0 - 1.0
            let randR = Double(wanderSeedR) / Double(UInt32.max) * 2.0 - 1.0

            blurMod = randL * 0.5
            shiftMod = randR * 0.5
            timeJitterL = randL * 2.0   // up to +/-2ms jitter
            timeJitterR = randR * 2.0

            // Pan modulation for stereo drift
            wanderSeedL = wanderSeedL &* 1_664_525 &+ 1_013_904_223
            panModulation = Double(wanderSeedL) / Double(UInt32.max) * 2.0 - 1.0
        }
    }

    private mutating func smoothWanderMods() {
        blurModSmoothed += (blurMod - blurModSmoothed) * wanderModSmooth
        shiftModSmoothed += (shiftMod - shiftModSmoothed) * wanderModSmooth
        timeJitterLSmoothed += (timeJitterL - timeJitterLSmoothed) * wanderModSmooth
        timeJitterRSmoothed += (timeJitterR - timeJitterRSmoothed) * wanderModSmooth
        panModSmoothed += (panModulation - panModSmoothed) * wanderModSmooth
    }

    // MARK: - Utilities

    private static func tanhClip(_ x: Float) -> Float {
        // Fast tanh approximation for feedback bounding
        if x > 3.0 { return 1.0 }
        if x < -3.0 { return -1.0 }
        let x2 = x * x
        return x * (27.0 + x2) / (27.0 + 9.0 * x2)
    }

    // MARK: - Update parameters

    mutating func updateParameters(_ params: [String: Double]) {
        if let l = params["life"] { life = max(0, min(1, l)) }
        if let b = params["blur"] { blur = max(0, min(1, b)) }
        if let s = params["shift"] { shift = max(0, min(1, s)) }
        if let w = params["wander"] { wander = max(0, min(1, w)) }
        if let d = params["delayTime"] { delayTime = max(0, min(1, d)) }
    }

    // MARK: - Reset

    mutating func reset() {
        for i in 0..<Self.bufferSize {
            bufferL[i] = 0
            bufferR[i] = 0
        }
        writeIndex = 0

        for i in 0..<Self.allpassDelays.count {
            let delay = Self.allpassDelays[i]
            for j in 0..<delay {
                allpassBufL[i][j] = 0
                allpassBufR[i][j] = 0
            }
            allpassIdxL[i] = 0
            allpassIdxR[i] = 0
        }

        lpStateL = 0; lpStateR = 0
        hpStateL = 0; hpStateR = 0
        dcX1L = 0; dcY1L = 0
        dcX1R = 0; dcY1R = 0
        envelopeL = 0; envelopeR = 0
        pitchDrift = 0
        wanderPhase = 0
        blurMod = 0; shiftMod = 0
        timeJitterL = 0; timeJitterR = 0
        panModulation = 0
        blurModSmoothed = 0; shiftModSmoothed = 0
        timeJitterLSmoothed = 0; timeJitterRSmoothed = 0
        panModSmoothed = 0
    }
}
