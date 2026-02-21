import Foundation

/// 8-voice polyphonic manager for the FUSE engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as FlowVoiceManager.
struct FuseVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (FuseVoice, FuseVoice, FuseVoice, FuseVoice,
                 FuseVoice, FuseVoice, FuseVoice, FuseVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    /// Sample rate stored from render callback — used by NoteReceiver methods.
    var sampleRate: Double = 48000

    /// WARM node-level state for inter-voice power sag.
    var warmNodeState: WarmNodeState = WarmNodeState()

    init() {
        voices = (FuseVoice(), FuseVoice(), FuseVoice(), FuseVoice(),
                  FuseVoice(), FuseVoice(), FuseVoice(), FuseVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique RNG seeds per voice for coupling asymmetry
        voices.0.rng = 0x1234_5678_9ABC_DEF0
        voices.1.rng = 0x8765_4321_FEDC_BA98
        voices.2.rng = 0xDEAD_BEEF_CAFE_BABE
        voices.3.rng = 0xCAFE_BABE_DEAD_BEEF
        voices.4.rng = 0xFACE_FEED_BEAD_D00D
        voices.5.rng = 0xBAAD_F00D_C0DE_F00D
        voices.6.rng = 0xD00D_BEAD_FACE_FEED
        voices.7.rng = 0xC0DE_F00D_BAAD_F00D

        // WARM: unique analog tolerance per voice
        WarmProcessor.seedVoice(&voices.0.warmState, voiceIndex: 0)
        WarmProcessor.seedVoice(&voices.1.warmState, voiceIndex: 1)
        WarmProcessor.seedVoice(&voices.2.warmState, voiceIndex: 2)
        WarmProcessor.seedVoice(&voices.3.warmState, voiceIndex: 3)
        WarmProcessor.seedVoice(&voices.4.warmState, voiceIndex: 4)
        WarmProcessor.seedVoice(&voices.5.warmState, voiceIndex: 5)
        WarmProcessor.seedVoice(&voices.6.warmState, voiceIndex: 6)
        WarmProcessor.seedVoice(&voices.7.warmState, voiceIndex: 7)
    }

    // MARK: - Voice Access Helpers

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

    private mutating func allocateVoice(pitch: Int, velocity: Double, sampleRate: Double) {
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

    mutating func configureFuse(
        character: Double, tune: Double, couple: Double,
        filter: Double, feedback: Double, warmth: Double
    ) {
        applyConfig(&voices.0, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.1, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.2, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.3, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.4, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.5, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.6, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
        applyConfig(&voices.7, character: character, tune: tune, couple: couple, filter: filter, feedback: feedback, warmth: warmth)
    }

    private func applyConfig(
        _ voice: inout FuseVoice,
        character: Double, tune: Double, couple: Double,
        filter: Double, feedback: Double, warmth: Double
    ) {
        voice.characterTarget = character
        voice.tuneTarget = tune
        voice.coupleTarget = couple
        voice.filterTarget = filter
        voice.feedbackTarget = feedback
        voice.warmthTarget = warmth
    }

    // MARK: - Render

    mutating func renderSample(sampleRate: Double) -> Float {
        let s0 = voices.0.renderSample(sampleRate: sampleRate)
        let s1 = voices.1.renderSample(sampleRate: sampleRate)
        let s2 = voices.2.renderSample(sampleRate: sampleRate)
        let s3 = voices.3.renderSample(sampleRate: sampleRate)
        let s4 = voices.4.renderSample(sampleRate: sampleRate)
        let s5 = voices.5.renderSample(sampleRate: sampleRate)
        let s6 = voices.6.renderSample(sampleRate: sampleRate)
        let s7 = voices.7.renderSample(sampleRate: sampleRate)

        var mix = s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7

        // Clear pitch assignments for voices that finished
        if !voices.0.isActive && pitches.0 != -1 { pitches.0 = -1 }
        if !voices.1.isActive && pitches.1 != -1 { pitches.1 = -1 }
        if !voices.2.isActive && pitches.2 != -1 { pitches.2 = -1 }
        if !voices.3.isActive && pitches.3 != -1 { pitches.3 = -1 }
        if !voices.4.isActive && pitches.4 != -1 { pitches.4 = -1 }
        if !voices.5.isActive && pitches.5 != -1 { pitches.5 = -1 }
        if !voices.6.isActive && pitches.6 != -1 { pitches.6 = -1 }
        if !voices.7.isActive && pitches.7 != -1 { pitches.7 = -1 }

        // WARM: inter-voice power sag
        let warmLevel = Float(voices.0.warmthParam)
        mix = WarmProcessor.applyPowerSagMono(&warmNodeState, sample: mix, warm: warmLevel)

        // Output limiting
        return Float(tanh(Double(mix) * 0.8) * 3.0)
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

extension FuseVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        allocateVoice(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && isVoiceActive(i) {
                releaseVoiceAt(i, sampleRate: sampleRate)
                return
            }
        }
    }
}
