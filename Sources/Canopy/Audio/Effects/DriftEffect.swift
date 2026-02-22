import Foundation

/// Drift effect — traveling delay where echoes degrade as they travel through a medium.
///
/// True stereo effect with distance-degradation coupling. Four controls (Distance, Medium,
/// Wander, Decay) produce dozens of behaviors through divergent mapping.
///
/// Parameters:
/// - `distance`: How far echoes travel (0.0–1.0). Maps to delay time (10ms–1200ms exponential),
///   HF rolloff, degradation depth, stereo width, and pre-delay diffusion.
/// - `medium`: What the echoes travel through (0.0–1.0). Crossfades between air (transparent),
///   water (warm/dispersed), and metal (resonant/ringing).
/// - `wander`: How much echoes drift in time and space (0.0–1.0). Delay modulation, stereo
///   rotation, pitch drift accumulation, and spatial scatter.
/// - `decay`: How many echoes return (0.0–1.0). Maps to feedback (capped at 0.92).
struct DriftEffect {
    // MARK: - Buffer sizes

    /// 120,000 samples per channel — supports 1200ms + 5ms modulation headroom at 96kHz
    private static let delayBufferSize = 120_000

    /// Diffusion allpass: 1 stage per channel, 512 samples
    private static let diffusionAPSize = 512

    /// Water allpass: 4 stages per channel, 512 samples each
    private static let waterAPCount = 4
    private static let waterAPSize = 512
    /// Prime delays in 2–9ms range at 48kHz
    private static let waterAPDelays = [113, 199, 317, 421]

    /// Metal comb: 3 per channel, 4800 samples each
    private static let metalCombCount = 3
    private static let metalCombSize = 4800
    /// Non-harmonic ratios for metallic character
    private static let metalCombRatios: [Double] = [1.0, 1.347, 1.839]

    /// Shimmer allpass: 1024 samples per channel
    private static let shimmerAPSize = 1024

    // MARK: - Stereo delay buffers

    private let delayBufL: UnsafeMutablePointer<Float>
    private let delayBufR: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0

    // MARK: - Diffusion allpass (1 stage per channel, in feedback path)

    private let diffusionBufL: UnsafeMutablePointer<Float>
    private let diffusionBufR: UnsafeMutablePointer<Float>
    private var diffusionIdxL: Int = 0
    private var diffusionIdxR: Int = 0

    // MARK: - Water allpass chain (4 stages per channel)

    private let waterAPBufL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let waterAPBufR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let waterAPIdxL: UnsafeMutablePointer<Int>
    private let waterAPIdxR: UnsafeMutablePointer<Int>

    // MARK: - Metal comb bank (3 per channel)

    private let metalCombBufL: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let metalCombBufR: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let metalCombIdxL: UnsafeMutablePointer<Int>
    private let metalCombIdxR: UnsafeMutablePointer<Int>

    // MARK: - Shimmer allpass (1 per channel)

    private let shimmerBufL: UnsafeMutablePointer<Float>
    private let shimmerBufR: UnsafeMutablePointer<Float>
    private var shimmerIdxL: Int = 0
    private var shimmerIdxR: Int = 0

    // MARK: - Filter state

    /// HF rolloff one-pole LP (distance-coupled), per channel
    private var hfLPStateL: Double = 0
    private var hfLPStateR: Double = 0

    /// Water low shelf: bass extraction one-pole LP, per channel
    private var waterBassLPL: Double = 0
    private var waterBassLPR: Double = 0

    /// Water aggressive LP, per channel
    private var waterLPL: Double = 0
    private var waterLPR: Double = 0

    /// Feedback-path damping LP (fixed reference, safe pattern), per channel
    private var feedbackDampL: Double = 0
    private var feedbackDampR: Double = 0

    // MARK: - DC blockers (5Hz one-pole HP)

    private var dcX1L: Double = 0
    private var dcY1L: Double = 0
    private var dcX1R: Double = 0
    private var dcY1R: Double = 0

    // MARK: - Envelope followers

    private var envelopeL: Float = 0
    private var envelopeR: Float = 0

    // MARK: - Wander LFOs

    private var lfoPhase1: Double = 0
    private var lfoPhase2: Double = 0
    private var rotationPhase: Double = 0

    // MARK: - Per-repeat accumulation state

    private var pitchDriftAccum: Double = 0
    private var scatterL: Double = 0
    private var scatterR: Double = 0
    private var scatterLSmoothed: Double = 0
    private var scatterRSmoothed: Double = 0
    private var lastDelaySamplesInt: Int = 0

    // MARK: - LCG noise seeds

    private var lcgSeedL: UInt32 = 2_345_678
    private var lcgSeedR: UInt32 = 8_765_432
    private var lcgSeedPitch: UInt32 = 5_678_901

    // MARK: - Sync mode

    /// Beat divisions for sync mode: label → beats
    static let divisionBeats: [Double] = [0.125, 0.25, 0.375, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
    static let divisionNames: [String] = ["1/32", "1/16", "1/16d", "1/8", "1/8d", "1/4", "1/4d", "1/2", "1/2d", "1/1"]

    private var sync: Bool = false
    private var division: Int = 5  // 1/4 note default
    private var bpm: Double = 120.0

    // MARK: - Parameter targets

    private var distance: Double = 0.3
    private var medium: Double = 0.5
    private var wander: Double = 0.15
    private var decay: Double = 0.4

    // MARK: - Smoothed parameters

    private var distanceSmoothed: Double = 0.3
    private var mediumSmoothed: Double = 0.5
    private var wanderSmoothed: Double = 0.15
    private var decaySmoothed: Double = 0.4
    private var delaySamplesSmoothed: Double = 0  // smoothed final delay target (both modes)

    // Smoothing coefficients
    private let paramSmooth: Double = 0.001
    private let delaySmooth: Double = 0.0001

    // MARK: - Init

    init() {
        // Stereo delay buffers
        delayBufL = .allocate(capacity: Self.delayBufferSize)
        delayBufL.initialize(repeating: 0, count: Self.delayBufferSize)
        delayBufR = .allocate(capacity: Self.delayBufferSize)
        delayBufR.initialize(repeating: 0, count: Self.delayBufferSize)

        // Diffusion allpass
        diffusionBufL = .allocate(capacity: Self.diffusionAPSize)
        diffusionBufL.initialize(repeating: 0, count: Self.diffusionAPSize)
        diffusionBufR = .allocate(capacity: Self.diffusionAPSize)
        diffusionBufR.initialize(repeating: 0, count: Self.diffusionAPSize)

        // Water allpass chain
        waterAPBufL = .allocate(capacity: Self.waterAPCount)
        waterAPBufR = .allocate(capacity: Self.waterAPCount)
        waterAPIdxL = .allocate(capacity: Self.waterAPCount)
        waterAPIdxR = .allocate(capacity: Self.waterAPCount)
        for i in 0..<Self.waterAPCount {
            let bL = UnsafeMutablePointer<Float>.allocate(capacity: Self.waterAPSize)
            bL.initialize(repeating: 0, count: Self.waterAPSize)
            waterAPBufL[i] = bL
            waterAPIdxL[i] = 0

            let bR = UnsafeMutablePointer<Float>.allocate(capacity: Self.waterAPSize)
            bR.initialize(repeating: 0, count: Self.waterAPSize)
            waterAPBufR[i] = bR
            waterAPIdxR[i] = 0
        }

        // Metal comb bank
        metalCombBufL = .allocate(capacity: Self.metalCombCount)
        metalCombBufR = .allocate(capacity: Self.metalCombCount)
        metalCombIdxL = .allocate(capacity: Self.metalCombCount)
        metalCombIdxR = .allocate(capacity: Self.metalCombCount)
        for i in 0..<Self.metalCombCount {
            let bL = UnsafeMutablePointer<Float>.allocate(capacity: Self.metalCombSize)
            bL.initialize(repeating: 0, count: Self.metalCombSize)
            metalCombBufL[i] = bL
            metalCombIdxL[i] = 0

            let bR = UnsafeMutablePointer<Float>.allocate(capacity: Self.metalCombSize)
            bR.initialize(repeating: 0, count: Self.metalCombSize)
            metalCombBufR[i] = bR
            metalCombIdxR[i] = 0
        }

        // Shimmer allpass
        shimmerBufL = .allocate(capacity: Self.shimmerAPSize)
        shimmerBufL.initialize(repeating: 0, count: Self.shimmerAPSize)
        shimmerBufR = .allocate(capacity: Self.shimmerAPSize)
        shimmerBufR.initialize(repeating: 0, count: Self.shimmerAPSize)
    }

    // MARK: - Mono processing

    mutating func process(sample: Float, sampleRate: Float) -> Float {
        let (outL, outR) = processStereo(sampleL: sample, sampleR: sample, sampleRate: sampleRate)
        return (outL + outR) * 0.5
    }

    // MARK: - True stereo processing

    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        // 1. Smooth parameters
        distanceSmoothed += (distance - distanceSmoothed) * delaySmooth  // extra slow for delay time
        mediumSmoothed += (medium - mediumSmoothed) * paramSmooth
        wanderSmoothed += (wander - wanderSmoothed) * paramSmooth
        decaySmoothed += (decay - decaySmoothed) * paramSmooth

        // 2. Compute derived values — branch between FREE and SYNC delay
        let delayMs: Double
        if sync && bpm > 0 {
            let beats = Self.divisionBeats[min(division, Self.divisionBeats.count - 1)]
            delayMs = beats / bpm * 60_000.0
        } else {
            delayMs = 10.0 * pow(120.0, distanceSmoothed)
        }
        let delaySamplesTarget = max(1.0, min(Double(Self.delayBufferSize - 4), delayMs / 1000.0 * Double(sampleRate)))
        // Smooth the final delay target (handles both free and sync mode transitions)
        if delaySamplesSmoothed == 0 { delaySamplesSmoothed = delaySamplesTarget }
        delaySamplesSmoothed += (delaySamplesTarget - delaySamplesSmoothed) * delaySmooth
        let delaySamples = delaySamplesSmoothed

        let hfCutoff = 18000.0 * pow(0.7, distanceSmoothed * 6.0)
        let clampedHFCutoff = max(20.0, min(hfCutoff, Double(sampleRate) * 0.5 - 100.0))

        let stereoWidth = Float(distanceSmoothed * 0.8)

        let diffusionCoeff = Float(0.1 + distanceSmoothed * 0.25)  // floor smooths echo envelopes

        // Medium weights
        let rawAir = max(0.0, 1.0 - mediumSmoothed * 2.5)
        let rawWater = exp(-pow((mediumSmoothed - 0.5) / 0.22, 2))
        let rawMetal = max(0.0, (mediumSmoothed - 0.6) * 2.5)
        let weightSum = max(0.001, rawAir + rawWater + rawMetal)
        let airW = Float(rawAir / weightSum)
        let waterW = Float(rawWater / weightSum)
        let metalW = Float(rawMetal / weightSum)

        // Feedback — bass boost is output-only so loop is gain-free
        let feedback = Float(decaySmoothed * 0.98)

        // 3. Update wander LFOs
        let lfoRate1 = 0.3 / (1.0 + wanderSmoothed * 4.0)
        let lfoRate2 = lfoRate1 * 1.127
        lfoPhase1 += lfoRate1 / Double(sampleRate)
        if lfoPhase1 >= 1.0 { lfoPhase1 -= 1.0 }
        lfoPhase2 += lfoRate2 / Double(sampleRate)
        if lfoPhase2 >= 1.0 { lfoPhase2 -= 1.0 }

        let rotationRate = wanderSmoothed * 0.5
        rotationPhase += rotationRate / Double(sampleRate)
        if rotationPhase >= 1.0 { rotationPhase -= 1.0 }

        // Delay modulation from wander
        let wanderModMs = wanderSmoothed * 3.0
        let mod1 = sin(2.0 * .pi * lfoPhase1) * wanderModMs
        let mod2 = sin(2.0 * .pi * lfoPhase2) * wanderModMs
        let modSamplesL = (mod1 + mod2 * 0.5) / 1000.0 * Double(sampleRate)
        let modSamplesR = (mod1 - mod2 * 0.5) / 1000.0 * Double(sampleRate)  // stereo detuning

        // Minimum delay floor: smooth quadratic ramp, no step discontinuity
        let minDelayMs = 0.02 + wanderSmoothed * wanderSmoothed * 5.0
        let minDelaySamples = minDelayMs / 1000.0 * Double(sampleRate)

        // 4. Read from stereo delay buffers with cubic Hermite + wander modulation + pitch drift
        let driftOffsetSamples = pitchDriftAccum * Double(sampleRate) * 0.001
        let readDelayL = max(minDelaySamples, delaySamples + modSamplesL + driftOffsetSamples)
        let readDelayR = max(minDelaySamples, delaySamples + modSamplesR + driftOffsetSamples)

        let delayedL = Self.cubicRead(buffer: delayBufL, bufferSize: Self.delayBufferSize,
                                       writeIndex: writeIndex, delaySamples: readDelayL)
        let delayedR = Self.cubicRead(buffer: delayBufR, bufferSize: Self.delayBufferSize,
                                       writeIndex: writeIndex, delaySamples: readDelayR)

        // 5. Process through medium (3-path crossfade, per channel)
        var procL = delayedL
        var procR = delayedR

        // --- AIR PATH ---
        let airOutL: Float
        let airOutR: Float
        if airW > 0.001 {
            // One-pole LP, cutoff coupled to distance
            let airG = 1.0 - exp(-2.0 * .pi * clampedHFCutoff / Double(sampleRate))
            hfLPStateL += (Double(procL) - hfLPStateL) * airG
            hfLPStateR += (Double(procR) - hfLPStateR) * airG
            airOutL = Float(hfLPStateL)
            airOutR = Float(hfLPStateR)
        } else {
            // Keep filter state tracking to avoid discontinuities
            let airG = 1.0 - exp(-2.0 * .pi * clampedHFCutoff / Double(sampleRate))
            hfLPStateL += (Double(procL) - hfLPStateL) * airG
            hfLPStateR += (Double(procR) - hfLPStateR) * airG
            airOutL = 0
            airOutR = 0
        }

        // --- WATER PATH ---
        let waterOutL: Float
        let waterOutR: Float
        if waterW > 0.001 {
            // Aggressive LP
            let waterCutoff = max(20.0, min(2000.0 + 4000.0 * (1.0 - distanceSmoothed),
                                             Double(sampleRate) * 0.5 - 100.0))
            let waterG = 1.0 - exp(-2.0 * .pi * waterCutoff / Double(sampleRate))
            waterLPL += (Double(procL) - waterLPL) * waterG
            waterLPR += (Double(procR) - waterLPR) * waterG
            var wL = Float(waterLPL)
            var wR = Float(waterLPR)

            // Low shelf state tracking at 300Hz (boost applied to output only, not feedback)
            let bassG = 1.0 - exp(-2.0 * .pi * 300.0 / Double(sampleRate))
            waterBassLPL += (Double(wL) - waterBassLPL) * bassG
            waterBassLPR += (Double(wR) - waterBassLPR) * bassG

            // 4-stage allpass dispersion chain
            let apCoeff = Float(0.3 + distanceSmoothed * 0.4)  // coefficient coupled to distance
            for i in 0..<Self.waterAPCount {
                Self.processAllpass(input: &wL, buf: waterAPBufL[i], writeIdx: &waterAPIdxL[i],
                                     bufSize: Self.waterAPSize, delay: Self.waterAPDelays[i],
                                     coeff: apCoeff)
                Self.processAllpass(input: &wR, buf: waterAPBufR[i], writeIdx: &waterAPIdxR[i],
                                     bufSize: Self.waterAPSize, delay: Self.waterAPDelays[i],
                                     coeff: apCoeff)
            }

            // Pitch jitter: LCG noise → modulates read offset
            lcgSeedPitch = lcgSeedPitch &* 1_664_525 &+ 1_013_904_223
            let jitterNorm = Double(lcgSeedPitch) / Double(UInt32.max) * 2.0 - 1.0
            let jitterMs = jitterNorm * distanceSmoothed * 0.5
            let jitterSamples = Float(jitterMs / 1000.0 * Double(sampleRate))
            // Apply as subtle pitch warp (mix jittered with clean)
            let jitterAmt = Float(distanceSmoothed * 0.15)
            wL += wL * jitterSamples * jitterAmt * 0.0001
            wR += wR * jitterSamples * jitterAmt * 0.0001

            waterOutL = wL
            waterOutR = wR
        } else {
            // Keep filter state tracking
            let waterCutoff = max(20.0, min(2000.0 + 4000.0 * (1.0 - distanceSmoothed),
                                             Double(sampleRate) * 0.5 - 100.0))
            let waterG = 1.0 - exp(-2.0 * .pi * waterCutoff / Double(sampleRate))
            waterLPL += (Double(procL) - waterLPL) * waterG
            waterLPR += (Double(procR) - waterLPR) * waterG
            let bassG = 1.0 - exp(-2.0 * .pi * 300.0 / Double(sampleRate))
            waterBassLPL += (Double(procL) - waterBassLPL) * bassG
            waterBassLPR += (Double(procR) - waterBassLPR) * bassG
            waterOutL = 0
            waterOutR = 0
        }

        // --- METAL PATH ---
        let metalOutL: Float
        let metalOutR: Float
        if metalW > 0.001 {
            var mL: Float = 0
            var mR: Float = 0

            // 3-comb filter bank — fractional delay with linear interpolation (no integer clicks)
            // Scale comb excitation by metalW when low — prevents full-level resonance
            // when metal contribution to output is negligible
            let combInputScale = min(1.0, metalW * 10)  // 0→1 over metalW 0→0.1
            let basePeriod = max(1.0, delaySamples / 50.0)
            for i in 0..<Self.metalCombCount {
                let combDelayF = max(1.0, min(Double(Self.metalCombSize - 2), basePeriod * Self.metalCombRatios[i]))
                let combFb: Float = min(0.75, Float(0.4 + distanceSmoothed * 0.3)) * Float(decaySmoothed * 0.9 + 0.05)

                // Read from comb L with linear interpolation
                let readPosL = Double(metalCombIdxL[i]) - combDelayF
                let rpL = readPosL < 0 ? readPosL + Double(Self.metalCombSize) : readPosL
                let ri0L = Int(rpL) % Self.metalCombSize
                let ri1L = (ri0L + 1) % Self.metalCombSize
                let fracL = Float(rpL - Double(Int(rpL)))
                let combOutL = metalCombBufL[i][ri0L] * (1.0 - fracL) + metalCombBufL[i][ri1L] * fracL
                metalCombBufL[i][metalCombIdxL[i]] = procL * combInputScale + combOutL * combFb
                metalCombIdxL[i] = (metalCombIdxL[i] + 1) % Self.metalCombSize
                mL += combOutL

                // Read from comb R with linear interpolation
                let readPosR = Double(metalCombIdxR[i]) - combDelayF
                let rpR = readPosR < 0 ? readPosR + Double(Self.metalCombSize) : readPosR
                let ri0R = Int(rpR) % Self.metalCombSize
                let ri1R = (ri0R + 1) % Self.metalCombSize
                let fracR = Float(rpR - Double(Int(rpR)))
                let combOutR = metalCombBufR[i][ri0R] * (1.0 - fracR) + metalCombBufR[i][ri1R] * fracR
                metalCombBufR[i][metalCombIdxR[i]] = procR * combInputScale + combOutR * combFb
                metalCombIdxR[i] = (metalCombIdxR[i] + 1) % Self.metalCombSize
                mR += combOutR
            }
            mL /= Float(Self.metalCombCount)
            mR /= Float(Self.metalCombCount)

            // Shimmer allpass: modulated by wander LFO
            let shimmerCoeff = Float(0.5 + mediumSmoothed * 0.15)
            let shimmerMod = Float(sin(2.0 * .pi * lfoPhase1) * wanderSmoothed * 3.0)
            Self.processModulatedAllpass(input: &mL, buf: shimmerBufL, writeIdx: &shimmerIdxL,
                                          bufSize: Self.shimmerAPSize, nominalDelay: 512,
                                          modOffset: shimmerMod, coeff: shimmerCoeff)
            Self.processModulatedAllpass(input: &mR, buf: shimmerBufR, writeIdx: &shimmerIdxR,
                                          bufSize: Self.shimmerAPSize, nominalDelay: 512,
                                          modOffset: -shimmerMod, coeff: shimmerCoeff)

            metalOutL = mL
            metalOutR = mR
        } else {
            metalOutL = 0
            metalOutR = 0
        }

        // Crossfade medium outputs
        procL = airOutL * airW + waterOutL * waterW + metalOutL * metalW
        procR = airOutR * airW + waterOutR * waterW + metalOutR * metalW

        // Unconditional loop loss — guarantees decay (no gain sources remain in loop)
        procL *= 0.995
        procR *= 0.995

        // Feedback-path damping: fixed reference LP, blend by distance + excitation.
        // Signal always passes — distance controls color, not survival.
        // Pattern: fixed LP as reference, then mix dry↔LP by amount.
        feedbackDampL += 0.5 * (Double(procL) - feedbackDampL)  // fixed ~5.3kHz ref at 48kHz
        feedbackDampR += 0.5 * (Double(procR) - feedbackDampR)
        // More distance = darker. More metal/water excitation = more damping to compensate.
        // Floor of 0.15 ensures HF always rolls off in the loop (absorbs tanh harmonics).
        let excitationDamp = Double(metalW) * 0.25 + Double(waterW) * 0.1
        let dampAmt = Float(min(1.0, 0.15 + distanceSmoothed * 0.5 + excitationDamp))
        procL = procL + (Float(feedbackDampL) - procL) * dampAmt
        procR = procR + (Float(feedbackDampR) - procR) * dampAmt

        // 6. Distance-coupled diffusion allpass (always runs — no on/off phase discontinuity.
        //    At coeff≈0 it becomes a pure delay, which is fine in the feedback path.)
        Self.processAllpass(input: &procL, buf: diffusionBufL, writeIdx: &diffusionIdxL,
                             bufSize: Self.diffusionAPSize, delay: 256, coeff: diffusionCoeff)
        Self.processAllpass(input: &procR, buf: diffusionBufR, writeIdx: &diffusionIdxR,
                             bufSize: Self.diffusionAPSize, delay: 256, coeff: diffusionCoeff)

        // 7. DC blocker (5Hz one-pole HP)
        let dcCoeff = 1.0 - (2.0 * .pi * 5.0 / Double(sampleRate))
        let dcOutL = Double(procL) - dcX1L + dcCoeff * dcY1L
        dcX1L = Double(procL)
        dcY1L = dcOutL
        procL = Float(dcOutL)

        let dcOutR = Double(procR) - dcX1R + dcCoeff * dcY1R
        dcX1R = Double(procR)
        dcY1R = dcOutR
        procR = Float(dcOutR)

        // 8. Stereo rotation from wander (quadrature LFO cross-blending)
        let rotAmt = Float(wanderSmoothed * 0.5)
        let rotSin = Float(sin(2.0 * .pi * rotationPhase)) * rotAmt
        let rotCos = Float(cos(2.0 * .pi * rotationPhase))
        let rotScale = 1.0 - rotAmt + rotAmt * abs(rotCos)  // maintain volume
        let rotL = procL * rotScale + procR * rotSin
        let rotR = procR * rotScale - procL * rotSin
        procL = rotL
        procR = rotR

        // 9. Spatial scatter at high wander — use smoothed values to avoid gain clicks
        scatterLSmoothed += (scatterL - scatterLSmoothed) * 0.001  // ~20ms smooth, less AM modulation
        scatterRSmoothed += (scatterR - scatterRSmoothed) * 0.001
        let scatterFade = Float(max(0, (wanderSmoothed - 0.2)) * 5.0)  // smooth 0→1 over wander 0.2–0.4
        if scatterFade > 0 {
            let scatterAmt = Float(wanderSmoothed * 0.4) * min(1.0, scatterFade)
            procL *= (1.0 + Float(scatterLSmoothed) * scatterAmt)
            procR *= (1.0 + Float(scatterRSmoothed) * scatterAmt)
        }

        // 10. Distance-based stereo width
        let monoMix = (procL + procR) * 0.5
        let sideMix = (procL - procR) * 0.5
        procL = monoMix + sideMix * stereoWidth
        procR = monoMix - sideMix * stereoWidth

        // 11. Pitch drift accumulation — dead zone below 0.1 to avoid comb filtering
        //     from near-identical read positions in feedback loop.
        //     Decays slowly to prevent unbounded drift.
        if wanderSmoothed > 0.1 {
            pitchDriftAccum += wanderSmoothed * 0.002
        }
        pitchDriftAccum *= 0.9995  // faster decay prevents hitting hard clamp
        pitchDriftAccum = max(-5.0, min(5.0, pitchDriftAccum))

        // Re-roll scatter once per delay cycle (at writeIndex wraparound relative to delay length)
        let currentDelaySamplesInt = max(1, Int(delaySamples))
        if lastDelaySamplesInt > 0 && (writeIndex % currentDelaySamplesInt) == 0 {
            lcgSeedL = lcgSeedL &* 1_664_525 &+ 1_013_904_223
            lcgSeedR = lcgSeedR &* 1_664_525 &+ 1_013_904_223
            scatterL = Double(lcgSeedL) / Double(UInt32.max) * 2.0 - 1.0
            scatterR = Double(lcgSeedR) / Double(UInt32.max) * 2.0 - 1.0
        }
        lastDelaySamplesInt = currentDelaySamplesInt

        // 12. Envelope follower + soft gain reduction (ceiling 0.7)
        let releaseCoeff: Float = 1.0 - 1.0 / (0.1 * sampleRate)
        let ceiling: Float = 0.7

        let attackCoeff: Float = 1.0 - 1.0 / (0.0005 * sampleRate)  // 0.5ms attack

        let absL = abs(procL)
        envelopeL = absL > envelopeL
            ? absL + (envelopeL - absL) * attackCoeff
            : envelopeL * releaseCoeff
        let gainL: Float = envelopeL > ceiling ? ceiling / envelopeL : 1.0
        procL *= gainL

        let absR = abs(procR)
        envelopeR = absR > envelopeR
            ? absR + (envelopeR - absR) * attackCoeff
            : envelopeR * releaseCoeff
        let gainR: Float = envelopeR > ceiling ? ceiling / envelopeR : 1.0
        procR *= gainR

        // 13. Feedback write: tanh clip(input * 0.4 + processed * feedback)
        delayBufL[writeIndex] = Self.tanhClip(sampleL * 0.4 + procL * feedback)
        delayBufR[writeIndex] = Self.tanhClip(sampleR * 0.4 + procR * feedback)

        // 14. Advance write index
        writeIndex += 1
        if writeIndex >= Self.delayBufferSize { writeIndex = 0 }

        // 15. Output-only water bass warmth (not in feedback loop — preserves long sustain)
        if waterW > 0.001 {
            let bassDecayScale = Float(1.0 - decaySmoothed * 0.3)
            let bassBoost = Float(2.0 + 2.0 * distanceSmoothed) * bassDecayScale
            let boostLinear = powf(10.0, bassBoost / 20.0) - 1.0
            procL += Float(waterBassLPL) * boostLinear * waterW
            procR += Float(waterBassLPR) * boostLinear * waterW
        }

        return (procL, procR)
    }

    // MARK: - Parameter update

    mutating func updateParameters(_ params: [String: Double]) {
        if let d = params["distance"] { distance = max(0, min(1, d)) }
        if let m = params["medium"] { medium = max(0, min(1, m)) }
        if let w = params["wander"] { wander = max(0, min(1, w)) }
        if let dc = params["decay"] { decay = max(0, min(1, dc)) }
        if let s = params["sync"] { sync = s >= 0.5 }
        if let div = params["division"] { division = max(0, min(Self.divisionBeats.count - 1, Int(div))) }
        if let b = params["_bpm"] { bpm = b }
    }

    // MARK: - Reset

    mutating func reset() {
        // Delay buffers
        for i in 0..<Self.delayBufferSize {
            delayBufL[i] = 0
            delayBufR[i] = 0
        }
        writeIndex = 0

        // Diffusion allpass
        for i in 0..<Self.diffusionAPSize {
            diffusionBufL[i] = 0
            diffusionBufR[i] = 0
        }
        diffusionIdxL = 0
        diffusionIdxR = 0

        // Water allpass
        for i in 0..<Self.waterAPCount {
            for j in 0..<Self.waterAPSize {
                waterAPBufL[i][j] = 0
                waterAPBufR[i][j] = 0
            }
            waterAPIdxL[i] = 0
            waterAPIdxR[i] = 0
        }

        // Metal combs
        for i in 0..<Self.metalCombCount {
            for j in 0..<Self.metalCombSize {
                metalCombBufL[i][j] = 0
                metalCombBufR[i][j] = 0
            }
            metalCombIdxL[i] = 0
            metalCombIdxR[i] = 0
        }

        // Shimmer allpass
        for i in 0..<Self.shimmerAPSize {
            shimmerBufL[i] = 0
            shimmerBufR[i] = 0
        }
        shimmerIdxL = 0
        shimmerIdxR = 0

        // Filter state
        hfLPStateL = 0; hfLPStateR = 0
        waterBassLPL = 0; waterBassLPR = 0
        waterLPL = 0; waterLPR = 0
        feedbackDampL = 0; feedbackDampR = 0

        // DC blockers
        dcX1L = 0; dcY1L = 0
        dcX1R = 0; dcY1R = 0

        // Envelopes
        envelopeL = 0; envelopeR = 0

        // LFOs
        lfoPhase1 = 0; lfoPhase2 = 0
        rotationPhase = 0

        // Accumulation state
        pitchDriftAccum = 0
        scatterL = 0; scatterR = 0
        scatterLSmoothed = 0; scatterRSmoothed = 0
        lastDelaySamplesInt = 0
    }

    // MARK: - Utilities

    /// Rational tanh approximation
    private static func tanhClip(_ x: Float) -> Float {
        if x > 3.0 { return 1.0 }
        if x < -3.0 { return -1.0 }
        let x2 = x * x
        return x * (27.0 + x2) / (27.0 + 9.0 * x2)
    }

    /// Cubic Hermite interpolation from circular buffer
    private static func cubicRead(buffer: UnsafeMutablePointer<Float>, bufferSize: Int,
                                   writeIndex: Int, delaySamples: Double) -> Float {
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

        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)

        return ((c3 * frac + c2) * frac + c1) * frac + c0
    }

    /// Fixed-delay Schroeder allpass filter (true unity gain)
    private static func processAllpass(input: inout Float, buf: UnsafeMutablePointer<Float>,
                                        writeIdx: inout Int, bufSize: Int,
                                        delay: Int, coeff: Float) {
        let readIdx = (writeIdx - delay + bufSize) % bufSize
        let delayed = buf[readIdx]
        let v = input - coeff * delayed
        buf[writeIdx] = v
        writeIdx = (writeIdx + 1) % bufSize
        input = coeff * v + delayed
    }

    /// Modulated Schroeder allpass filter with linear interpolation (true unity gain)
    private static func processModulatedAllpass(input: inout Float, buf: UnsafeMutablePointer<Float>,
                                                 writeIdx: inout Int, bufSize: Int,
                                                 nominalDelay: Int, modOffset: Float,
                                                 coeff: Float) {
        var readPos = Float(writeIdx) - Float(nominalDelay) + modOffset
        if readPos < 0 { readPos += Float(bufSize) }
        let idx0 = Int(readPos) % bufSize
        let idx1 = (idx0 + 1) % bufSize
        let frac = readPos - Float(Int(readPos))
        let delayed = buf[idx0] * (1.0 - frac) + buf[idx1] * frac

        let v = input - coeff * delayed
        buf[writeIdx] = v
        writeIdx = (writeIdx + 1) % bufSize
        input = coeff * v + delayed
    }
}
