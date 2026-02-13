import Foundation

/// ADSR envelope states.
enum EnvelopeStage {
    case idle
    case attack
    case decay
    case sustain
    case release
}

/// A single voice that generates one waveform with an ADSR envelope.
/// All methods are designed for audio-thread use: no allocations, no locks.
struct OscillatorRenderer {
    // Oscillator state
    var phase: Double = 0
    var frequency: Double = 440
    var velocity: Double = 0.8
    var isActive: Bool = false

    // Waveform: 0=sine, 1=triangle, 2=sawtooth, 3=square, 4=noise
    var waveform: Int = 0

    // ADSR envelope
    var envelopeStage: EnvelopeStage = .idle
    var envelopeLevel: Double = 0
    var attackRate: Double = 0    // per-sample increment
    var decayRate: Double = 0     // per-sample decrement
    var sustainLevel: Double = 0.7
    var releaseRate: Double = 0   // per-sample decrement

    // Noise state (simple LCG for deterministic noise)
    var noiseSeed: UInt32 = 1

    /// Configure envelope rates from seconds-based ADSR parameters.
    mutating func configureEnvelope(attack: Double, decay: Double, sustain: Double, release: Double, sampleRate: Double) {
        let minTime = 0.001 // prevent division by zero
        attackRate = 1.0 / (max(attack, minTime) * sampleRate)
        decayRate = (1.0 - sustain) / (max(decay, minTime) * sampleRate)
        sustainLevel = sustain
        releaseRate = sustain / (max(release, minTime) * sampleRate)
    }

    /// Trigger a note on.
    /// When retriggering an active voice, preserves phase and envelope level
    /// to avoid discontinuities (pops/clicks).
    mutating func noteOn(frequency: Double, velocity: Double) {
        self.frequency = frequency
        self.velocity = velocity
        if !isActive {
            self.phase = 0
            self.envelopeLevel = 0
        }
        self.envelopeStage = .attack
        self.isActive = true
    }

    /// Trigger a note off (enters release stage).
    mutating func noteOff() {
        if isActive {
            envelopeStage = .release
        }
    }

    /// Render a single sample. Returns the amplitude value [-1, 1] scaled by envelope and velocity.
    mutating func renderSample(sampleRate: Double) -> Float {
        guard isActive else { return 0 }

        // Advance envelope
        advanceEnvelope()

        if envelopeStage == .idle {
            isActive = false
            return 0
        }

        // Generate waveform sample
        let raw = generateWaveform()

        // Advance phase
        phase += frequency / sampleRate
        if phase >= 1.0 {
            phase -= 1.0
        }

        return Float(raw * envelopeLevel * velocity)
    }

    // MARK: - Private

    private mutating func advanceEnvelope() {
        switch envelopeStage {
        case .idle:
            break

        case .attack:
            envelopeLevel += attackRate
            if envelopeLevel >= 1.0 {
                envelopeLevel = 1.0
                envelopeStage = .decay
            }

        case .decay:
            envelopeLevel -= decayRate
            if envelopeLevel <= sustainLevel {
                envelopeLevel = sustainLevel
                envelopeStage = .sustain
            }

        case .sustain:
            // Hold at sustain level until noteOff
            envelopeLevel = sustainLevel

        case .release:
            envelopeLevel -= releaseRate
            if envelopeLevel <= 0 {
                envelopeLevel = 0
                envelopeStage = .idle
            }
        }
    }

    private mutating func generateWaveform() -> Double {
        switch waveform {
        case 0: // Sine
            return sin(phase * 2.0 * .pi)

        case 1: // Triangle
            return 4.0 * abs(phase - 0.5) - 1.0

        case 2: // Sawtooth
            return 2.0 * phase - 1.0

        case 3: // Square
            return phase < 0.5 ? 1.0 : -1.0

        case 4: // Noise (linear congruential generator)
            noiseSeed = noiseSeed &* 1664525 &+ 1013904223
            return Double(Int32(bitPattern: noiseSeed)) / Double(Int32.max)

        default:
            return 0
        }
    }
}
