import Foundation

/// Brick-wall lookahead limiter — the final stage of the master bus.
///
/// Named "Shore" in Canopy's vocabulary: the hard boundary where sound meets silence.
/// Uses a 48-sample (1ms at 48kHz) lookahead buffer to anticipate peaks and reduce
/// gain before they arrive, producing transparent limiting with zero overshoot.
///
/// - Instant attack (1 sample)
/// - 100ms release (smooth gain recovery, no pumping)
/// - Ceiling: 0.97 linear (~-0.3 dBFS)
///
/// Stereo usage: create two instances (one per channel) sharing the same gain envelope,
/// or use `StereoShore` which links gain across L/R.
struct Shore {
    /// Lookahead buffer — circular, pre-allocated, never resized.
    private let buffer: UnsafeMutablePointer<Float>
    private let bufferSize: Int
    private var writeIndex: Int = 0

    /// Current gain reduction (1.0 = no reduction, <1.0 = limiting).
    private var gainReduction: Float = 1.0

    /// Peak envelope follower.
    private var peakEnvelope: Float = 0.0

    /// Release coefficient (per-sample).
    private let releaseCoeff: Float

    /// Hard ceiling in linear amplitude.
    var ceiling: Float

    /// Whether the limiter is active.
    var enabled: Bool = true

    /// Create a Shore limiter.
    /// - Parameters:
    ///   - lookaheadSamples: Size of lookahead buffer (48 = ~1ms at 48kHz)
    ///   - releaseMs: Release time in milliseconds
    ///   - ceiling: Maximum output amplitude (linear)
    ///   - sampleRate: Audio sample rate
    init(lookaheadSamples: Int = 48, releaseMs: Float = 100.0, ceiling: Float = 0.97, sampleRate: Float = 48000.0) {
        self.bufferSize = lookaheadSamples
        self.buffer = .allocate(capacity: lookaheadSamples)
        self.buffer.initialize(repeating: 0, count: lookaheadSamples)
        self.ceiling = ceiling
        // Release: exponential decay coefficient
        // Time constant = releaseMs / 1000 * sampleRate samples
        let releaseSamples = releaseMs / 1000.0 * sampleRate
        self.releaseCoeff = 1.0 - expf(-1.0 / releaseSamples)
    }

    /// Process a single sample through the lookahead limiter.
    ///
    /// The input is written into the lookahead buffer, and the delayed sample
    /// (from `lookaheadSamples` ago) is output with gain reduction applied.
    /// The gain envelope looks ahead to anticipate peaks.
    mutating func process(sample: Float) -> Float {
        guard enabled else { return sample }

        let absSample = abs(sample)

        // Update peak envelope: instant attack, smooth release
        if absSample > peakEnvelope {
            peakEnvelope = absSample
        } else {
            peakEnvelope += (absSample - peakEnvelope) * releaseCoeff
        }

        // Calculate desired gain to keep output under ceiling
        let desiredGain: Float
        if peakEnvelope > ceiling {
            desiredGain = ceiling / peakEnvelope
        } else {
            desiredGain = 1.0
        }

        // Smooth gain reduction: instant attack, smooth release
        if desiredGain < gainReduction {
            gainReduction = desiredGain  // Instant attack
        } else {
            gainReduction += (desiredGain - gainReduction) * releaseCoeff
        }

        // Read delayed sample from buffer
        let delayedSample = buffer[writeIndex]

        // Write current sample into buffer
        buffer[writeIndex] = sample

        // Advance write index (circular)
        writeIndex += 1
        if writeIndex >= bufferSize {
            writeIndex = 0
        }

        // Apply gain reduction to the delayed sample
        return delayedSample * gainReduction
    }

    /// Reset all state. Call when restarting playback.
    mutating func reset() {
        for i in 0..<bufferSize {
            buffer[i] = 0
        }
        writeIndex = 0
        gainReduction = 1.0
        peakEnvelope = 0.0
    }
}

/// Stereo Shore limiter with linked gain reduction across L/R channels.
///
/// Uses the maximum peak from both channels to compute a single gain envelope,
/// preventing stereo image shift during limiting.
struct StereoShore {
    private let bufferL: UnsafeMutablePointer<Float>
    private let bufferR: UnsafeMutablePointer<Float>
    private let bufferSize: Int
    private var writeIndex: Int = 0

    private var gainReduction: Float = 1.0
    private var peakEnvelope: Float = 0.0
    private let releaseCoeff: Float

    var ceiling: Float
    var enabled: Bool = true

    init(lookaheadSamples: Int = 48, releaseMs: Float = 100.0, ceiling: Float = 0.97, sampleRate: Float = 48000.0) {
        self.bufferSize = lookaheadSamples
        self.bufferL = .allocate(capacity: lookaheadSamples)
        self.bufferL.initialize(repeating: 0, count: lookaheadSamples)
        self.bufferR = .allocate(capacity: lookaheadSamples)
        self.bufferR.initialize(repeating: 0, count: lookaheadSamples)
        self.ceiling = ceiling
        let releaseSamples = releaseMs / 1000.0 * sampleRate
        self.releaseCoeff = 1.0 - expf(-1.0 / releaseSamples)
    }

    /// Process a stereo sample pair. Returns (limitedL, limitedR).
    mutating func process(left: Float, right: Float) -> (Float, Float) {
        guard enabled else { return (left, right) }

        // Use max of both channels for linked detection
        let absPeak = max(abs(left), abs(right))

        if absPeak > peakEnvelope {
            peakEnvelope = absPeak
        } else {
            peakEnvelope += (absPeak - peakEnvelope) * releaseCoeff
        }

        let desiredGain: Float
        if peakEnvelope > ceiling {
            desiredGain = ceiling / peakEnvelope
        } else {
            desiredGain = 1.0
        }

        if desiredGain < gainReduction {
            gainReduction = desiredGain
        } else {
            gainReduction += (desiredGain - gainReduction) * releaseCoeff
        }

        let delayedL = bufferL[writeIndex]
        let delayedR = bufferR[writeIndex]

        bufferL[writeIndex] = left
        bufferR[writeIndex] = right

        writeIndex += 1
        if writeIndex >= bufferSize {
            writeIndex = 0
        }

        return (delayedL * gainReduction, delayedR * gainReduction)
    }

    mutating func reset() {
        for i in 0..<bufferSize {
            bufferL[i] = 0
            bufferR[i] = 0
        }
        writeIndex = 0
        gainReduction = 1.0
        peakEnvelope = 0.0
    }
}
