import Foundation

/// Terrain effect — 3-band parametric EQ.
///
/// Parameters:
/// - `low`: Low shelf gain (0.0–1.0). 0.5 = unity, 0 = -12dB, 1 = +12dB.
/// - `mid`: Mid bell gain (0.0–1.0). Same mapping.
/// - `high`: High shelf gain (0.0–1.0). Same mapping.
///
/// Fixed crossover frequencies: low shelf 200Hz, mid bell 1kHz (Q=0.7), high shelf 4kHz.
/// Zero allocations, all state is inline.
struct TerrainEffect {
    // Target parameters (0–1, mapped to dB internally)
    private var low: Double = 0.5
    private var mid: Double = 0.5
    private var high: Double = 0.5

    // Smoothed parameters
    private var lowSmoothed: Double = 0.5
    private var midSmoothed: Double = 0.5
    private var highSmoothed: Double = 0.5

    private let smoothCoeff: Double = 0.002

    // Low shelf biquad state (2nd order)
    private var lsX1: Double = 0, lsX2: Double = 0
    private var lsY1: Double = 0, lsY2: Double = 0

    // Mid bell biquad state (2nd order)
    private var mbX1: Double = 0, mbX2: Double = 0
    private var mbY1: Double = 0, mbY2: Double = 0

    // High shelf biquad state (2nd order)
    private var hsX1: Double = 0, hsX2: Double = 0
    private var hsY1: Double = 0, hsY2: Double = 0

    // Cached coefficients (recomputed when parameters change)
    private var lsB0: Double = 1, lsB1: Double = 0, lsB2: Double = 0
    private var lsA1: Double = 0, lsA2: Double = 0

    private var mbB0: Double = 1, mbB1: Double = 0, mbB2: Double = 0
    private var mbA1: Double = 0, mbA2: Double = 0

    private var hsB0: Double = 1, hsB1: Double = 0, hsB2: Double = 0
    private var hsA1: Double = 0, hsA2: Double = 0

    // Coefficient update counter (recalculate every 64 samples to save CPU)
    private var updateCounter: Int = 0
    private var lastSampleRate: Float = 0

    /// Process a single sample through the 3-band EQ.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        lowSmoothed += (low - lowSmoothed) * smoothCoeff
        midSmoothed += (mid - midSmoothed) * smoothCoeff
        highSmoothed += (high - highSmoothed) * smoothCoeff

        // Recompute coefficients every 64 samples or on sample rate change
        updateCounter += 1
        if updateCounter >= 64 || lastSampleRate != sampleRate {
            updateCounter = 0
            lastSampleRate = sampleRate
            let sr = Double(sampleRate)

            // Map 0–1 to dB: 0.5 = 0dB, 0 = -12dB, 1 = +12dB
            let lowDB = (lowSmoothed - 0.5) * 24.0
            let midDB = (midSmoothed - 0.5) * 24.0
            let highDB = (highSmoothed - 0.5) * 24.0

            computeLowShelf(freqHz: 200.0, gainDB: lowDB, sampleRate: sr)
            computePeakingEQ(freqHz: 1000.0, gainDB: midDB, q: 0.7, sampleRate: sr)
            computeHighShelf(freqHz: 4000.0, gainDB: highDB, sampleRate: sr)
        }

        let x = Double(sample)

        // Low shelf
        var y = lsB0 * x + lsB1 * lsX1 + lsB2 * lsX2 - lsA1 * lsY1 - lsA2 * lsY2
        lsX2 = lsX1; lsX1 = x
        lsY2 = lsY1; lsY1 = y

        // Mid bell
        let x2 = y
        y = mbB0 * x2 + mbB1 * mbX1 + mbB2 * mbX2 - mbA1 * mbY1 - mbA2 * mbY2
        mbX2 = mbX1; mbX1 = x2
        mbY2 = mbY1; mbY1 = y

        // High shelf
        let x3 = y
        y = hsB0 * x3 + hsB1 * hsX1 + hsB2 * hsX2 - hsA1 * hsY1 - hsA2 * hsY2
        hsX2 = hsX1; hsX1 = x3
        hsY2 = hsY1; hsY1 = y

        return Float(y)
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let l = params["low"] { low = max(0, min(1, l)) }
        if let m = params["mid"] { mid = max(0, min(1, m)) }
        if let h = params["high"] { high = max(0, min(1, h)) }
    }

    /// Reset filter state.
    mutating func reset() {
        lsX1 = 0; lsX2 = 0; lsY1 = 0; lsY2 = 0
        mbX1 = 0; mbX2 = 0; mbY1 = 0; mbY2 = 0
        hsX1 = 0; hsX2 = 0; hsY1 = 0; hsY2 = 0
    }

    // MARK: - Biquad Coefficient Computation (Audio EQ Cookbook)

    private mutating func computeLowShelf(freqHz: Double, gainDB: Double, sampleRate: Double) {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * .pi * freqHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / 2.0 * sqrt(2.0)  // S = 1 (shelf slope)
        let sqrtA2alpha = 2.0 * sqrt(A) * alpha

        let a0 = (A + 1.0) + (A - 1.0) * cosW0 + sqrtA2alpha
        lsB0 = (A * ((A + 1.0) - (A - 1.0) * cosW0 + sqrtA2alpha)) / a0
        lsB1 = (2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)) / a0
        lsB2 = (A * ((A + 1.0) - (A - 1.0) * cosW0 - sqrtA2alpha)) / a0
        lsA1 = (-2.0 * ((A - 1.0) + (A + 1.0) * cosW0)) / a0
        lsA2 = ((A + 1.0) + (A - 1.0) * cosW0 - sqrtA2alpha) / a0
    }

    private mutating func computePeakingEQ(freqHz: Double, gainDB: Double, q: Double, sampleRate: Double) {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * .pi * freqHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)

        let a0 = 1.0 + alpha / A
        mbB0 = (1.0 + alpha * A) / a0
        mbB1 = (-2.0 * cosW0) / a0
        mbB2 = (1.0 - alpha * A) / a0
        mbA1 = (-2.0 * cosW0) / a0
        mbA2 = (1.0 - alpha / A) / a0
    }

    private mutating func computeHighShelf(freqHz: Double, gainDB: Double, sampleRate: Double) {
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * .pi * freqHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / 2.0 * sqrt(2.0)
        let sqrtA2alpha = 2.0 * sqrt(A) * alpha

        let a0 = (A + 1.0) - (A - 1.0) * cosW0 + sqrtA2alpha
        hsB0 = (A * ((A + 1.0) + (A - 1.0) * cosW0 + sqrtA2alpha)) / a0
        hsB1 = (-2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)) / a0
        hsB2 = (A * ((A + 1.0) + (A - 1.0) * cosW0 - sqrtA2alpha)) / a0
        hsA1 = (2.0 * ((A - 1.0) - (A + 1.0) * cosW0)) / a0
        hsA2 = ((A + 1.0) - (A - 1.0) * cosW0 - sqrtA2alpha) / a0
    }
}
