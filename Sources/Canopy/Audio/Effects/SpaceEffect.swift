import Foundation

/// Space effect — Freeverb (Schroeder-Moorer) reverb.
///
/// Parameters:
/// - `size`: Room size / feedback amount (0.0–1.0). 0 = small room, 1 = vast canyon.
/// - `damp`: High-frequency damping (0.0–1.0). Higher = darker reverb tail.
///
/// Architecture: 8 parallel comb filters -> 4 series allpass filters.
/// All buffers pre-allocated, zero heap ops on audio thread.
struct SpaceEffect {
    // Comb filter delays (Freeverb standard)
    private static let combDelays = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    // Allpass filter delays
    private static let allpassDelays = [556, 441, 341, 225]

    // Comb filters — using UnsafeMutablePointer arrays for audio-thread safety
    private let combBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let combIndices: UnsafeMutablePointer<Int>
    private let combFilterStore: UnsafeMutablePointer<Double>

    // Allpass filters
    private let allpassBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let allpassIndices: UnsafeMutablePointer<Int>

    // Smoothed parameters
    private var sizeSmoothed: Double = 0.5
    private var dampSmoothed: Double = 0.5

    // Target parameters
    private var size: Double = 0.5
    private var damp: Double = 0.5

    private let smoothCoeff: Double = 0.001

    init() {
        // Allocate comb filter storage
        let combCount = Self.combDelays.count
        combBuffers = .allocate(capacity: combCount)
        combIndices = .allocate(capacity: combCount)
        combFilterStore = .allocate(capacity: combCount)

        for i in 0..<combCount {
            let delay = Self.combDelays[i]
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: delay)
            buf.initialize(repeating: 0, count: delay)
            combBuffers[i] = buf
            combIndices[i] = 0
            combFilterStore[i] = 0
        }

        // Allocate allpass filter storage
        let allpassCount = Self.allpassDelays.count
        allpassBuffers = .allocate(capacity: allpassCount)
        allpassIndices = .allocate(capacity: allpassCount)

        for i in 0..<allpassCount {
            let delay = Self.allpassDelays[i]
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: delay)
            buf.initialize(repeating: 0, count: delay)
            allpassBuffers[i] = buf
            allpassIndices[i] = 0
        }
    }

    /// Process a single sample.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        // Smooth parameters
        sizeSmoothed += (size - sizeSmoothed) * smoothCoeff
        dampSmoothed += (damp - dampSmoothed) * smoothCoeff

        // Freeverb parameters
        let feedback = Float(0.7 + sizeSmoothed * 0.28)  // 0.7–0.98
        let dampCoeff = Float(dampSmoothed * 0.4)

        // Sum 8 parallel comb filters
        var combSum: Float = 0
        for i in 0..<8 {
            combSum += processComb(input: sample, index: i, feedback: feedback, damp: dampCoeff)
        }

        // Scale comb output
        var output = combSum * 0.125  // Average of 8 combs

        // 4 series allpass filters
        for i in 0..<4 {
            output = processAllpass(input: output, index: i)
        }

        return output
    }

    // MARK: - Comb filter

    private mutating func processComb(input: Float, index: Int, feedback: Float, damp: Float) -> Float {
        let delay = Self.combDelays[index]
        let buf = combBuffers[index]
        let idx = combIndices[index]

        let delayed = buf[idx]

        // Damped feedback: one-pole lowpass
        let store = combFilterStore[index]
        let dampD = Double(damp)
        let filtered = Double(delayed) * (1.0 - dampD) + store * dampD
        combFilterStore[index] = filtered

        buf[idx] = input + Float(filtered) * feedback

        combIndices[index] = (idx + 1) % delay
        return delayed
    }

    // MARK: - Allpass filter

    private mutating func processAllpass(input: Float, index: Int) -> Float {
        let delay = Self.allpassDelays[index]
        let buf = allpassBuffers[index]
        let idx = allpassIndices[index]

        let delayed = buf[idx]
        let allpassFeedback: Float = 0.5
        let output = -input + delayed
        buf[idx] = input + delayed * allpassFeedback

        allpassIndices[index] = (idx + 1) % delay
        return output
    }

    /// Update parameters from dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        if let s = params["size"] { size = max(0, min(1, s)) }
        if let d = params["damp"] { damp = max(0, min(1, d)) }
    }

    /// Reset all buffers and state.
    mutating func reset() {
        for i in 0..<Self.combDelays.count {
            let delay = Self.combDelays[i]
            for j in 0..<delay { combBuffers[i][j] = 0 }
            combIndices[i] = 0
            combFilterStore[i] = 0
        }
        for i in 0..<Self.allpassDelays.count {
            let delay = Self.allpassDelays[i]
            for j in 0..<delay { allpassBuffers[i][j] = 0 }
            allpassIndices[i] = 0
        }
    }
}
