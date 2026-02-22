import Foundation

/// 8-voice polyphonic manager for FUSE virtual analog circuit synthesis.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
struct FuseVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (FuseVoice, FuseVoice, FuseVoice, FuseVoice,
                 FuseVoice, FuseVoice, FuseVoice, FuseVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    /// Shared parameters for all voices.
    var params = FuseParams()

    static let voiceCount = 8

    /// Sample rate stored from render callback.
    var sampleRate: Float = 48000

    init() {
        voices = (FuseVoice(), FuseVoice(), FuseVoice(), FuseVoice(),
                  FuseVoice(), FuseVoice(), FuseVoice(), FuseVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Seed each voice with unique tolerance
        seedAllTolerances()
    }

    // MARK: - Tolerance Seeding

    private mutating func seedAllTolerances() {
        voices.0.tolerance = FuseVoice.seedTolerance(voiceIndex: 0, warm: params.warm)
        voices.1.tolerance = FuseVoice.seedTolerance(voiceIndex: 1, warm: params.warm)
        voices.2.tolerance = FuseVoice.seedTolerance(voiceIndex: 2, warm: params.warm)
        voices.3.tolerance = FuseVoice.seedTolerance(voiceIndex: 3, warm: params.warm)
        voices.4.tolerance = FuseVoice.seedTolerance(voiceIndex: 4, warm: params.warm)
        voices.5.tolerance = FuseVoice.seedTolerance(voiceIndex: 5, warm: params.warm)
        voices.6.tolerance = FuseVoice.seedTolerance(voiceIndex: 6, warm: params.warm)
        voices.7.tolerance = FuseVoice.seedTolerance(voiceIndex: 7, warm: params.warm)

        // Also seed WARM state
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

    private func voiceAt(_ i: Int) -> FuseVoice {
        switch i {
        case 0: return voices.0
        case 1: return voices.1
        case 2: return voices.2
        case 3: return voices.3
        case 4: return voices.4
        case 5: return voices.5
        case 6: return voices.6
        case 7: return voices.7
        default: return voices.0
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

    /// Allocate a voice: reuse same pitch → find idle → steal lowest supply voltage.
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
            if !voiceAt(i).isActive {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the voice with lowest supply voltage (Rule 7)
        var quietest = 0
        var lowestLevel = voiceAt(0).envelopeLevel
        for i in 1..<Self.voiceCount {
            let level = voiceAt(i).envelopeLevel
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
        case 0: voices.0.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 1: voices.1.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 2: voices.2.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 3: voices.3.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 4: voices.4.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 5: voices.5.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 6: voices.6.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        case 7: voices.7.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
        default: break
        }
    }

    private mutating func releaseVoiceAt(_ i: Int) {
        switch i {
        case 0: voices.0.noteOff()
        case 1: voices.1.noteOff()
        case 2: voices.2.noteOff()
        case 3: voices.3.noteOff()
        case 4: voices.4.noteOff()
        case 5: voices.5.noteOff()
        case 6: voices.6.noteOff()
        case 7: voices.7.noteOff()
        default: break
        }
    }

    // MARK: - Configuration

    /// Apply FUSE parameters to all voices. Called from audio thread via command buffer.
    mutating func configure(
        soul: Float, tune: Float, couple: Float,
        body: Float, color: Float, warm: Float,
        keyTracking: Bool
    ) {
        params.soul = soul
        params.tune = tune
        params.couple = couple
        params.body = body
        params.color = color
        params.warm = warm
        params.keyTracking = keyTracking

        // Re-seed tolerances when warm changes
        voices.0.tolerance = FuseVoice.seedTolerance(voiceIndex: 0, warm: warm)
        voices.1.tolerance = FuseVoice.seedTolerance(voiceIndex: 1, warm: warm)
        voices.2.tolerance = FuseVoice.seedTolerance(voiceIndex: 2, warm: warm)
        voices.3.tolerance = FuseVoice.seedTolerance(voiceIndex: 3, warm: warm)
        voices.4.tolerance = FuseVoice.seedTolerance(voiceIndex: 4, warm: warm)
        voices.5.tolerance = FuseVoice.seedTolerance(voiceIndex: 5, warm: warm)
        voices.6.tolerance = FuseVoice.seedTolerance(voiceIndex: 6, warm: warm)
        voices.7.tolerance = FuseVoice.seedTolerance(voiceIndex: 7, warm: warm)
    }

    // MARK: - Render

    /// Render one sample (NoteReceiver conformance, Double sampleRate).
    mutating func renderSample(sampleRate: Double) -> Float {
        renderSampleFloat(sampleRate: Float(sampleRate))
    }

    /// Render one sample: sum all 8 voices (manually unrolled).
    mutating func renderSampleFloat(sampleRate: Float) -> Float {
        var mix: Float = 0
        mix += voices.0.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.1.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.2.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.3.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.4.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.5.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.6.renderSample(sampleRate: sampleRate, params: params)
        mix += voices.7.renderSample(sampleRate: sampleRate, params: params)

        // Clear pitch assignments for voices that finished
        if !voices.0.isActive && pitches.0 != -1 { pitches.0 = -1 }
        if !voices.1.isActive && pitches.1 != -1 { pitches.1 = -1 }
        if !voices.2.isActive && pitches.2 != -1 { pitches.2 = -1 }
        if !voices.3.isActive && pitches.3 != -1 { pitches.3 = -1 }
        if !voices.4.isActive && pitches.4 != -1 { pitches.4 = -1 }
        if !voices.5.isActive && pitches.5 != -1 { pitches.5 = -1 }
        if !voices.6.isActive && pitches.6 != -1 { pitches.6 = -1 }
        if !voices.7.isActive && pitches.7 != -1 { pitches.7 = -1 }

        return mix
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
        allocateVoice(pitch: pitch, velocity: Float(velocity), sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && voiceAt(i).isActive {
                releaseVoiceAt(i)
                return
            }
        }
    }
}
