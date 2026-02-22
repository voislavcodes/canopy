import Foundation
import Accelerate

/// MELT — Spectral Gravity Effect.
///
/// Frequencies have mass. Gravity pulls them down. Each FFT bin has a position,
/// velocity, and experiences Newtonian forces: gravity (down), viscosity (drag),
/// floor (hard stop), heat (up + turbulence). The spectrum is a physical system.
///
/// True stereo: shared physics engine (both channels' bins fall at same rate),
/// independent amplitude envelopes per channel from separate FFT analyses.
///
/// Resynthesis: oscillator bank. Each FFT bin maps to a sine oscillator whose
/// frequency tracks the displaced bin position and whose amplitude tracks the
/// analyzed magnitude. Per-sample linear interpolation of frequency and amplitude
/// ensures continuous transitions — no frame boundaries, no overlap-add, no crackles.
///
/// Parameters:
/// - `gravity`: Downward force strength (0.0–1.0). 0 = zero-G, 1 = singularity.
/// - `viscosity`: Resistance to falling (0.0–1.0). 0 = vacuum, 1 = tar.
/// - `floor`: Lowest frequency bins can fall to (0.0–1.0). 0 = sub-bass, 1 = upper-mid.
/// - `heat`: Upward restoring force + turbulence (0.0–1.0). 0 = cold, 1 = plasma.
struct MeltEffect {

    // MARK: - FFT Constants

    private static let fftSize = 2048
    private static let halfFFT = 1024
    private static let hopSize = 512
    private static let log2n: vDSP_Length = 11

    /// Converts FFT magnitude → oscillator amplitude.
    /// 4/N compensates for Hann window coherent gain in the DFT.
    private static let oscAmpScale: Float = 4.0 / Float(fftSize)

    // MARK: - FFT Setup

    private let fftSetup: FFTSetup

    // MARK: - Input Ring Buffers (stereo)

    private let inputRingL: UnsafeMutablePointer<Float>
    private let inputRingR: UnsafeMutablePointer<Float>
    private var inputWritePos: Int = 0

    // MARK: - FFT Working Buffers (analysis only)

    private let windowedBuf: UnsafeMutablePointer<Float>
    private let fftRealIn: UnsafeMutablePointer<Float>
    private let fftImagIn: UnsafeMutablePointer<Float>

    // MARK: - Physics State (shared across L/R)

    private let binPositions: UnsafeMutablePointer<Float>
    private let binVelocities: UnsafeMutablePointer<Float>
    private let naturalPositions: UnsafeMutablePointer<Float>

    // MARK: - Pre-computed Window

    private let hannWindow: UnsafeMutablePointer<Float>

    // MARK: - Oscillator Bank

    private let oscPhases: UnsafeMutablePointer<Float>
    private let oscFreqs: UnsafeMutablePointer<Float>
    private let oscFreqIncs: UnsafeMutablePointer<Float>
    private let oscAmpsL: UnsafeMutablePointer<Float>
    private let oscAmpsR: UnsafeMutablePointer<Float>
    private let oscAmpIncsL: UnsafeMutablePointer<Float>
    private let oscAmpIncsR: UnsafeMutablePointer<Float>

    // Scratch buffers for vectorized sin
    private let sinInput: UnsafeMutablePointer<Float>
    private let sinOutput: UnsafeMutablePointer<Float>

    // MARK: - Hop Counter

    private var hopCounter: Int
    private var samplesProcessed: Int = 0

    // MARK: - DC Blockers (stereo)

    private var dcX1L: Float = 0
    private var dcY1L: Float = 0
    private var dcX1R: Float = 0
    private var dcY1R: Float = 0

    // MARK: - Noise State

    private var noiseStateL: UInt32 = 77_777
    private var noiseStateR: UInt32 = 54_321

    // MARK: - Parameter Targets

    private var gravity: Float = 0.4
    private var viscosity: Float = 0.3
    private var floor_: Float = 0.0
    private var heat: Float = 0.2

    // MARK: - Smoothed Parameters

    private var gravitySmooth: Float = 0.4
    private var viscositySmooth: Float = 0.3
    private var floorSmooth: Float = 0.0
    private var heatSmooth: Float = 0.2

    private let paramSmoothCoeff: Float = 0.001

    // MARK: - Init

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!

        let fft = Self.fftSize
        let half = Self.halfFFT

        // Input ring buffers
        inputRingL = .allocate(capacity: fft)
        inputRingL.initialize(repeating: 0, count: fft)
        inputRingR = .allocate(capacity: fft)
        inputRingR.initialize(repeating: 0, count: fft)

        // FFT working buffers (analysis only)
        windowedBuf = .allocate(capacity: fft)
        windowedBuf.initialize(repeating: 0, count: fft)
        fftRealIn = .allocate(capacity: half)
        fftRealIn.initialize(repeating: 0, count: half)
        fftImagIn = .allocate(capacity: half)
        fftImagIn.initialize(repeating: 0, count: half)

        // Physics state
        binPositions = .allocate(capacity: half)
        binVelocities = .allocate(capacity: half)
        naturalPositions = .allocate(capacity: half)
        for i in 0..<half {
            let pos = Float(i) / Float(half)
            binPositions[i] = pos
            naturalPositions[i] = pos
            binVelocities[i] = 0
        }

        // Hann window
        hannWindow = .allocate(capacity: fft)
        for i in 0..<fft {
            hannWindow[i] = 0.5 * (1.0 - cos(2.0 * .pi * Float(i) / Float(fft)))
        }

        // Oscillator bank
        oscPhases = .allocate(capacity: half)
        oscPhases.initialize(repeating: 0, count: half)
        oscFreqs = .allocate(capacity: half)
        oscFreqs.initialize(repeating: 0, count: half)
        oscFreqIncs = .allocate(capacity: half)
        oscFreqIncs.initialize(repeating: 0, count: half)
        oscAmpsL = .allocate(capacity: half)
        oscAmpsL.initialize(repeating: 0, count: half)
        oscAmpsR = .allocate(capacity: half)
        oscAmpsR.initialize(repeating: 0, count: half)
        oscAmpIncsL = .allocate(capacity: half)
        oscAmpIncsL.initialize(repeating: 0, count: half)
        oscAmpIncsR = .allocate(capacity: half)
        oscAmpIncsR.initialize(repeating: 0, count: half)

        // Scratch for vectorized sin
        sinInput = .allocate(capacity: half)
        sinInput.initialize(repeating: 0, count: half)
        sinOutput = .allocate(capacity: half)
        sinOutput.initialize(repeating: 0, count: half)

        hopCounter = Self.hopSize
    }

    // MARK: - Mono Processing

    mutating func process(sample: Float, sampleRate: Float) -> Float {
        let (outL, _) = processStereo(sampleL: sample, sampleR: sample, sampleRate: sampleRate)
        return outL
    }

    // MARK: - True Stereo Processing

    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        // Smooth parameters
        gravitySmooth += (gravity - gravitySmooth) * paramSmoothCoeff
        viscositySmooth += (viscosity - viscositySmooth) * paramSmoothCoeff
        floorSmooth += (floor_ - floorSmooth) * paramSmoothCoeff
        heatSmooth += (heat - heatSmooth) * paramSmoothCoeff

        // Push to ring buffers
        inputRingL[inputWritePos] = sampleL
        inputRingR[inputWritePos] = sampleR
        inputWritePos = (inputWritePos + 1) % Self.fftSize

        // Hop check
        hopCounter -= 1
        if hopCounter <= 0 {
            hopCounter = Self.hopSize
            processHop(sampleRate: sampleRate)
        }

        samplesProcessed += 1

        // Silence during ring buffer fill (oscillators ramp from 0 naturally)
        if samplesProcessed < Self.fftSize {
            return (0, 0)
        }

        // ── Oscillator bank output (vectorized) ──
        let half = Self.halfFFT

        // Interpolate frequencies: oscFreqs += oscFreqIncs
        vDSP_vadd(oscFreqs, 1, oscFreqIncs, 1, oscFreqs, 1, vDSP_Length(half))

        // Interpolate amplitudes
        vDSP_vadd(oscAmpsL, 1, oscAmpIncsL, 1, oscAmpsL, 1, vDSP_Length(half))
        vDSP_vadd(oscAmpsR, 1, oscAmpIncsR, 1, oscAmpsR, 1, vDSP_Length(half))

        // Advance phases: oscPhases += oscFreqs / sampleRate
        var invSR = 1.0 / sampleRate
        vDSP_vsma(oscFreqs, 1, &invSR, oscPhases, 1, oscPhases, 1, vDSP_Length(half))

        // Wrap phases to [0, 1): oscPhases -= floor(oscPhases)
        var count = Int32(half)
        vvfloorf(sinInput, oscPhases, &count)
        vDSP_vsub(sinInput, 1, oscPhases, 1, oscPhases, 1, vDSP_Length(half))

        // sin(2π × phases)
        var twoPi = Float(2.0 * .pi)
        vDSP_vsmul(oscPhases, 1, &twoPi, sinInput, 1, vDSP_Length(half))
        vvsinf(sinOutput, sinInput, &count)

        // Dot product: outL = sum(oscAmpsL * sinOutput)
        var outL: Float = 0
        var outR: Float = 0
        vDSP_dotpr(oscAmpsL, 1, sinOutput, 1, &outL, vDSP_Length(half))
        vDSP_dotpr(oscAmpsR, 1, sinOutput, 1, &outR, vDSP_Length(half))

        // Fade-in over 512 samples after initial silence (avoids click at unmute)
        let fadeLen: Float = 512
        let fadeSamples = samplesProcessed - Self.fftSize
        if fadeSamples < Int(fadeLen) {
            let fade = Float(fadeSamples) / fadeLen
            outL *= fade
            outR *= fade
        }

        // DC blockers (5Hz one-pole HP)
        let dcCoeff: Float = 1.0 - (2.0 * .pi * 5.0 / sampleRate)

        let dcOutL = outL - dcX1L + dcCoeff * dcY1L
        dcX1L = outL
        dcY1L = dcOutL
        outL = dcOutL

        let dcOutR = outR - dcX1R + dcCoeff * dcY1R
        dcX1R = outR
        dcY1R = dcOutR
        outR = dcOutR

        return (outL, outR)
    }

    // MARK: - Per-Hop Processing

    private mutating func processHop(sampleRate: Float) {
        let half = Self.halfFFT
        let hop = Self.hopSize
        let dt = Float(hop) / sampleRate
        let nyquist = sampleRate * 0.5
        let invHop = 1.0 / Float(hop)

        // 1. Advance physics
        advancePhysics(dt: dt)

        // 2. Analyze L → set L amplitude targets
        analyzeChannel(inputRing: inputRingL)
        for bin in 1..<half {
            let re = fftRealIn[bin]
            let im = fftImagIn[bin]
            let mag = sqrtf(re * re + im * im)
            let target = mag * Self.oscAmpScale
            oscAmpIncsL[bin] = (target - oscAmpsL[bin]) * invHop
        }

        // 3. Analyze R → set R amplitude targets
        analyzeChannel(inputRing: inputRingR)
        for bin in 1..<half {
            let re = fftRealIn[bin]
            let im = fftImagIn[bin]
            let mag = sqrtf(re * re + im * im)
            let target = mag * Self.oscAmpScale
            oscAmpIncsR[bin] = (target - oscAmpsR[bin]) * invHop
        }

        // 4. Set frequency targets from displaced bin positions
        for bin in 1..<half {
            let targetFreq = binPositions[bin] * nyquist
            oscFreqIncs[bin] = (targetFreq - oscFreqs[bin]) * invHop
        }
    }

    // MARK: - FFT Analysis

    private mutating func analyzeChannel(inputRing: UnsafeMutablePointer<Float>) {
        let fft = Self.fftSize
        let half = Self.halfFFT

        // Copy from ring buffer with Hann windowing
        for i in 0..<fft {
            let ringIdx = (inputWritePos - fft + i + fft) % fft
            windowedBuf[i] = inputRing[ringIdx] * hannWindow[i]
        }

        // Pack into split complex format
        let splitReal = fftRealIn
        let splitImag = fftImagIn
        windowedBuf.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
            var split = DSPSplitComplex(realp: splitReal, imagp: splitImag)
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
        }

        // Forward FFT
        var splitComplex = DSPSplitComplex(realp: fftRealIn, imagp: fftImagIn)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        // Scale by 0.5 (vDSP convention)
        var scale: Float = 0.5
        vDSP_vsmul(fftRealIn, 1, &scale, fftRealIn, 1, vDSP_Length(half))
        vDSP_vsmul(fftImagIn, 1, &scale, fftImagIn, 1, vDSP_Length(half))

        // Zero DC (realp[0]) and Nyquist (imagp[0]) — vDSP packed format
        fftRealIn[0] = 0
        fftImagIn[0] = 0
    }

    // MARK: - Physics Engine

    private mutating func advancePhysics(dt: Float) {
        let half = Self.halfFFT
        let gravityForce = gravitySmooth * 2.0
        let viscCoeff = 0.01 + viscositySmooth * 0.99
        let heatForce = heatSmooth * 2.0

        // Remap floor: quadratic curve, 0→sub-bass, 1→~3.3 kHz (bin 154)
        let effectiveFloor = floorSmooth * floorSmooth * 0.15
        let minPos = max(effectiveFloor, 1.0 / Float(half))

        for bin in 0..<half {
            let naturalPos = naturalPositions[bin]
            let currentPos = binPositions[bin]

            // Gravity (toward floor)
            let heightAboveFloor = max(0, currentPos - effectiveFloor)
            let gForce = -gravityForce * heightAboveFloor

            // Viscosity (opposes motion)
            let viscForce = -binVelocities[bin] * viscCoeff * 10.0

            // Heat restoring (toward natural position)
            let hForce = heatForce * (naturalPos - currentPos)

            // Heat turbulence (random kicks)
            var turbulence: Float = 0
            if heatSmooth > 0.1 {
                noiseStateL = noiseStateL &* 1_664_525 &+ 1_013_904_223
                let rand01 = Float(noiseStateL) / Float(UInt32.max)
                turbulence = (rand01 - 0.3) * heatSmooth * 0.5
            }

            // Semi-implicit Euler
            let totalForce = gForce + viscForce + hForce + turbulence
            binVelocities[bin] += totalForce * dt
            binVelocities[bin] = max(-2.0, min(2.0, binVelocities[bin]))
            binPositions[bin] += binVelocities[bin] * dt

            // Hard floor clamp
            if binPositions[bin] < minPos {
                binPositions[bin] = minPos
                if binVelocities[bin] < 0 { binVelocities[bin] = 0 }
            }
            binPositions[bin] = min(1.0, binPositions[bin])
        }
    }

    // MARK: - Update Parameters

    mutating func updateParameters(_ params: [String: Double]) {
        if let g = params["gravity"] {
            gravity = max(0, min(1, Float(g)))
        }
        if let v = params["viscosity"] {
            viscosity = max(0, min(1, Float(v)))
        }
        if let f = params["floor"] {
            floor_ = max(0, min(1, Float(f)))
        }
        if let h = params["heat"] {
            heat = max(0, min(1, Float(h)))
        }

        gravitySmooth = gravity
        viscositySmooth = viscosity
        floorSmooth = floor_
        heatSmooth = heat
    }

    // MARK: - Reset

    mutating func reset() {
        let fft = Self.fftSize
        let half = Self.halfFFT

        for i in 0..<fft {
            inputRingL[i] = 0
            inputRingR[i] = 0
            windowedBuf[i] = 0
        }
        inputWritePos = 0

        for i in 0..<half {
            fftRealIn[i] = 0
            fftImagIn[i] = 0
            oscPhases[i] = 0
            oscFreqs[i] = 0
            oscFreqIncs[i] = 0
            oscAmpsL[i] = 0
            oscAmpsR[i] = 0
            oscAmpIncsL[i] = 0
            oscAmpIncsR[i] = 0
            sinInput[i] = 0
            sinOutput[i] = 0
        }

        for i in 0..<half {
            let pos = Float(i) / Float(half)
            binPositions[i] = pos
            binVelocities[i] = 0
        }

        hopCounter = Self.hopSize
        samplesProcessed = 0

        dcX1L = 0; dcY1L = 0
        dcX1R = 0; dcY1R = 0

        noiseStateL = 77_777
        noiseStateR = 54_321
    }
}
