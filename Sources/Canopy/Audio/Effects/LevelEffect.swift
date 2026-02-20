import Foundation

/// Level effect — gain staging utility for volume control.
///
/// Parameters:
/// - `amount`: Gain level (0.0–1.0). 0.0 = silence, 0.5 = unity (0dB), 1.0 = +12dB.
///
/// Mapping: `dB = (amount - 0.5) * 24.0` → `gain = pow(10, dB/20)`
/// Uses parameter smoothing to avoid clicks on adjustment.
struct LevelEffect {
    // Smoothed gain (linear)
    private var gainSmooth: Double = 1.0

    // Target gain (linear)
    private var gainTarget: Double = 1.0

    private let smoothCoeff: Double = 0.001

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth toward target
        gainSmooth += (gainTarget - gainSmooth) * smoothCoeff

        // Hard zero below threshold to avoid denormals
        if gainSmooth < 0.001 {
            return 0
        }

        return sample * Float(gainSmooth)
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let amount = params["amount"] {
            let clamped = max(0, min(1, amount))
            // Below threshold → silence
            if clamped < 0.001 {
                gainTarget = 0
            } else {
                let dB = (clamped - 0.5) * 24.0
                gainTarget = pow(10.0, dB / 20.0)
            }
        }
    }

    /// Reset state.
    mutating func reset() {
        gainSmooth = gainTarget
    }
}
