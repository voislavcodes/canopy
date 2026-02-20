import Foundation

/// Heat effect — saturation/distortion via tanh waveshaping.
///
/// Parameters:
/// - `temperature`: Drive amount (0.0–1.0). 0 = transparent, 1 = heavy distortion.
/// - `tone`: Post-distortion lowpass (0.0–1.0). 0 = dark, 1 = bright.
///
/// At temperature=0, drive=1.0 and tanh(x)~x for small signals = transparent passthrough.
struct HeatEffect {
    // Smoothed parameters
    private var tempSmoothed: Double = 0.3
    private var toneSmoothed: Double = 0.7

    // Target parameters
    private var temperature: Double = 0.3
    private var tone: Double = 0.7

    // One-pole lowpass state for tone control
    private var lpState: Double = 0

    private let smoothCoeff: Double = 0.002

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        tempSmoothed += (temperature - tempSmoothed) * smoothCoeff
        toneSmoothed += (tone - toneSmoothed) * smoothCoeff

        // Drive = 1.0 + temperature * 10.0
        // At temp=0: drive=1.0, tanh(x*1)~x for small x = transparent
        // At temp=1: drive=11.0, heavy saturation
        let drive = 1.0 + tempSmoothed * 10.0
        let x = Double(sample)

        // Waveshape
        let shaped = tanh(x * drive)

        // Post-distortion one-pole lowpass (tone control)
        // tone=1 → cutoff near Nyquist (bright), tone=0 → cutoff ~200Hz (dark)
        let cutoffHz = 200.0 + toneSmoothed * (Double(sampleRate) * 0.45 - 200.0)
        let g = 1.0 - exp(-2.0 * .pi * cutoffHz / Double(sampleRate))
        lpState += (shaped - lpState) * g

        // Compensate for volume increase from drive
        let compensation = 1.0 / max(1.0, sqrt(drive))
        return Float(lpState * compensation)
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let t = params["temperature"] { temperature = max(0, min(1, t)) }
        if let tn = params["tone"] { tone = max(0, min(1, tn)) }
    }

    /// Reset state.
    mutating func reset() {
        lpState = 0
    }
}
