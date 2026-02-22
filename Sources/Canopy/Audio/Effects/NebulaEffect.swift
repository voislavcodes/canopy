import Foundation

/// NEBULA — Feedback Delay Network reverb where the tail *evolves*.
///
/// A physics-inspired reverb modeled on interstellar nebulae. Sound enters a vast cloud
/// of 8 cross-coupled delay lines and scatters between them via a Hadamard mixing matrix.
/// Each pass through the feedback network applies spectral transformation: frequency-dependent
/// damping, pitch shifting (Doppler/red-shift), harmonic excitation (re-emission), and
/// allpass diffusion (scattering density).
///
/// At low settings: a smooth, natural reverb. At high settings: a generative instrument
/// where input transforms into continuously evolving ambient texture.
///
/// Parameters:
/// - `cloud`: Scattering density (0.0–1.0). Allpass diffusion, delay spread, injection weight.
/// - `depth`: Travel distance (0.0–1.0). Delay length, feedback gain, per-pass damping.
/// - `glow`: Temperature (0.0–1.0). Damping profile, harmonic excitation, pitch shift direction.
/// - `drift`: Turbulence (0.0–1.0). Delay modulation, pitch random walk, allpass modulation.
struct NebulaEffect {

    // MARK: - Constants

    private static let lineCount = 8

    /// 2 seconds at 48kHz per delay line
    private static let maxDelaySamples = 96_000

    /// Allpass buffer sizes — 20% and 35% of max delay
    private static let allpassSize1 = 19_200
    private static let allpassSize2 = 33_600

    /// Pitch shifter circular buffer
    private static let pitchBufSize = 4_096

    /// Prime-inspired delay ratios — mutually incommensurate to prevent beating
    private static let delayRatios: (Float, Float, Float, Float, Float, Float, Float, Float) = (
        0.199, 0.307, 0.419, 0.541, 0.673, 0.787, 0.883, 1.000
    )

    /// Hadamard normalization: 1/√8
    private static let hadamardScale: Float = 1.0 / 2.828427  // 1/√8

    /// Emission line base frequencies staggered across lines (Hz)
    private static let emissionFreqs1: (Float, Float, Float, Float, Float, Float, Float, Float) = (
        400, 600, 900, 1200, 1600, 2100, 2700, 3300
    )
    private static let emissionFreqs2: (Float, Float, Float, Float, Float, Float, Float, Float) = (
        800, 1100, 1500, 2000, 2600, 3200, 4000, 5000
    )

    /// LCG primes for per-line random walks
    private static let lcgSeeds: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        2_654_435_761, 1_013_904_223, 3_266_489_917, 668_265_263,
        1_103_515_245, 214_013_000, 2_531_011_000, 747_796_405
    )

    // MARK: - Delay Buffers (8 lines)

    private let delayBufs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let writeIndices: UnsafeMutablePointer<Int>

    // MARK: - Allpass Buffers (2 per line = 16)

    private let apBufs1: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let apBufs2: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let apIdx1: UnsafeMutablePointer<Int>
    private let apIdx2: UnsafeMutablePointer<Int>

    // MARK: - Pitch Shifter Buffers (8)

    private let pitchBufs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let pitchWritePos: UnsafeMutablePointer<Int>
    private let grainPhases: UnsafeMutablePointer<Float>

    // MARK: - Per-line filter state

    /// Damping filter: one-pole LP state (HF damping)
    private let dampLP: UnsafeMutablePointer<Float>
    /// Damping filter: one-pole HP state (LF damping)
    private let dampHP: UnsafeMutablePointer<Float>

    /// Glow filter: 2 bandpass states per line (4 floats per line: bp1.s1, bp1.s2, bp2.s1, bp2.s2)
    private let glowBPState: UnsafeMutablePointer<Float>

    /// Feedback line values from previous sample
    private let feedbackLines: UnsafeMutablePointer<Float>

    // MARK: - DC Blockers (stereo)

    private var dcX1L: Float = 0
    private var dcY1L: Float = 0
    private var dcX1R: Float = 0
    private var dcY1R: Float = 0

    // MARK: - Envelope followers (stereo output)

    private var envelopeL: Float = 0
    private var envelopeR: Float = 0

    // MARK: - Modulation state

    /// Per-line LCG seeds for drift random walks
    private let lcgState: UnsafeMutablePointer<UInt32>

    /// Per-line modulation oscillator phases
    private let modPhases: UnsafeMutablePointer<Float>

    /// Per-line pitch drift random walk accumulators (cents)
    private let pitchDriftAcc: UnsafeMutablePointer<Float>

    /// Per-line allpass coefficient modulation values
    private let apModValues: UnsafeMutablePointer<Float>

    // MARK: - Computed delay state

    /// Current delay lengths in samples per line (smoothed)
    private let currentDelayLengths: UnsafeMutablePointer<Float>

    /// Current allpass lengths per line (ap1, ap2)
    private let currentAPLen1: UnsafeMutablePointer<Float>
    private let currentAPLen2: UnsafeMutablePointer<Float>

    /// Input injection gains per line
    private let inputGains: UnsafeMutablePointer<Float>

    // MARK: - Parameter targets

    private var cloud: Float = 0.5
    private var depth: Float = 0.5
    private var glow: Float = 0.3
    private var drift: Float = 0.2

    // MARK: - Smoothed parameters

    private var cloudSmoothed: Float = 0.5
    private var depthSmoothed: Float = 0.5
    private var glowSmoothed: Float = 0.3
    private var driftSmoothed: Float = 0.2

    // MARK: - Derived parameters (smoothed)
    // Initial values must match what recalculateDerived produces for the default
    // params (cloud=0.5, depth=0.5, glow=0.3, drift=0.2).

    private var feedbackGain: Float = 0.8432       // 0.6 + pow(0.5, 0.7) * 0.395
    private var feedbackGainSmoothed: Float = 0.8432
    private var hfDampCoeff: Float = 0.42          // 0.6 * (1.0 - 0.3)
    private var hfDampCoeffSmoothed: Float = 0.42
    private var lfDampCoeff: Float = 0.0           // max(0, (0.3-0.3)*0.36)
    private var lfDampCoeffSmoothed: Float = 0.0
    private var depthDamping: Float = 0.9925       // 1.0 - 0.5 * 0.015
    private var depthDampingSmoothed: Float = 0.9925
    private var glowDrive: Float = 0.0             // max(0, (0.3-0.4)*1.67) = 0
    private var glowDriveSmoothed: Float = 0.0
    private var emissionGain: Float = 0.0          // max(0, (0.3-0.5)*0.4) = 0
    private var emissionGainSmoothed: Float = 0.0
    private var pitchShiftSemitones: Float = 0.0    // glow 0.3 in dead zone [0.3, 0.7]
    private var pitchShiftSemitonesSmoothed: Float = 0.0
    private var apCoeffBase: Float = 0.35          // 0.5 * 0.7
    private var apCoeffBaseSmoothed: Float = 0.35
    private var delayModDepth: Float = 40.0        // 0.2 * 200.0
    private var delayModDepthSmoothed: Float = 40.0
    private var delayModRate: Float = 0.5          // 0.1 + 0.2 * 2.0
    private var pitchWalkRange: Float = 0.004      // 0.2 * 0.02
    private var pitchWalkRate: Float = 0.1         // 0.2 * 0.5
    private var apModDepth: Float = 0.03           // 0.2 * 0.15

    private let paramSmooth: Float = 0.001
    private let derivedSmooth: Float = 0.0005

    // MARK: - Init

    init() {
        let n = Self.lineCount

        // Allocate 8 delay buffers
        delayBufs = .allocate(capacity: n)
        writeIndices = .allocate(capacity: n)
        for i in 0..<n {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDelaySamples)
            buf.initialize(repeating: 0, count: Self.maxDelaySamples)
            delayBufs[i] = buf
            writeIndices[i] = 0
        }

        // Allocate 16 allpass buffers (2 per line)
        apBufs1 = .allocate(capacity: n)
        apBufs2 = .allocate(capacity: n)
        apIdx1 = .allocate(capacity: n)
        apIdx2 = .allocate(capacity: n)
        for i in 0..<n {
            let b1 = UnsafeMutablePointer<Float>.allocate(capacity: Self.allpassSize1)
            b1.initialize(repeating: 0, count: Self.allpassSize1)
            apBufs1[i] = b1
            apIdx1[i] = 0

            let b2 = UnsafeMutablePointer<Float>.allocate(capacity: Self.allpassSize2)
            b2.initialize(repeating: 0, count: Self.allpassSize2)
            apBufs2[i] = b2
            apIdx2[i] = 0
        }

        // Allocate 8 pitch shifter buffers
        pitchBufs = .allocate(capacity: n)
        pitchWritePos = .allocate(capacity: n)
        grainPhases = .allocate(capacity: n)
        for i in 0..<n {
            let pb = UnsafeMutablePointer<Float>.allocate(capacity: Self.pitchBufSize)
            pb.initialize(repeating: 0, count: Self.pitchBufSize)
            pitchBufs[i] = pb
            pitchWritePos[i] = 0
            grainPhases[i] = Float(i) * Float(Self.pitchBufSize / n)  // stagger grain phases
        }

        // Allocate per-line filter state
        dampLP = .allocate(capacity: n)
        dampLP.initialize(repeating: 0, count: n)
        dampHP = .allocate(capacity: n)
        dampHP.initialize(repeating: 0, count: n)

        // 4 floats per line for glow bandpass state
        glowBPState = .allocate(capacity: n * 4)
        glowBPState.initialize(repeating: 0, count: n * 4)

        feedbackLines = .allocate(capacity: n)
        feedbackLines.initialize(repeating: 0, count: n)

        // Modulation state
        lcgState = .allocate(capacity: n)
        modPhases = .allocate(capacity: n)
        pitchDriftAcc = .allocate(capacity: n)
        apModValues = .allocate(capacity: n)
        for i in 0..<n {
            lcgState[i] = Self.tupleElement(Self.lcgSeeds, index: i)
            modPhases[i] = Float(i) / Float(n) * 2.0 * .pi
            pitchDriftAcc[i] = 0
            apModValues[i] = 0
        }

        // Computed delay state
        currentDelayLengths = .allocate(capacity: n)
        currentDelayLengths.initialize(repeating: 4800, count: n)  // ~100ms default
        currentAPLen1 = .allocate(capacity: n)
        currentAPLen1.initialize(repeating: 960, count: n)
        currentAPLen2 = .allocate(capacity: n)
        currentAPLen2.initialize(repeating: 1680, count: n)
        inputGains = .allocate(capacity: n)
        for i in 0..<n {
            inputGains[i] = 1.0 / 2.828427  // 1/√8
        }
    }

    // MARK: - Tuple access helper

    private static func tupleElement(_ t: (Float, Float, Float, Float, Float, Float, Float, Float), index: Int) -> Float {
        switch index {
        case 0: return t.0; case 1: return t.1; case 2: return t.2; case 3: return t.3
        case 4: return t.4; case 5: return t.5; case 6: return t.6; case 7: return t.7
        default: return t.0
        }
    }

    private static func tupleElement(_ t: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32), index: Int) -> UInt32 {
        switch index {
        case 0: return t.0; case 1: return t.1; case 2: return t.2; case 3: return t.3
        case 4: return t.4; case 5: return t.5; case 6: return t.6; case 7: return t.7
        default: return t.0
        }
    }

    // MARK: - Mono processing (sums to mono internally, outputs mono)

    mutating func process(sample: Float, sampleRate: Float) -> Float {
        let (outL, outR) = processStereo(sampleL: sample, sampleR: sample, sampleRate: sampleRate)
        return (outL + outR) * 0.5
    }

    // MARK: - Stereo processing (mono FDN → stereo output)

    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        smoothAllParameters()
        let inMono = (sampleL + sampleR) * 0.5

        // ── Per-line processing ──
        var lineOutputs = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))

        for i in 0..<Self.lineCount {
            // Inject input + feedback
            let injection = inMono * inputGains[i] + feedbackLines[i]

            // Write to delay buffer
            delayBufs[i][writeIndices[i]] = injection

            // Compute modulated delay read position
            let nominalDelay = currentDelayLengths[i]
            let modOffset = sin(modPhases[i]) * delayModDepthSmoothed
            let totalDelay = nominalDelay + modOffset
            let clampedDelay = max(1.0, min(totalDelay, Float(Self.maxDelaySamples - 4)))

            // Read with cubic Hermite interpolation
            var sample = Self.cubicRead(buffer: delayBufs[i], writeIndex: writeIndices[i],
                                        delaySamples: clampedDelay, bufferSize: Self.maxDelaySamples)

            // Advance write index
            writeIndices[i] = (writeIndices[i] + 1) % Self.maxDelaySamples

            // ── XFORM chain ──

            // 1. Allpass diffusion (2 stages)
            let apCoeff = max(0.0, min(0.75, apCoeffBaseSmoothed + apModValues[i]))
            sample = processAllpass(lineIndex: i, stage: 1, input: sample, coefficient: apCoeff)
            sample = processAllpass(lineIndex: i, stage: 2, input: sample, coefficient: apCoeff)

            // 2. Damping filter
            sample = processDamping(lineIndex: i, input: sample)

            // 3. Pitch shifter
            sample = processPitchShift(lineIndex: i, input: sample)

            // 4. Glow filter (harmonic excitation)
            sample = processGlow(lineIndex: i, input: sample, sampleRate: sampleRate)

            // Store line output
            switch i {
            case 0: lineOutputs.0 = sample
            case 1: lineOutputs.1 = sample
            case 2: lineOutputs.2 = sample
            case 3: lineOutputs.3 = sample
            case 4: lineOutputs.4 = sample
            case 5: lineOutputs.5 = sample
            case 6: lineOutputs.6 = sample
            case 7: lineOutputs.7 = sample
            default: break
            }

            // Update modulation phase
            modPhases[i] += delayModRate * 2.0 * .pi / sampleRate
            if modPhases[i] >= 2.0 * .pi { modPhases[i] -= 2.0 * .pi }
        }

        // ── Hadamard 8×8 butterfly mixing ──
        Self.hadamard8(&lineOutputs)

        // ── Apply feedback gain + safety limiter ──
        var emergencyReduce: Float = 0.0
        for i in 0..<Self.lineCount {
            var val: Float
            switch i {
            case 0: val = lineOutputs.0; case 1: val = lineOutputs.1
            case 2: val = lineOutputs.2; case 3: val = lineOutputs.3
            case 4: val = lineOutputs.4; case 5: val = lineOutputs.5
            case 6: val = lineOutputs.6; case 7: val = lineOutputs.7
            default: val = 0
            }

            val *= feedbackGainSmoothed

            // Emergency gain reduction: if any line > 2.0, reduce feedback
            if abs(val) > 2.0 {
                emergencyReduce = max(emergencyReduce, 0.01)
            }

            // tanh clip on feedback
            val = Self.tanhClip(val)
            feedbackLines[i] = val
        }

        // Apply emergency reduction
        if emergencyReduce > 0 {
            feedbackGainSmoothed = max(0.1, feedbackGainSmoothed - emergencyReduce)
        }

        // Update drift random walks
        updateDriftModulation(sampleRate: sampleRate)

        // ── Stereo output tapping ──
        // Even lines → L, odd lines → R
        let rawL = (lineOutputs.0 + lineOutputs.2 + lineOutputs.4 + lineOutputs.6) * 0.25
        let rawR = (lineOutputs.1 + lineOutputs.3 + lineOutputs.5 + lineOutputs.7) * 0.25

        // Cross-feed: 20%
        let crossFeed: Float = 0.2
        let outputBoost: Float = 1.33  // +2.5 dB
        var outL = (rawL + rawR * crossFeed) * outputBoost
        var outR = (rawR + rawL * crossFeed) * outputBoost

        // ── DC blockers ──
        let dcCoeff: Float = 1.0 - (2.0 * .pi * 5.0 / sampleRate)
        let dcOutL = outL - dcX1L + dcCoeff * dcY1L
        dcX1L = outL
        dcY1L = dcOutL
        outL = dcOutL

        let dcOutR = outR - dcX1R + dcCoeff * dcY1R
        dcX1R = outR
        dcY1R = dcOutR
        outR = dcOutR

        // ── Envelope followers with soft gain reduction ──
        let releaseCoeff: Float = 1.0 - 1.0 / (0.15 * sampleRate)
        let ceiling: Float = 0.85

        let absL = abs(outL)
        envelopeL = absL > envelopeL ? absL : envelopeL * releaseCoeff
        if envelopeL > ceiling { outL *= ceiling / envelopeL }

        let absR = abs(outR)
        envelopeR = absR > envelopeR ? absR : envelopeR * releaseCoeff
        if envelopeR > ceiling { outR *= ceiling / envelopeR }

        return (outL, outR)
    }

    // MARK: - Allpass diffusion

    private mutating func processAllpass(lineIndex i: Int, stage: Int, input: Float, coefficient: Float) -> Float {
        let buf: UnsafeMutablePointer<Float>
        let idx: UnsafeMutablePointer<Int>
        let maxSize: Int
        let nominalLen: Float

        if stage == 1 {
            buf = apBufs1[i]
            idx = apIdx1.advanced(by: i)
            maxSize = Self.allpassSize1
            nominalLen = currentAPLen1[i]
        } else {
            buf = apBufs2[i]
            idx = apIdx2.advanced(by: i)
            maxSize = Self.allpassSize2
            nominalLen = currentAPLen2[i]
        }

        let len = max(1, min(Int(nominalLen), maxSize - 1))
        let readIdx = (idx.pointee - len + maxSize) % maxSize
        let delayed = buf[readIdx]

        let v = input + delayed * coefficient
        buf[idx.pointee] = v
        idx.pointee = (idx.pointee + 1) % maxSize
        let output = delayed - v * coefficient

        return output
    }

    // MARK: - Damping filter

    private mutating func processDamping(lineIndex i: Int, input: Float) -> Float {
        // One-pole LP reference (fixed cutoff ~5kHz at 48kHz)
        dampLP[i] += 0.5 * (input - dampLP[i])

        // Blend toward LP: hfDampCoeff is damping amount (0 = transparent, 0.6 = dark)
        // Signal always passes — no more frozen filter at high glow
        let afterLP = input + (dampLP[i] - input) * hfDampCoeffSmoothed

        // One-pole HP (LF damping)
        dampHP[i] += lfDampCoeffSmoothed * (afterLP - dampHP[i])
        let afterHP = afterLP - dampHP[i] * lfDampCoeffSmoothed

        // Depth-dependent overall damping
        return afterHP * depthDampingSmoothed
    }

    // MARK: - Pitch shifter (2-grain Hann-windowed overlap)

    private mutating func processPitchShift(lineIndex i: Int, input: Float) -> Float {
        let bufSize = Self.pitchBufSize
        let grainSize: Float = 2048.0

        // Write input
        pitchBufs[i][pitchWritePos[i]] = input
        pitchWritePos[i] = (pitchWritePos[i] + 1) % bufSize

        // Compute total shift: base from Glow + random walk from Drift
        let totalShift = pitchShiftSemitonesSmoothed + pitchDriftAcc[i] / 100.0
        let shiftRate = powf(2.0, totalShift / 12.0)
        let readDelta = 1.0 - shiftRate

        // Skip processing if shift is negligible (< 1 cent = 0.01 semitones).
        // The grain overlap pitch shifter introduces comb filtering and ~1024 samples
        // of grain fill-up latency, which is destructive for near-zero shifts.
        if abs(totalShift) < 0.02 {
            return input
        }

        let phase = grainPhases[i]
        let wPos = Float(pitchWritePos[i])

        // Grain A
        var readPosA = wPos - phase
        if readPosA < 0 { readPosA += Float(bufSize) }
        let sampleA = Self.linearReadPitch(buffer: pitchBufs[i], at: readPosA, bufferSize: bufSize)
        let windowA = Self.hannWindow(phase / grainSize)

        // Grain B (offset by half grain)
        let phaseB = phase + grainSize * 0.5
        let phaseBWrapped = phaseB >= grainSize ? phaseB - grainSize : phaseB
        var readPosB = wPos - phaseBWrapped
        if readPosB < 0 { readPosB += Float(bufSize) }
        let sampleB = Self.linearReadPitch(buffer: pitchBufs[i], at: readPosB, bufferSize: bufSize)
        let windowB = Self.hannWindow(phaseBWrapped / grainSize)

        // Advance grain phase
        grainPhases[i] += 1.0 + readDelta
        if grainPhases[i] >= grainSize { grainPhases[i] -= grainSize }
        if grainPhases[i] < 0 { grainPhases[i] += grainSize }

        return sampleA * windowA + sampleB * windowB
    }

    /// Hann window: sin²(π × t) for t in [0,1]
    private static func hannWindow(_ t: Float) -> Float {
        let clamped = max(0, min(1, t))
        let s = sinf(.pi * clamped)
        return s * s
    }

    /// Linear interpolation read from pitch buffer
    private static func linearReadPitch(buffer: UnsafeMutablePointer<Float>, at pos: Float, bufferSize: Int) -> Float {
        let idx0 = Int(pos) % bufferSize
        let idx1 = (idx0 + 1) % bufferSize
        let frac = pos - Float(Int(pos))
        return buffer[idx0] * (1.0 - frac) + buffer[idx1] * frac
    }

    // MARK: - Glow filter (harmonic excitation via resonant bandpasses)

    private mutating func processGlow(lineIndex i: Int, input: Float, sampleRate: Float) -> Float {
        // Early-out: no glow processing when drive is negligible
        guard glowDriveSmoothed > 0.01 else { return input }

        // Soft saturation — generates odd harmonics
        let driven = Self.tanhClip(input * (1.0 + glowDriveSmoothed * 3.0)) / (1.0 + glowDriveSmoothed * 0.5)

        // Emission line bandpass filters (Chamberlin SVF)
        let baseIdx = i * 4

        let freq1 = Self.tupleElement(Self.emissionFreqs1, index: i) + glowSmoothed * 500.0
        let freq2 = Self.tupleElement(Self.emissionFreqs2, index: i) + glowSmoothed * 1500.0
        let q = 3.0 + glowSmoothed * 7.0  // Q: 3–10

        // SVF bandpass 1
        let f1 = 2.0 * sinf(.pi * min(freq1, sampleRate * 0.48) / sampleRate)
        let q1 = 1.0 / q
        let bp1Low = glowBPState[baseIdx] + f1 * glowBPState[baseIdx + 1]
        let bp1High = driven * q1 - bp1Low - q1 * glowBPState[baseIdx + 1]
        let bp1Band = f1 * bp1High + glowBPState[baseIdx + 1]
        glowBPState[baseIdx] = bp1Low
        glowBPState[baseIdx + 1] = bp1Band

        // SVF bandpass 2
        let f2 = 2.0 * sinf(.pi * min(freq2, sampleRate * 0.48) / sampleRate)
        let bp2Low = glowBPState[baseIdx + 2] + f2 * glowBPState[baseIdx + 3]
        let bp2High = driven * q1 - bp2Low - q1 * glowBPState[baseIdx + 3]
        let bp2Band = f2 * bp2High + glowBPState[baseIdx + 3]
        glowBPState[baseIdx + 2] = bp2Low
        glowBPState[baseIdx + 3] = bp2Band

        let emitted = driven + (bp1Band + bp2Band) * emissionGainSmoothed

        // Energy-neutral blend: redistribute, don't add
        let dry = 1.0 - glowDriveSmoothed * 0.5
        let wet = glowDriveSmoothed * 0.5
        return input * dry + emitted * wet
    }

    // MARK: - Hadamard 8×8 butterfly (in-place, energy-preserving)

    private static func hadamard8(_ v: inout (Float, Float, Float, Float, Float, Float, Float, Float)) {
        // Stage 1: pairs
        let a0 = v.0 + v.1; let a1 = v.0 - v.1
        let a2 = v.2 + v.3; let a3 = v.2 - v.3
        let a4 = v.4 + v.5; let a5 = v.4 - v.5
        let a6 = v.6 + v.7; let a7 = v.6 - v.7

        // Stage 2: quads
        let b0 = a0 + a2; let b1 = a1 + a3
        let b2 = a0 - a2; let b3 = a1 - a3
        let b4 = a4 + a6; let b5 = a5 + a7
        let b6 = a4 - a6; let b7 = a5 - a7

        // Stage 3: octets + normalize
        v.0 = (b0 + b4) * hadamardScale
        v.1 = (b1 + b5) * hadamardScale
        v.2 = (b2 + b6) * hadamardScale
        v.3 = (b3 + b7) * hadamardScale
        v.4 = (b0 - b4) * hadamardScale
        v.5 = (b1 - b5) * hadamardScale
        v.6 = (b2 - b6) * hadamardScale
        v.7 = (b3 - b7) * hadamardScale
    }

    // MARK: - Drift modulation update

    private mutating func updateDriftModulation(sampleRate: Float) {
        for i in 0..<Self.lineCount {
            // Advance LCG
            lcgState[i] = lcgState[i] &* 1_664_525 &+ 1_013_904_223

            // Pitch random walk
            let rand01 = Float(lcgState[i]) / Float(UInt32.max)
            let randBipolar = rand01 * 2.0 - 1.0
            pitchDriftAcc[i] += randBipolar * pitchWalkRate / sampleRate
            pitchDriftAcc[i] *= 0.9999  // slow decay toward zero
            pitchDriftAcc[i] = max(-2.0, min(2.0, pitchDriftAcc[i]))  // ±2 cents max
            pitchDriftAcc[i] *= pitchWalkRange > 0.0001 ? 1.0 : 0.0  // zero when drift is off

            // Allpass coefficient modulation
            lcgState[i] = lcgState[i] &* 1_664_525 &+ 1_013_904_223
            let rand2 = Float(lcgState[i]) / Float(UInt32.max) * 2.0 - 1.0
            apModValues[i] += (rand2 * apModDepth - apModValues[i]) * 0.01
            apModValues[i] = max(-0.15, min(0.15, apModValues[i]))
        }
    }

    // MARK: - Parameter smoothing

    private mutating func smoothAllParameters() {
        cloudSmoothed += (cloud - cloudSmoothed) * paramSmooth
        depthSmoothed += (depth - depthSmoothed) * paramSmooth
        glowSmoothed += (glow - glowSmoothed) * paramSmooth
        driftSmoothed += (drift - driftSmoothed) * paramSmooth

        feedbackGainSmoothed += (feedbackGain - feedbackGainSmoothed) * derivedSmooth
        hfDampCoeffSmoothed += (hfDampCoeff - hfDampCoeffSmoothed) * derivedSmooth
        lfDampCoeffSmoothed += (lfDampCoeff - lfDampCoeffSmoothed) * derivedSmooth
        depthDampingSmoothed += (depthDamping - depthDampingSmoothed) * derivedSmooth
        glowDriveSmoothed += (glowDrive - glowDriveSmoothed) * derivedSmooth
        emissionGainSmoothed += (emissionGain - emissionGainSmoothed) * derivedSmooth
        pitchShiftSemitonesSmoothed += (pitchShiftSemitones - pitchShiftSemitonesSmoothed) * derivedSmooth
        apCoeffBaseSmoothed += (apCoeffBase - apCoeffBaseSmoothed) * derivedSmooth
        delayModDepthSmoothed += (delayModDepth - delayModDepthSmoothed) * derivedSmooth
    }

    // MARK: - Control mapping

    private mutating func recalculateDerived(sampleRate: Float) {
        // Use raw target values (not smoothed) — this is called once at creation time,
        // so we need the actual parameter values, not the slowly-converging smoothed ones.

        // ── Depth → delay, feedback, damping ──
        let d = depth
        let baseDelayMs = 10.0 * powf(200.0, d)
        let baseDelaySamples = baseDelayMs * 0.001 * sampleRate

        feedbackGain = 0.6 + 0.395 * powf(d, 0.7)
        depthDamping = 1.0 - d * 0.015

        // ── Cloud → allpass, delay spread, injection ──
        let c = cloud
        apCoeffBase = c * 0.7  // 0–0.7
        let spreadRatio = 0.1 + c * 0.9

        let activeLines = max(2, Int(c * 8.0))
        let injectionGain = 1.0 / sqrtf(Float(activeLines))

        for i in 0..<Self.lineCount {
            let ratio = Self.tupleElement(Self.delayRatios, index: i)
            let lineSpread = powf(Float(i + 1) / 8.0, 1.0 + (1.0 - spreadRatio) * 3.0)
            let delayLen = baseDelaySamples * ratio * lineSpread * spreadRatio
                         + baseDelaySamples * ratio * (1.0 - spreadRatio)
            currentDelayLengths[i] = max(1.0, min(Float(Self.maxDelaySamples - 4), delayLen))

            // Allpass lengths scale with delay
            currentAPLen1[i] = max(1.0, min(Float(Self.allpassSize1 - 1), delayLen * 0.2))
            currentAPLen2[i] = max(1.0, min(Float(Self.allpassSize2 - 1), delayLen * 0.35))

            // Injection gains
            inputGains[i] = i < activeLines ? injectionGain : 0.0
        }

        // ── Glow → damping profile, excitation, pitch ──
        let g = glow
        glowDrive = max(0, (g - 0.4) * 1.67)
        emissionGain = max(0, (g - 0.5) * 0.4)

        // HF damping floor scales with excitation to prevent self-oscillation
        hfDampCoeff = 0.6 * (1.0 - g) + glowDrive * 0.15
        lfDampCoeff = max(0, (g - 0.3) * 0.36)

        if g < 0.3 {
            pitchShiftSemitones = (0.3 - g) * -6.0 / 100.0  // red-shift up to -1.8 cents
        } else if g > 0.7 {
            pitchShiftSemitones = (g - 0.7) * 12.0 / 100.0  // blue-shift up to +3.6 cents
        } else {
            pitchShiftSemitones = 0  // dead zone — no comb artifacts in feedback loop
        }

        // ── Drift → modulation depths ──
        let dr = drift
        delayModDepth = dr * 200.0
        delayModRate = 0.1 + dr * 2.0
        pitchWalkRange = dr * 0.02
        pitchWalkRate = dr * 0.5
        apModDepth = dr * 0.15
    }

    // MARK: - Cubic Hermite interpolation

    private static func cubicRead(buffer: UnsafeMutablePointer<Float>, writeIndex: Int,
                                   delaySamples: Float, bufferSize: Int) -> Float {
        let readPos = Float(writeIndex) - delaySamples
        let readPosWrapped = readPos < 0 ? readPos + Float(bufferSize) : readPos

        let idx1 = Int(readPosWrapped) % bufferSize
        let idx0 = (idx1 - 1 + bufferSize) % bufferSize
        let idx2 = (idx1 + 1) % bufferSize
        let idx3 = (idx1 + 2) % bufferSize

        let frac = readPosWrapped - Float(Int(readPosWrapped))

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

    // MARK: - Utilities

    private static func tanhClip(_ x: Float) -> Float {
        if x > 3.0 { return 1.0 }
        if x < -3.0 { return -1.0 }
        let x2 = x * x
        return x * (27.0 + x2) / (27.0 + 9.0 * x2)
    }

    // MARK: - Update parameters

    mutating func updateParameters(_ params: [String: Double]) {
        var needsRecalc = false
        if let c = params["cloud"] {
            cloud = max(0, min(1, Float(c)))
            needsRecalc = true
        }
        if let d = params["depth"] {
            depth = max(0, min(1, Float(d)))
            needsRecalc = true
        }
        if let g = params["glow"] {
            glow = max(0, min(1, Float(g)))
            needsRecalc = true
        }
        if let dr = params["drift"] {
            drift = max(0, min(1, Float(dr)))
            needsRecalc = true
        }
        if needsRecalc {
            // Snap smoothed params to targets — the effect is freshly created on every
            // chain rebuild, so there's no old state to smooth from.
            cloudSmoothed = cloud
            depthSmoothed = depth
            glowSmoothed = glow
            driftSmoothed = drift

            recalculateDerived(sampleRate: 48000)

            // Snap derived smoothed values to their targets so the effect starts
            // with correct parameters immediately, no convergence lag.
            feedbackGainSmoothed = feedbackGain
            hfDampCoeffSmoothed = hfDampCoeff
            lfDampCoeffSmoothed = lfDampCoeff
            depthDampingSmoothed = depthDamping
            glowDriveSmoothed = glowDrive
            emissionGainSmoothed = emissionGain
            pitchShiftSemitonesSmoothed = pitchShiftSemitones
            apCoeffBaseSmoothed = apCoeffBase
            delayModDepthSmoothed = delayModDepth
        }
    }

    // MARK: - Reset

    mutating func reset() {
        let n = Self.lineCount

        for i in 0..<n {
            // Clear delay buffers
            for j in 0..<Self.maxDelaySamples {
                delayBufs[i][j] = 0
            }
            writeIndices[i] = 0

            // Clear allpass buffers
            for j in 0..<Self.allpassSize1 {
                apBufs1[i][j] = 0
            }
            for j in 0..<Self.allpassSize2 {
                apBufs2[i][j] = 0
            }
            apIdx1[i] = 0
            apIdx2[i] = 0

            // Clear pitch buffers
            for j in 0..<Self.pitchBufSize {
                pitchBufs[i][j] = 0
            }
            pitchWritePos[i] = 0
            grainPhases[i] = Float(i) * Float(Self.pitchBufSize / n)

            // Clear filter state
            dampLP[i] = 0
            dampHP[i] = 0
            glowBPState[i * 4] = 0
            glowBPState[i * 4 + 1] = 0
            glowBPState[i * 4 + 2] = 0
            glowBPState[i * 4 + 3] = 0

            feedbackLines[i] = 0

            // Reset modulation
            lcgState[i] = Self.tupleElement(Self.lcgSeeds, index: i)
            modPhases[i] = Float(i) / Float(n) * 2.0 * .pi
            pitchDriftAcc[i] = 0
            apModValues[i] = 0
        }

        // Reset DC blockers
        dcX1L = 0; dcY1L = 0
        dcX1R = 0; dcY1R = 0

        // Reset envelopes
        envelopeL = 0
        envelopeR = 0
    }

    // MARK: - Presets

    struct Preset {
        let name: String
        let cloud: Float
        let depth: Float
        let glow: Float
        let drift: Float
    }

    static let presets: [Preset] = [
        Preset(name: "Interstellar", cloud: 0.6,  depth: 0.7,  glow: 0.25, drift: 0.2),
        Preset(name: "Dark Matter",  cloud: 0.7,  depth: 0.85, glow: 0.0,  drift: 0.15),
        Preset(name: "Emission",     cloud: 0.5,  depth: 0.6,  glow: 0.8,  drift: 0.25),
        Preset(name: "Pulsar",       cloud: 0.2,  depth: 0.4,  glow: 0.5,  drift: 0.1),
        Preset(name: "Solar Wind",   cloud: 0.5,  depth: 0.5,  glow: 0.6,  drift: 0.7),
        Preset(name: "Event Horizon",cloud: 0.9,  depth: 1.0,  glow: 0.3,  drift: 0.3),
        Preset(name: "Supernova",    cloud: 0.7,  depth: 0.8,  glow: 1.0,  drift: 0.6),
        Preset(name: "Cosmic Dust",  cloud: 0.4,  depth: 0.3,  glow: 0.15, drift: 0.4),
        Preset(name: "Red Giant",    cloud: 0.8,  depth: 0.7,  glow: 0.0,  drift: 0.5),
        Preset(name: "Aurora",       cloud: 0.3,  depth: 0.5,  glow: 0.9,  drift: 0.8),
        Preset(name: "Void",         cloud: 0.95, depth: 0.95, glow: 0.1,  drift: 0.0),
        Preset(name: "Genesis",      cloud: 0.5,  depth: 0.6,  glow: 0.65, drift: 0.3),
        Preset(name: "Stardust",     cloud: 0.35, depth: 0.45, glow: 0.5,  drift: 0.35),
        Preset(name: "Quasar",       cloud: 0.6,  depth: 0.9,  glow: 0.95, drift: 0.9),
    ]

    mutating func applyPreset(_ preset: Preset) {
        updateParameters([
            "cloud": Double(preset.cloud),
            "depth": Double(preset.depth),
            "glow": Double(preset.glow),
            "drift": Double(preset.drift)
        ])
    }
}
