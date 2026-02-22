import Foundation

/// 8-voice polyphonic manager for VOLT analog circuit drum synthesis.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
struct VoltVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (VoltVoice, VoltVoice, VoltVoice, VoltVoice,
                 VoltVoice, VoltVoice, VoltVoice, VoltVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    /// Shared parameters for all voices.
    var params = VoltParams()

    static let voiceCount = 8

    /// Sample rate stored from render callback.
    var sampleRate: Float = 48000

    init() {
        voices = (VoltVoice(), VoltVoice(), VoltVoice(), VoltVoice(),
                  VoltVoice(), VoltVoice(), VoltVoice(), VoltVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Seed each voice with unique RNG, tolerance, and WARM state
        seedAllVoices()
    }

    // MARK: - Voice Seeding

    private mutating func seedAllVoices() {
        for i in 0..<Self.voiceCount {
            var voice = voiceAt(i)
            voice.tolerance = VoltTolerance.seed(voiceIndex: i, warm: params.warm)
            voice.rng = UInt64(i &* 2654435761 &+ 1442695040888963407)
            WarmProcessor.seedVoice(&voice.warmState, voiceIndex: i)
            setVoice(i, voice)
        }
    }

    // MARK: - Voice Access Helpers

    private func voiceAt(_ i: Int) -> VoltVoice {
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

    private mutating func setVoice(_ i: Int, _ v: VoltVoice) {
        switch i {
        case 0: voices.0 = v
        case 1: voices.1 = v
        case 2: voices.2 = v
        case 3: voices.3 = v
        case 4: voices.4 = v
        case 5: voices.5 = v
        case 6: voices.6 = v
        case 7: voices.7 = v
        default: break
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

    /// Allocate a voice: reuse same pitch → find idle → steal lowest envelope cap voltage.
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

        // Third: steal the voice with lowest envelope cap voltage (Rule 7)
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
        case 0:
            voices.0.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.0.trigger(params: params)
        case 1:
            voices.1.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.1.trigger(params: params)
        case 2:
            voices.2.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.2.trigger(params: params)
        case 3:
            voices.3.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.3.trigger(params: params)
        case 4:
            voices.4.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.4.trigger(params: params)
        case 5:
            voices.5.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.5.trigger(params: params)
        case 6:
            voices.6.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.6.trigger(params: params)
        case 7:
            voices.7.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.7.trigger(params: params)
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

    /// Apply VOLT parameters. Called from audio thread via command buffer.
    mutating func configure(
        layerA: Int, layerB: Int, mix: Float,
        resPitch: Float, resSweep: Float, resDecay: Float, resDrive: Float, resPunch: Float,
        noiseColor: Float, noiseSnap: Float, noiseBody: Float,
        noiseClap: Float, noiseTone: Float, noiseFilter: Float,
        metSpread: Float, metTune: Float, metRing: Float, metBand: Float, metDensity: Float,
        tonPitch: Float, tonFM: Float, tonShape: Float, tonBend: Float, tonDecay: Float,
        warm: Float
    ) {
        params.layerATopology = layerA
        params.layerBTopology = layerB
        params.mix = mix
        params.resPitch = resPitch; params.resSweep = resSweep; params.resDecay = resDecay
        params.resDrive = resDrive; params.resPunch = resPunch
        params.noiseColor = noiseColor; params.noiseSnap = noiseSnap; params.noiseBody = noiseBody
        params.noiseClap = noiseClap; params.noiseTone = noiseTone; params.noiseFilter = noiseFilter
        params.metSpread = metSpread; params.metTune = metTune; params.metRing = metRing
        params.metBand = metBand; params.metDensity = metDensity
        params.tonPitch = tonPitch; params.tonFM = tonFM; params.tonShape = tonShape
        params.tonBend = tonBend; params.tonDecay = tonDecay
        params.warm = warm

        // Re-seed tolerances when warm changes
        voices.0.tolerance = VoltTolerance.seed(voiceIndex: 0, warm: warm)
        voices.1.tolerance = VoltTolerance.seed(voiceIndex: 1, warm: warm)
        voices.2.tolerance = VoltTolerance.seed(voiceIndex: 2, warm: warm)
        voices.3.tolerance = VoltTolerance.seed(voiceIndex: 3, warm: warm)
        voices.4.tolerance = VoltTolerance.seed(voiceIndex: 4, warm: warm)
        voices.5.tolerance = VoltTolerance.seed(voiceIndex: 5, warm: warm)
        voices.6.tolerance = VoltTolerance.seed(voiceIndex: 6, warm: warm)
        voices.7.tolerance = VoltTolerance.seed(voiceIndex: 7, warm: warm)
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

extension VoltVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        allocateVoice(pitch: pitch, velocity: Float(velocity), sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        // Drums don't gate — they decay naturally. But release matching voice for reuse.
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && voiceAt(i).isActive {
                releaseVoiceAt(i)
                return
            }
        }
    }
}
