import Foundation

/// 8-voice fixed-slot drum kit manager for VOLT analog circuit drum synthesis.
/// Each voice has its own VoltParams — MIDI pitch maps to a fixed slot index.
/// Same architecture as FMDrumKit: no voice stealing, fixed mapping.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
struct VoltVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (VoltVoice, VoltVoice, VoltVoice, VoltVoice,
                 VoltVoice, VoltVoice, VoltVoice, VoltVoice)

    /// Per-slot parameters (each slot has independent topology/params).
    var slotParams: (VoltParams, VoltParams, VoltParams, VoltParams,
                     VoltParams, VoltParams, VoltParams, VoltParams)

    static let voiceCount = 8

    /// GM-standard MIDI pitch mapping per voice index (matches FMDrumKit).
    static let midiPitches = [36, 38, 42, 46, 41, 43, 49, 51]
    static let voiceNames = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]

    /// Sample rate stored from render callback.
    var sampleRate: Float = 48000

    init() {
        voices = (VoltVoice(), VoltVoice(), VoltVoice(), VoltVoice(),
                  VoltVoice(), VoltVoice(), VoltVoice(), VoltVoice())
        slotParams = (VoltParams(), VoltParams(), VoltParams(), VoltParams(),
                      VoltParams(), VoltParams(), VoltParams(), VoltParams())

        // Seed each voice with unique RNG, tolerance, and WARM state
        seedAllVoices()
    }

    // MARK: - Voice Seeding

    private mutating func seedAllVoices() {
        for i in 0..<Self.voiceCount {
            var voice = voiceAt(i)
            let warm = slotParamsAt(i).warm
            voice.tolerance = VoltTolerance.seed(voiceIndex: i, warm: warm)
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

    private func slotParamsAt(_ i: Int) -> VoltParams {
        switch i {
        case 0: return slotParams.0
        case 1: return slotParams.1
        case 2: return slotParams.2
        case 3: return slotParams.3
        case 4: return slotParams.4
        case 5: return slotParams.5
        case 6: return slotParams.6
        case 7: return slotParams.7
        default: return slotParams.0
        }
    }

    // MARK: - Fixed MIDI Mapping

    /// Map a MIDI pitch to a voice index. Returns -1 if no match.
    static func voiceIndex(forPitch pitch: Int) -> Int {
        for i in 0..<midiPitches.count {
            if midiPitches[i] == pitch { return i }
        }
        return -1
    }

    // MARK: - Note Trigger

    private mutating func triggerVoiceAt(_ i: Int, pitch: Int, velocity: Float, sampleRate: Float) {
        let p = slotParamsAt(i)
        switch i {
        case 0:
            voices.0.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.0.trigger(params: p)
        case 1:
            voices.1.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.1.trigger(params: p)
        case 2:
            voices.2.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.2.trigger(params: p)
        case 3:
            voices.3.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.3.trigger(params: p)
        case 4:
            voices.4.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.4.trigger(params: p)
        case 5:
            voices.5.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.5.trigger(params: p)
        case 6:
            voices.6.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.6.trigger(params: p)
        case 7:
            voices.7.noteOn(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            voices.7.trigger(params: p)
        default: break
        }
    }

    // MARK: - Per-Slot Configuration

    /// Apply parameters to a single slot. Called from audio thread via command buffer.
    mutating func configureSlot(
        index: Int,
        layerA: Int, layerB: Int, mix: Float,
        resPitch: Float, resSweep: Float, resDecay: Float, resDrive: Float, resPunch: Float,
        noiseColor: Float, noiseSnap: Float, noiseBody: Float,
        noiseClap: Float, noiseTone: Float, noiseFilter: Float,
        metSpread: Float, metTune: Float, metRing: Float, metBand: Float, metDensity: Float,
        tonPitch: Float, tonFM: Float, tonShape: Float, tonBend: Float, tonDecay: Float,
        warm: Float
    ) {
        var p = VoltParams()
        p.layerATopology = layerA
        p.layerBTopology = layerB
        p.mix = mix
        p.resPitch = resPitch; p.resSweep = resSweep; p.resDecay = resDecay
        p.resDrive = resDrive; p.resPunch = resPunch
        p.noiseColor = noiseColor; p.noiseSnap = noiseSnap; p.noiseBody = noiseBody
        p.noiseClap = noiseClap; p.noiseTone = noiseTone; p.noiseFilter = noiseFilter
        p.metSpread = metSpread; p.metTune = metTune; p.metRing = metRing
        p.metBand = metBand; p.metDensity = metDensity
        p.tonPitch = tonPitch; p.tonFM = tonFM; p.tonShape = tonShape
        p.tonBend = tonBend; p.tonDecay = tonDecay
        p.warm = warm

        switch index {
        case 0: slotParams.0 = p
        case 1: slotParams.1 = p
        case 2: slotParams.2 = p
        case 3: slotParams.3 = p
        case 4: slotParams.4 = p
        case 5: slotParams.5 = p
        case 6: slotParams.6 = p
        case 7: slotParams.7 = p
        default: break
        }

        // Re-seed tolerance for this voice when warm changes
        var voice = voiceAt(index)
        voice.tolerance = VoltTolerance.seed(voiceIndex: index, warm: warm)
        setVoice(index, voice)
    }

    // MARK: - Render

    /// Render one sample (NoteReceiver conformance, Double sampleRate).
    mutating func renderSample(sampleRate: Double) -> Float {
        renderSampleFloat(sampleRate: Float(sampleRate))
    }

    /// Render one sample: sum all 8 voices with per-slot params (manually unrolled).
    mutating func renderSampleFloat(sampleRate: Float) -> Float {
        var mix: Float = 0
        mix += voices.0.renderSample(sampleRate: sampleRate, params: slotParams.0)
        mix += voices.1.renderSample(sampleRate: sampleRate, params: slotParams.1)
        mix += voices.2.renderSample(sampleRate: sampleRate, params: slotParams.2)
        mix += voices.3.renderSample(sampleRate: sampleRate, params: slotParams.3)
        mix += voices.4.renderSample(sampleRate: sampleRate, params: slotParams.4)
        mix += voices.5.renderSample(sampleRate: sampleRate, params: slotParams.5)
        mix += voices.6.renderSample(sampleRate: sampleRate, params: slotParams.6)
        mix += voices.7.renderSample(sampleRate: sampleRate, params: slotParams.7)
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
    }
}

// MARK: - NoteReceiver Conformance

extension VoltVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        let index = Self.voiceIndex(forPitch: pitch)
        guard index >= 0 else { return }
        triggerVoiceAt(index, pitch: pitch, velocity: Float(velocity), sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        // Drums are one-shot — note-off is a no-op
    }
}
