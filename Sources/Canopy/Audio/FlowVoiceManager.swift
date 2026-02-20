import Foundation

/// 8-voice polyphonic manager for the FLOW engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as WestCoastVoiceManager.
struct FlowVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (FlowVoice, FlowVoice, FlowVoice, FlowVoice,
                 FlowVoice, FlowVoice, FlowVoice, FlowVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    init() {
        voices = (FlowVoice(), FlowVoice(), FlowVoice(), FlowVoice(),
                  FlowVoice(), FlowVoice(), FlowVoice(), FlowVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique noise seeds per voice — decorrelates turbulence across voices.
        voices.0.noiseState = 0x1234_5678
        voices.1.noiseState = 0x8765_4321
        voices.2.noiseState = 0xDEAD_BEEF
        voices.3.noiseState = 0xCAFE_BABE
        voices.4.noiseState = 0xFACE_FEED
        voices.5.noiseState = 0xBAAD_F00D
        voices.6.noiseState = 0xD00D_BEAD
        voices.7.noiseState = 0xC0DE_F00D
    }

    // MARK: - Voice Access Helpers
    //
    // CRITICAL: No voiceAt() that returns FlowVoice by value.
    // Copying a FlowVoice copies its [FlowPartial] array reference,
    // bumping the refcount to 2. If the copy is alive when triggerVoiceAt
    // mutates partials[], Swift triggers CoW — a heap allocation on the
    // audio thread. Instead, read specific properties directly from the tuple.

    /// Read isActive without copying the entire FlowVoice (avoids CoW on [FlowPartial]).
    private func isVoiceActive(_ i: Int) -> Bool {
        switch i {
        case 0: return voices.0.isActive
        case 1: return voices.1.isActive
        case 2: return voices.2.isActive
        case 3: return voices.3.isActive
        case 4: return voices.4.isActive
        case 5: return voices.5.isActive
        case 6: return voices.6.isActive
        case 7: return voices.7.isActive
        default: return false
        }
    }

    /// Read envelopeLevel without copying the entire FlowVoice.
    private func voiceEnvelopeLevel(_ i: Int) -> Float {
        switch i {
        case 0: return voices.0.envelopeLevel
        case 1: return voices.1.envelopeLevel
        case 2: return voices.2.envelopeLevel
        case 3: return voices.3.envelopeLevel
        case 4: return voices.4.envelopeLevel
        case 5: return voices.5.envelopeLevel
        case 6: return voices.6.envelopeLevel
        case 7: return voices.7.envelopeLevel
        default: return 0
        }
    }

    private func pitchAt(_ i: Int) -> Int {
        switch i {
        case 0: return pitches.0
        case 1: return pitches.1
        case 2: return pitches.2
        case 3: return pitches.3
        case 4: return pitches.4
        case 5: return pitches.5
        case 6: return pitches.6
        case 7: return pitches.7
        default: return -1
        }
    }

    private mutating func setPitch(_ i: Int, _ v: Int) {
        switch i {
        case 0: pitches.0 = v
        case 1: pitches.1 = v
        case 2: pitches.2 = v
        case 3: pitches.3 = v
        case 4: pitches.4 = v
        case 5: pitches.5 = v
        case 6: pitches.6 = v
        case 7: pitches.7 = v
        default: break
        }
    }

    // MARK: - Voice Stealing

    /// Allocate a voice: reuse same pitch → find idle → steal quietest.
    private mutating func allocateVoice(pitch: Int, velocity: Double, sampleRate: Double) {
        // First: reuse a voice already playing this pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch {
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Second: find an idle voice (reads Bool directly, no FlowVoice copy)
        for i in 0..<Self.voiceCount {
            if !isVoiceActive(i) {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the quietest voice (reads Float directly, no FlowVoice copy)
        var quietest = 0
        var lowestLevel = voiceEnvelopeLevel(0)
        for i in 1..<Self.voiceCount {
            let level = voiceEnvelopeLevel(i)
            if level < lowestLevel {
                lowestLevel = level
                quietest = i
            }
        }
        setPitch(quietest, pitch)
        triggerVoiceAt(quietest, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    private mutating func triggerVoiceAt(_ i: Int, pitch: Int, velocity: Double, sampleRate: Double) {
        switch i {
        case 0: voices.0.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 1: voices.1.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 2: voices.2.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 3: voices.3.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 4: voices.4.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 5: voices.5.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 6: voices.6.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 7: voices.7.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        default: break
        }
    }

    private mutating func releaseVoiceAt(_ i: Int, sampleRate: Double) {
        switch i {
        case 0: voices.0.release(sampleRate: sampleRate)
        case 1: voices.1.release(sampleRate: sampleRate)
        case 2: voices.2.release(sampleRate: sampleRate)
        case 3: voices.3.release(sampleRate: sampleRate)
        case 4: voices.4.release(sampleRate: sampleRate)
        case 5: voices.5.release(sampleRate: sampleRate)
        case 6: voices.6.release(sampleRate: sampleRate)
        case 7: voices.7.release(sampleRate: sampleRate)
        default: break
        }
    }

    // MARK: - Bulk Configuration

    /// Apply FLOW parameters to all 8 voices.
    mutating func configureFlow(
        current: Double, viscosity: Double, obstacle: Double,
        channel: Double, density: Double, warmth: Double
    ) {
        applyConfig(&voices.0, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.1, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.2, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.3, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.4, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.5, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.6, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
        applyConfig(&voices.7, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth)
    }

    private func applyConfig(
        _ voice: inout FlowVoice,
        current: Double, viscosity: Double, obstacle: Double,
        channel: Double, density: Double, warmth: Double
    ) {
        voice.currentTarget = current
        voice.viscosityTarget = viscosity
        voice.obstacleTarget = obstacle
        voice.channelTarget = channel
        voice.densityTarget = density
        voice.warmthTarget = warmth
    }

    /// Render one sample: sum all 8 voices, then soft-limit once.
    /// Single tanh at the sum — NOT per-voice. Per-voice tanh creates odd harmonics
    /// that intermodulate when summed, producing distortion that scales with voice count.
    /// One tanh on the sum gracefully handles any number of voices without volume pumping.
    mutating func renderSample(sampleRate: Double) -> Float {
        var mix: Float = 0
        mix += voices.0.renderSample(sampleRate: sampleRate)
        mix += voices.1.renderSample(sampleRate: sampleRate)
        mix += voices.2.renderSample(sampleRate: sampleRate)
        mix += voices.3.renderSample(sampleRate: sampleRate)
        mix += voices.4.renderSample(sampleRate: sampleRate)
        mix += voices.5.renderSample(sampleRate: sampleRate)
        mix += voices.6.renderSample(sampleRate: sampleRate)
        mix += voices.7.renderSample(sampleRate: sampleRate)

        // Clear pitch assignments for voices that finished
        if !voices.0.isActive && pitches.0 != -1 { pitches.0 = -1 }
        if !voices.1.isActive && pitches.1 != -1 { pitches.1 = -1 }
        if !voices.2.isActive && pitches.2 != -1 { pitches.2 = -1 }
        if !voices.3.isActive && pitches.3 != -1 { pitches.3 = -1 }
        if !voices.4.isActive && pitches.4 != -1 { pitches.4 = -1 }
        if !voices.5.isActive && pitches.5 != -1 { pitches.5 = -1 }
        if !voices.6.isActive && pitches.6 != -1 { pitches.6 = -1 }
        if !voices.7.isActive && pitches.7 != -1 { pitches.7 = -1 }

        // Two-stage output: gentle tanh tames peaks, then linear gain boosts volume.
        // tanh(mix * 0.7) barely compresses single voices but catches multi-voice peaks.
        // The ×3.5 linear boost brings FLOW in line with other synths.
        // Shore (master bus limiter) handles any output exceeding ±1.0.
        return Float(tanh(Double(mix) * 0.4) * 7.99)
    }

    /// Kill all voices immediately.
    mutating func allNotesOff() {
        voices.0.kill()
        voices.1.kill()
        voices.2.kill()
        voices.3.kill()
        voices.4.kill()
        voices.5.kill()
        voices.6.kill()
        voices.7.kill()
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)
    }
}

// MARK: - NoteReceiver Conformance

extension FlowVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // frequency parameter ignored — FlowVoice computes its own from pitch
        allocateVoice(pitch: pitch, velocity: velocity, sampleRate: 44100)
    }

    mutating func noteOff(pitch: Int) {
        // Release all voices playing this pitch (reads Bool directly, no FlowVoice copy)
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && isVoiceActive(i) {
                releaseVoiceAt(i, sampleRate: 44100)
                return
            }
        }
    }
}
