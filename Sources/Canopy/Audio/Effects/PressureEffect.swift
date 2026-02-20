import Foundation

/// Pressure effect — feed-forward compressor with RMS level detection.
///
/// Parameters:
/// - `weight`: Threshold (0.0–1.0). 0 = compress everything, 1 = only loud peaks.
/// - `squeeze`: Ratio amount (0.0–1.0). 0 = 1:1 (no compression), 1 = infinity:1 (limiting).
/// - `speed`: Release time (0.0–1.0). 0 = fast release, 1 = slow release.
struct PressureEffect {
    // RMS envelope
    private var rmsEnvelope: Double = 0

    // Gain reduction (smoothed)
    private var gainSmoothed: Double = 1.0

    // Smoothed parameters
    private var weightSmoothed: Double = 0.5
    private var squeezeSmoothed: Double = 0.3
    private var speedSmoothed: Double = 0.5

    // Target parameters
    private var weight: Double = 0.5
    private var squeeze: Double = 0.3
    private var speed: Double = 0.5

    private let smoothCoeff: Double = 0.002

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        weightSmoothed += (weight - weightSmoothed) * smoothCoeff
        squeezeSmoothed += (squeeze - squeezeSmoothed) * smoothCoeff
        speedSmoothed += (speed - speedSmoothed) * smoothCoeff

        let x = Double(sample)

        // RMS envelope follower (exponential moving average of squared signal)
        let attackMs: Double = 5.0
        let releaseMs = 50.0 + speedSmoothed * 450.0  // 50ms–500ms
        let attackCoeff = 1.0 - exp(-1.0 / (attackMs / 1000.0 * Double(sampleRate)))
        let releaseCoeff = 1.0 - exp(-1.0 / (releaseMs / 1000.0 * Double(sampleRate)))

        let squared = x * x
        let coeff = squared > rmsEnvelope ? attackCoeff : releaseCoeff
        rmsEnvelope += (squared - rmsEnvelope) * coeff
        let rmsLevel = sqrt(max(0, rmsEnvelope))

        // Threshold: map weight (0–1) to threshold in linear (0.01–1.0)
        let threshold = 0.01 + weightSmoothed * 0.99

        // Compute gain reduction
        let desiredGain: Double
        if rmsLevel > threshold {
            // Ratio: map squeeze (0–1) to ratio (1:1 → infinity:1)
            // At squeeze=0: ratio=1 (no compression)
            // At squeeze=1: ratio=infinity (hard limiting)
            let ratio = 1.0 / (1.0 - squeezeSmoothed * 0.99)
            let overDB = 20.0 * log10(rmsLevel / threshold)
            let compressedOverDB = overDB / ratio
            desiredGain = pow(10.0, (compressedOverDB - overDB) / 20.0)
        } else {
            desiredGain = 1.0
        }

        // Smooth gain application
        let gainCoeff = desiredGain < gainSmoothed ? attackCoeff : releaseCoeff
        gainSmoothed += (desiredGain - gainSmoothed) * gainCoeff

        // Apply makeup gain (compensate for average gain reduction)
        let makeupGain = 1.0 + squeezeSmoothed * 0.5
        return Float(x * gainSmoothed * makeupGain)
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let w = params["weight"] { weight = max(0, min(1, w)) }
        if let s = params["squeeze"] { squeeze = max(0, min(1, s)) }
        if let sp = params["speed"] { speed = max(0, min(1, sp)) }
    }

    /// Reset state.
    mutating func reset() {
        rmsEnvelope = 0
        gainSmoothed = 1.0
    }
}
