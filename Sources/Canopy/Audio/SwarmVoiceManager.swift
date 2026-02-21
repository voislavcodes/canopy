import Foundation

/// 8-voice polyphonic manager for the SWARM engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as FlowVoiceManager.
struct SwarmVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (SwarmVoice, SwarmVoice, SwarmVoice, SwarmVoice,
                 SwarmVoice, SwarmVoice, SwarmVoice, SwarmVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    // Shared controls
    var sampleRate: Float = 48000
    var gravity: Float = 0.5
    var energy: Float = 0.3
    var flock: Float = 0.2
    var scatter: Float = 0.3
    var warmth: Float = 0.3

    init() {
        voices = (SwarmVoice(), SwarmVoice(), SwarmVoice(), SwarmVoice(),
                  SwarmVoice(), SwarmVoice(), SwarmVoice(), SwarmVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique noise seeds per voice — decorrelates turbulence (Rule 10)
        voices.0.noiseSeedBase = 0x1234_5678
        voices.1.noiseSeedBase = 0x8765_4321
        voices.2.noiseSeedBase = 0xDEAD_BEEF
        voices.3.noiseSeedBase = 0xCAFE_BABE
        voices.4.noiseSeedBase = 0xFACE_FEED
        voices.5.noiseSeedBase = 0xBAAD_F00D
        voices.6.noiseSeedBase = 0xD00D_BEAD
        voices.7.noiseSeedBase = 0xC0DE_F00D
    }

    // MARK: - Voice Access Helpers
    //
    // CRITICAL: No voiceAt() that returns SwarmVoice by value.
    // Copying a SwarmVoice would copy all tuple data. Instead,
    // read specific properties directly from the tuple via switch.

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

    /// Allocate a voice: reuse same pitch → find idle → steal quietest (Rule 7).
    private mutating func allocateVoice(pitch: Int, velocity: Float, sampleRate: Float) {
        // First: reuse a voice already playing this pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch {
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Second: find an idle voice
        for i in 0..<Self.voiceCount {
            if !isVoiceActive(i) {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the quietest voice
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

    private mutating func triggerVoiceAt(_ i: Int, pitch: Int, velocity: Float, sampleRate: Float) {
        switch i {
        case 0: voices.0.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 1: voices.1.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 2: voices.2.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 3: voices.3.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 4: voices.4.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 5: voices.5.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 6: voices.6.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        case 7: voices.7.trigger(pitch: pitch, velocity: velocity, gravity: gravity, energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate)
        default: break
        }
    }

    private mutating func releaseVoiceAt(_ i: Int, sampleRate: Float) {
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

    /// Apply SWARM parameters to all 8 voices.
    mutating func configureSwarm(
        gravity: Float, energy: Float, flock: Float,
        scatter: Float, warmth: Float
    ) {
        self.gravity = gravity
        self.energy = energy
        self.flock = flock
        self.scatter = scatter
        self.warmth = warmth
        voices.0.warmth = warmth
        voices.1.warmth = warmth
        voices.2.warmth = warmth
        voices.3.warmth = warmth
        voices.4.warmth = warmth
        voices.5.warmth = warmth
        voices.6.warmth = warmth
        voices.7.warmth = warmth
    }

    /// Render one stereo sample: sum all 8 voices, then safety tanh (Rule 6).
    mutating func renderStereoSample(sampleRate: Float) -> (Float, Float) {
        var mixL: Float = 0
        var mixR: Float = 0

        // Render each voice
        let g = gravity, e = energy, f = flock, s = scatter, sr = sampleRate

        let (l0, r0) = voices.0.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l0; mixR += r0
        let (l1, r1) = voices.1.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l1; mixR += r1
        let (l2, r2) = voices.2.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l2; mixR += r2
        let (l3, r3) = voices.3.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l3; mixR += r3
        let (l4, r4) = voices.4.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l4; mixR += r4
        let (l5, r5) = voices.5.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l5; mixR += r5
        let (l6, r6) = voices.6.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l6; mixR += r6
        let (l7, r7) = voices.7.renderSample(gravity: g, energy: e, flock: f, scatter: s, sampleRate: sr)
        mixL += l7; mixR += r7

        // Clear pitch assignments for voices that finished
        if !voices.0.isActive && pitches.0 != -1 { pitches.0 = -1 }
        if !voices.1.isActive && pitches.1 != -1 { pitches.1 = -1 }
        if !voices.2.isActive && pitches.2 != -1 { pitches.2 = -1 }
        if !voices.3.isActive && pitches.3 != -1 { pitches.3 = -1 }
        if !voices.4.isActive && pitches.4 != -1 { pitches.4 = -1 }
        if !voices.5.isActive && pitches.5 != -1 { pitches.5 = -1 }
        if !voices.6.isActive && pitches.6 != -1 { pitches.6 = -1 }
        if !voices.7.isActive && pitches.7 != -1 { pitches.7 = -1 }

        // Manager-level safety tanh (Rule 6)
        mixL = tanhf(mixL * 0.5)
        mixR = tanhf(mixR * 0.5)

        return (mixL, mixR)
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

extension SwarmVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        allocateVoice(pitch: pitch, velocity: Float(velocity), sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && isVoiceActive(i) {
                releaseVoiceAt(i, sampleRate: sampleRate)
                return
            }
        }
    }

    mutating func renderSample(sampleRate: Double) -> Float {
        // NoteReceiver requires mono — sum stereo to mono
        let (l, r) = renderStereoSample(sampleRate: Float(sampleRate))
        return (l + r) * 0.5
    }
}
