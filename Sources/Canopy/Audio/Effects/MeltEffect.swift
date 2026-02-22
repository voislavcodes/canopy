import Foundation
import Accelerate

/// MELT — Spectral Gravity Effect.
///
/// Frequencies have mass. Gravity pulls them down. Each FFT bin has a position,
/// velocity, and experiences Newtonian forces: gravity (down), viscosity (drag),
/// floor (hard stop), heat (up + turbulence). The spectrum is a physical system.
///
/// True stereo: shared physics engine (both channels' bins fall at same rate),
/// independent magnitude buffers per channel, independent heat turbulence noise.
///
/// Parameters:
/// - `gravity`: Downward force strength (0.0–1.0). 0 = zero-G, 1 = singularity.
/// - `viscosity`: Resistance to falling (0.0–1.0). 0 = vacuum, 1 = tar.
/// - `floor`: Lowest frequency bins can fall to (0.0–1.0). 0 = sub-bass, 1 = treble.
/// - `heat`: Upward restoring force + turbulence (0.0–1.0). 0 = cold, 1 = plasma.
struct MeltEffect {

    // MARK: - FFT Constants

    private static let fftSize = 2048
    private static let halfFFT = 1024       // numBins
    private static let hopSize = 512        // 75% overlap
    private static let overlapFactor = 4    // fftSize / hopSize
    /// vDSP log2 of fftSize
    private static let log2n: vDSP_Length = 11  // log2(2048)

    // MARK: - FFT Setup (persistent, never deallocated during lifetime)

    private let fftSetup: FFTSetup

    // MARK: - Input Ring Buffers (stereo)

    private let inputRingL: UnsafeMutablePointer<Float>
    private let inputRingR: UnsafeMutablePointer<Float>
    private var inputWritePos: Int = 0

    // MARK: - Output Overlap-Add Buffers (stereo)
    // Double the FFT size for overlap-add headroom

    private static let overlapBufSize = fftSize * 2
    private let overlapBufL: UnsafeMutablePointer<Float>
    private let overlapBufR: UnsafeMutablePointer<Float>
    private var overlapWritePos: Int = 0
    private var overlapReadPos: Int = 0

    // MARK: - FFT Working Buffers

    private let windowedBuf: UnsafeMutablePointer<Float>
    private let fftRealIn: UnsafeMutablePointer<Float>
    private let fftImagIn: UnsafeMutablePointer<Float>
    private let fftRealOut: UnsafeMutablePointer<Float>
    private let fftImagOut: UnsafeMutablePointer<Float>
    private let ifftOutput: UnsafeMutablePointer<Float>

    // MARK: - Spectral Data Buffers

    private let magnitudesL: UnsafeMutablePointer<Float>
    private let magnitudesR: UnsafeMutablePointer<Float>
    private let phases: UnsafeMutablePointer<Float>
    private let displacedMagsL: UnsafeMutablePointer<Float>
    private let displacedMagsR: UnsafeMutablePointer<Float>
    private let outputPhases: UnsafeMutablePointer<Float>

    // MARK: - Physics State (shared across L/R)

    private let binPositions: UnsafeMutablePointer<Float>
    private let binVelocities: UnsafeMutablePointer<Float>
    private let naturalPositions: UnsafeMutablePointer<Float>

    // MARK: - Pre-computed Window

    private let hannWindow: UnsafeMutablePointer<Float>

    // MARK: - Hop Counter

    private var hopCounter: Int
    private var samplesProcessed: Int = 0

    // MARK: - DC Blockers (stereo)

    private var dcX1L: Float = 0
    private var dcY1L: Float = 0
    private var dcX1R: Float = 0
    private var dcY1R: Float = 0

    // MARK: - Noise State (per-channel for independent turbulence)

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
        // Create FFT setup
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!

        let fft = Self.fftSize
        let half = Self.halfFFT
        let ovBuf = Self.overlapBufSize

        // Input ring buffers
        inputRingL = .allocate(capacity: fft)
        inputRingL.initialize(repeating: 0, count: fft)
        inputRingR = .allocate(capacity: fft)
        inputRingR.initialize(repeating: 0, count: fft)

        // Output overlap-add buffers
        overlapBufL = .allocate(capacity: ovBuf)
        overlapBufL.initialize(repeating: 0, count: ovBuf)
        overlapBufR = .allocate(capacity: ovBuf)
        overlapBufR.initialize(repeating: 0, count: ovBuf)

        // FFT working buffers
        windowedBuf = .allocate(capacity: fft)
        windowedBuf.initialize(repeating: 0, count: fft)
        fftRealIn = .allocate(capacity: half)
        fftRealIn.initialize(repeating: 0, count: half)
        fftImagIn = .allocate(capacity: half)
        fftImagIn.initialize(repeating: 0, count: half)
        fftRealOut = .allocate(capacity: half)
        fftRealOut.initialize(repeating: 0, count: half)
        fftImagOut = .allocate(capacity: half)
        fftImagOut.initialize(repeating: 0, count: half)
        ifftOutput = .allocate(capacity: fft)
        ifftOutput.initialize(repeating: 0, count: fft)

        // Spectral data
        magnitudesL = .allocate(capacity: half)
        magnitudesL.initialize(repeating: 0, count: half)
        magnitudesR = .allocate(capacity: half)
        magnitudesR.initialize(repeating: 0, count: half)
        phases = .allocate(capacity: half)
        phases.initialize(repeating: 0, count: half)
        displacedMagsL = .allocate(capacity: half)
        displacedMagsL.initialize(repeating: 0, count: half)
        displacedMagsR = .allocate(capacity: half)
        displacedMagsR.initialize(repeating: 0, count: half)
        outputPhases = .allocate(capacity: half)
        outputPhases.initialize(repeating: 0, count: half)

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

        // Pre-compute Hann window
        hannWindow = .allocate(capacity: fft)
        for i in 0..<fft {
            hannWindow[i] = 0.5 * (1.0 - cos(2.0 * .pi * Float(i) / Float(fft)))
        }

        // Start with full hop to fill initial buffer
        hopCounter = Self.hopSize
    }

    // MARK: - Mono Processing

    mutating func process(sample: Float, sampleRate: Float) -> Float {
        let (outL, _) = processStereo(sampleL: sample, sampleR: sample, sampleRate: sampleRate)
        return outL
    }

    // MARK: - True Stereo Processing

    mutating func processStereo(sampleL: Float, sampleR: Float, sampleRate: Float) -> (Float, Float) {
        // Smooth parameters per-sample
        gravitySmooth += (gravity - gravitySmooth) * paramSmoothCoeff
        viscositySmooth += (viscosity - viscositySmooth) * paramSmoothCoeff
        floorSmooth += (floor_ - floorSmooth) * paramSmoothCoeff
        heatSmooth += (heat - heatSmooth) * paramSmoothCoeff

        // Push samples to input ring buffers
        inputRingL[inputWritePos] = sampleL
        inputRingR[inputWritePos] = sampleR
        inputWritePos = (inputWritePos + 1) % Self.fftSize

        // Decrement hop counter
        hopCounter -= 1
        if hopCounter <= 0 {
            hopCounter = Self.hopSize
            processHop(sampleRate: sampleRate)
        }

        // Read from overlap-add output buffers
        var outL = overlapBufL[overlapReadPos]
        var outR = overlapBufR[overlapReadPos]

        // Clear the read position for next overlap cycle
        overlapBufL[overlapReadPos] = 0
        overlapBufR[overlapReadPos] = 0
        overlapReadPos = (overlapReadPos + 1) % Self.overlapBufSize

        // Silence during initial latency fill
        samplesProcessed += 1
        if samplesProcessed < Self.fftSize {
            return (0, 0)
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
        let fft = Self.fftSize
        let half = Self.halfFFT
        let hop = Self.hopSize

        // ── 1. Advance physics (shared across L/R) ──
        let dt = Float(hop) / sampleRate
        advancePhysics(dt: dt)

        // ── 2. Analyze L channel ──
        analyzeChannel(inputRing: inputRingL, magnitudes: magnitudesL, sampleRate: sampleRate)

        // ── 3. Displace L spectrum ──
        displaceSpectrum(inputMags: magnitudesL, outputMags: displacedMagsL)

        // ── 4. Energy normalization for L ──
        normalizeEnergy(inputMags: magnitudesL, outputMags: displacedMagsL)

        // ── 5. Advance output phases ──
        advanceOutputPhases(sampleRate: sampleRate)

        // ── 6. Resynthesize L ──
        resynthesize(displacedMags: displacedMagsL, overlapBuf: overlapBufL, sampleRate: sampleRate)

        // ── 7. Analyze R channel ──
        analyzeChannel(inputRing: inputRingR, magnitudes: magnitudesR, sampleRate: sampleRate)

        // ── 8. Displace R spectrum ──
        displaceSpectrum(inputMags: magnitudesR, outputMags: displacedMagsR)

        // ── 9. Energy normalization for R ──
        normalizeEnergy(inputMags: magnitudesR, outputMags: displacedMagsR)

        // ── 10. Resynthesize R (reuse same output phases — shared physics) ──
        resynthesize(displacedMags: displacedMagsR, overlapBuf: overlapBufR, sampleRate: sampleRate)
    }

    // MARK: - FFT Analysis

    private mutating func analyzeChannel(inputRing: UnsafeMutablePointer<Float>,
                                         magnitudes: UnsafeMutablePointer<Float>,
                                         sampleRate: Float) {
        let fft = Self.fftSize
        let half = Self.halfFFT

        // Copy from ring buffer with windowing
        for i in 0..<fft {
            let ringIdx = (inputWritePos - fft + i + fft) % fft
            windowedBuf[i] = inputRing[ringIdx] * hannWindow[i]
        }

        // Perform forward FFT using vDSP
        // Pack into split complex format
        var splitReal = fftRealIn
        var splitImag = fftImagIn
        windowedBuf.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
            var split = DSPSplitComplex(realp: splitReal, imagp: splitImag)
            vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
        }

        var splitComplex = DSPSplitComplex(realp: fftRealIn, imagp: fftImagIn)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))

        // Scale by 1/2 (vDSP convention)
        var scale: Float = 0.5
        vDSP_vsmul(fftRealIn, 1, &scale, fftRealIn, 1, vDSP_Length(half))
        vDSP_vsmul(fftImagIn, 1, &scale, fftImagIn, 1, vDSP_Length(half))

        // Extract magnitudes and phases
        for bin in 0..<half {
            let re = fftRealIn[bin]
            let im = fftImagIn[bin]
            magnitudes[bin] = sqrtf(re * re + im * im)
            phases[bin] = atan2f(im, re)
        }
    }

    // MARK: - Physics Engine

    private mutating func advancePhysics(dt: Float) {
        let half = Self.halfFFT
        let gravityForce = gravitySmooth * 2.0
        let viscCoeff = 0.01 + viscositySmooth * 0.99
        let floorPos = floorSmooth
        let heatForce = heatSmooth * 2.0

        for bin in 0..<half {
            let naturalPos = naturalPositions[bin]
            let currentPos = binPositions[bin]

            // Force 1: Gravity (downward — toward position 0.0)
            let heightAboveFloor = max(0, currentPos - floorPos)
            let gForce = -gravityForce * heightAboveFloor

            // Force 2: Viscosity (opposes motion)
            let viscForce = -binVelocities[bin] * viscCoeff * 10.0

            // Force 3: Floor collision (spring repulsion)
            var floorForce: Float = 0
            if currentPos < floorPos + 0.01 {
                let penetration = floorPos + 0.01 - currentPos
                floorForce = penetration * 50.0
            }

            // Force 4: Heat restoring (push toward natural position)
            let displacement = naturalPos - currentPos
            let hForce = heatForce * displacement

            // Force 5: Heat turbulence (random upward kicks) — use shared noise
            var turbulence: Float = 0
            if heatSmooth > 0.1 {
                noiseStateL = noiseStateL &* 1_664_525 &+ 1_013_904_223
                let rand01 = Float(noiseStateL) / Float(UInt32.max)
                turbulence = (rand01 - 0.3) * heatSmooth * 0.5
            }

            // Semi-implicit Euler integration
            let totalForce = gForce + viscForce + floorForce + hForce + turbulence
            binVelocities[bin] += totalForce * dt
            binVelocities[bin] = max(-2.0, min(2.0, binVelocities[bin]))
            binPositions[bin] += binVelocities[bin] * dt
            binPositions[bin] = max(0.0, min(1.0, binPositions[bin]))
        }
    }

    // MARK: - Spectral Displacement

    private func displaceSpectrum(inputMags: UnsafeMutablePointer<Float>,
                                  outputMags: UnsafeMutablePointer<Float>) {
        let half = Self.halfFFT

        // Clear output
        for bin in 0..<half {
            outputMags[bin] = 0
        }

        // Place each bin's energy at its displaced position
        for sourceBin in 0..<half {
            let energy = inputMags[sourceBin]
            if energy < 1e-8 { continue }

            let targetPos = binPositions[sourceBin] * Float(half)
            let targetBin = Int(targetPos)
            let frac = targetPos - Float(targetBin)

            if targetBin >= 0 && targetBin < half {
                outputMags[targetBin] += energy * (1.0 - frac)
            }
            if targetBin + 1 >= 0 && targetBin + 1 < half {
                outputMags[targetBin + 1] += energy * frac
            }
        }
    }

    // MARK: - Energy Normalization

    private func normalizeEnergy(inputMags: UnsafeMutablePointer<Float>,
                                 outputMags: UnsafeMutablePointer<Float>) {
        let half = Self.halfFFT

        var inputEnergy: Float = 0
        var outputEnergy: Float = 0
        for bin in 0..<half {
            inputEnergy += inputMags[bin] * inputMags[bin]
            outputEnergy += outputMags[bin] * outputMags[bin]
        }

        // Normalize output to match input energy, capped at 4x to prevent extreme gain
        let normFactor: Float
        if outputEnergy > 1e-10 {
            normFactor = min(4.0, sqrtf(max(inputEnergy, 1e-10) / outputEnergy))
        } else {
            normFactor = 1.0
        }

        for bin in 0..<half {
            outputMags[bin] *= normFactor
        }
    }

    // MARK: - Phase Management

    private mutating func advanceOutputPhases(sampleRate: Float) {
        let half = Self.halfFFT
        let hop = Self.hopSize

        for bin in 0..<half {
            let targetFreq = Float(bin) * sampleRate / Float(Self.fftSize)
            let phaseIncrement = 2.0 * .pi * targetFreq * Float(hop) / sampleRate
            outputPhases[bin] += phaseIncrement
            // Wrap phase to [-pi, pi]
            while outputPhases[bin] > .pi { outputPhases[bin] -= 2.0 * .pi }
            while outputPhases[bin] < -.pi { outputPhases[bin] += 2.0 * .pi }
        }
    }

    // MARK: - IFFT Resynthesis + Overlap-Add

    private mutating func resynthesize(displacedMags: UnsafeMutablePointer<Float>,
                                       overlapBuf: UnsafeMutablePointer<Float>,
                                       sampleRate: Float) {
        let fft = Self.fftSize
        let half = Self.halfFFT
        let hop = Self.hopSize

        // Build spectrum from displaced magnitudes + managed phases
        for bin in 0..<half {
            fftRealOut[bin] = displacedMags[bin] * cosf(outputPhases[bin])
            fftImagOut[bin] = displacedMags[bin] * sinf(outputPhases[bin])
        }

        // Perform inverse FFT
        var splitComplex = DSPSplitComplex(realp: fftRealOut, imagp: fftImagOut)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, Self.log2n, FFTDirection(kFFTDirection_Inverse))

        // Scale by 1/(2*fftSize) (vDSP convention for inverse)
        var scale: Float = 1.0 / Float(2 * fft)
        vDSP_vsmul(fftRealOut, 1, &scale, fftRealOut, 1, vDSP_Length(half))
        vDSP_vsmul(fftImagOut, 1, &scale, fftImagOut, 1, vDSP_Length(half))

        // Unpack from split complex to interleaved time-domain
        var split = DSPSplitComplex(realp: fftRealOut, imagp: fftImagOut)
        ifftOutput.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
            vDSP_ztoc(&split, 1, complexPtr, 2, vDSP_Length(half))
        }

        // Apply synthesis Hann window and accumulate into overlap-add buffer
        // Normalization: with 75% overlap and Hann window, COLA gain = hopSize/fftSize * 2
        let overlapNorm: Float = 2.0 / Float(Self.overlapFactor)
        let ovBufSize = Self.overlapBufSize

        for i in 0..<fft {
            let windowed = ifftOutput[i] * hannWindow[i] * overlapNorm
            let writeIdx = (overlapWritePos + i) % ovBufSize
            overlapBuf[writeIdx] += windowed
        }

        // Advance overlap write position by hop
        overlapWritePos = (overlapWritePos + hop) % ovBufSize
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

        // Snap smoothed to targets on fresh creation
        gravitySmooth = gravity
        viscositySmooth = viscosity
        floorSmooth = floor_
        heatSmooth = heat
    }

    // MARK: - Reset

    mutating func reset() {
        let fft = Self.fftSize
        let half = Self.halfFFT
        let ovBuf = Self.overlapBufSize

        // Clear input ring buffers
        for i in 0..<fft {
            inputRingL[i] = 0
            inputRingR[i] = 0
        }
        inputWritePos = 0

        // Clear overlap-add buffers
        for i in 0..<ovBuf {
            overlapBufL[i] = 0
            overlapBufR[i] = 0
        }
        overlapWritePos = 0
        overlapReadPos = 0

        // Clear FFT working buffers
        for i in 0..<fft {
            windowedBuf[i] = 0
            ifftOutput[i] = 0
        }
        for i in 0..<half {
            fftRealIn[i] = 0
            fftImagIn[i] = 0
            fftRealOut[i] = 0
            fftImagOut[i] = 0
            magnitudesL[i] = 0
            magnitudesR[i] = 0
            phases[i] = 0
            displacedMagsL[i] = 0
            displacedMagsR[i] = 0
            outputPhases[i] = 0
        }

        // Reset physics state
        for i in 0..<half {
            let pos = Float(i) / Float(half)
            binPositions[i] = pos
            binVelocities[i] = 0
        }

        // Reset counters
        hopCounter = Self.hopSize
        samplesProcessed = 0

        // Reset DC blockers
        dcX1L = 0; dcY1L = 0
        dcX1R = 0; dcY1R = 0

        // Reset noise state
        noiseStateL = 77_777
        noiseStateR = 54_321
    }
}
