import Foundation

/// Color effect — resonant filter wrapping the existing MoogLadderFilter.
///
/// Parameters:
/// - `hue`: Cutoff frequency mapped exponentially 20Hz–20kHz (0.0–1.0)
/// - `resonance`: Filter resonance (0.0–1.0)
/// - `type`: Filter type (0=lowpass, 1=highpass, 2=bandpass)
///
/// Lowpass mode uses the 4-pole Moog ladder. Highpass and bandpass use
/// a 2-pole state-variable filter for cleaner response.
struct ColorEffect {
    // Moog ladder for lowpass mode
    private var moog = MoogLadderFilter()

    // State-variable filter state for HP/BP modes
    private var svfLow: Double = 0
    private var svfBand: Double = 0

    // Smoothed parameters
    private var hueSmoothed: Double = 0.7
    private var resonanceSmoothed: Double = 0.0

    // Target parameters
    private var hue: Double = 0.7
    private var resonance: Double = 0.0
    private var filterType: Int = 0  // 0=LP, 1=HP, 2=BP

    // Smoothing coefficient
    private let smoothCoeff: Double = 0.002

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        hueSmoothed += (hue - hueSmoothed) * smoothCoeff
        resonanceSmoothed += (resonance - resonanceSmoothed) * smoothCoeff

        // Map hue (0–1) to cutoff frequency (20Hz–20kHz) exponentially
        let cutoffHz = 20.0 * pow(1000.0, hueSmoothed)

        switch filterType {
        case 0: // Lowpass — Moog ladder
            moog.enabled = true
            moog.cutoffHz = cutoffHz
            moog.resonance = resonanceSmoothed
            moog.updateCoefficients(sampleRate: Double(sampleRate))
            return moog.process(sample)

        case 1: // Highpass — state variable filter
            let f = 2.0 * sin(.pi * min(cutoffHz, Double(sampleRate) * 0.45) / Double(sampleRate))
            let q = 1.0 - resonanceSmoothed * 0.95
            let x = Double(sample)

            let high = x - svfLow - q * svfBand
            svfBand += f * high
            svfLow += f * svfBand

            return Float(max(-2.0, min(2.0, high)))

        case 2: // Bandpass — state variable filter
            let f = 2.0 * sin(.pi * min(cutoffHz, Double(sampleRate) * 0.45) / Double(sampleRate))
            let q = 1.0 - resonanceSmoothed * 0.95
            let x = Double(sample)

            let high = x - svfLow - q * svfBand
            svfBand += f * high
            svfLow += f * svfBand

            return Float(max(-2.0, min(2.0, svfBand)))

        default:
            return sample
        }
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let h = params["hue"] { hue = max(0, min(1, h)) }
        if let r = params["resonance"] { resonance = max(0, min(1, r)) }
        if let t = params["type"] { filterType = Int(t) }
    }

    /// Reset filter state.
    mutating func reset() {
        moog.reset()
        svfLow = 0
        svfBand = 0
    }
}
