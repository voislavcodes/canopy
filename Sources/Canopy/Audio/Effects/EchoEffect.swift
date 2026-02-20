import Foundation

/// Echo effect — delay line with feedback and diffusion.
///
/// Parameters:
/// - `distance`: Delay time (0.0–1.0, maps to 10ms–1000ms)
/// - `decay`: Feedback amount (0.0–1.0)
/// - `diffuse`: Lowpass in feedback path (0.0–1.0). Higher = darker echoes.
///
/// Uses a pre-allocated circular buffer (48000 samples = 1s at 48kHz).
/// Feedback is bounded by tanh to prevent runaway.
struct EchoEffect {
    /// Delay buffer — pre-allocated, never resized.
    private let buffer: UnsafeMutablePointer<Float>
    private let bufferSize: Int
    private var writeIndex: Int = 0

    // Smoothed parameters
    private var distanceSmoothed: Double = 0.3
    private var decaySmoothed: Double = 0.4

    // Target parameters
    private var distance: Double = 0.3
    private var decay: Double = 0.4
    private var diffuse: Double = 0.3

    // Feedback lowpass state
    private var feedbackLP: Double = 0

    private let smoothCoeff: Double = 0.0005  // Slow smoothing for delay time

    init() {
        // 1 second at 48kHz
        bufferSize = 48000
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        distanceSmoothed += (distance - distanceSmoothed) * smoothCoeff
        decaySmoothed += (decay - decaySmoothed) * smoothCoeff

        // Map distance (0–1) to delay time in samples (10ms–1000ms)
        let delayMs = 10.0 + distanceSmoothed * 990.0
        let delaySamples = delayMs / 1000.0 * Double(sampleRate)

        // Read from delay line with linear interpolation (smooth delay time changes)
        let readPos = Double(writeIndex) - delaySamples
        let readPosWrapped = readPos < 0 ? readPos + Double(bufferSize) : readPos
        let index0 = Int(readPosWrapped) % bufferSize
        let index1 = (index0 + 1) % bufferSize
        let frac = Float(readPosWrapped - Double(Int(readPosWrapped)))

        let delayed = buffer[index0] * (1.0 - frac) + buffer[index1] * frac

        // Feedback path with diffusion (lowpass) and tanh bounding
        let feedbackGain = decaySmoothed * 0.95  // Cap at 0.95 to prevent runaway
        let feedbackRaw = Double(delayed) * feedbackGain

        // Diffusion: one-pole lowpass in feedback (makes each echo darker)
        let diffuseCoeff = 1.0 - diffuse * 0.9  // diffuse=0 → no filtering, diffuse=1 → heavy LP
        let cutoffHz = 200.0 + diffuseCoeff * 18000.0
        let g = 1.0 - exp(-2.0 * .pi * cutoffHz / Double(sampleRate))
        feedbackLP += (feedbackRaw - feedbackLP) * g

        // Bound feedback with tanh
        let boundedFeedback = Float(tanh(feedbackLP))

        // Write input + feedback into buffer
        buffer[writeIndex] = sample + boundedFeedback

        // Advance write index
        writeIndex += 1
        if writeIndex >= bufferSize {
            writeIndex = 0
        }

        return delayed
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let d = params["distance"] { distance = max(0, min(1, d)) }
        if let dc = params["decay"] { decay = max(0, min(1, dc)) }
        if let df = params["diffuse"] { diffuse = max(0, min(1, df)) }
    }

    /// Reset state.
    mutating func reset() {
        for i in 0..<bufferSize {
            buffer[i] = 0
        }
        writeIndex = 0
        feedbackLP = 0
    }
}
