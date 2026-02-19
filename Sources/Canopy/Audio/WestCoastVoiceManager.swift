import Foundation

/// 8-voice polyphonic manager for West Coast complex oscillator.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as FMDrumKit: fixed tuple, manual unrolling.
struct WestCoastVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (WestCoastVoice, WestCoastVoice, WestCoastVoice, WestCoastVoice,
                 WestCoastVoice, WestCoastVoice, WestCoastVoice, WestCoastVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    init() {
        voices = (WestCoastVoice(), WestCoastVoice(), WestCoastVoice(), WestCoastVoice(),
                  WestCoastVoice(), WestCoastVoice(), WestCoastVoice(), WestCoastVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)
    }

    // MARK: - Voice Access Helpers

    private func voiceAt(_ i: Int) -> WestCoastVoice {
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

    /// Allocate a voice: reuse same pitch → find idle → steal quietest.
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
            if !voiceAt(i).isActive {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the quietest voice
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

    /// Apply West Coast parameters to all 8 voices.
    mutating func configureWestCoast(
        primaryWaveform: Int, modulatorRatio: Double, modulatorFineTune: Double,
        fmDepth: Double, envToFM: Double,
        ringModMix: Double,
        foldAmount: Double, foldStages: Int, foldSymmetry: Double, modToFold: Double,
        lpgMode: Int, strike: Double, damp: Double, color: Double,
        rise: Double, fall: Double, funcShape: Int, funcLoop: Bool
    ) {
        applyConfig(&voices.0, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.1, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.2, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.3, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.4, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.5, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.6, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
        applyConfig(&voices.7, primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio, modulatorFineTune: modulatorFineTune, fmDepth: fmDepth, envToFM: envToFM, ringModMix: ringModMix, foldAmount: foldAmount, foldStages: foldStages, foldSymmetry: foldSymmetry, modToFold: modToFold, lpgMode: lpgMode, strike: strike, damp: damp, color: color, rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop)
    }

    private func applyConfig(
        _ voice: inout WestCoastVoice,
        primaryWaveform: Int, modulatorRatio: Double, modulatorFineTune: Double,
        fmDepth: Double, envToFM: Double,
        ringModMix: Double,
        foldAmount: Double, foldStages: Int, foldSymmetry: Double, modToFold: Double,
        lpgMode: Int, strike: Double, damp: Double, color: Double,
        rise: Double, fall: Double, funcShape: Int, funcLoop: Bool
    ) {
        voice.primaryWaveform = primaryWaveform
        voice.modulatorRatio = modulatorRatio
        voice.modulatorFineTune = modulatorFineTune
        voice.fmDepth = fmDepth
        voice.envToFM = envToFM
        voice.ringModMix = ringModMix
        voice.foldAmount = foldAmount
        voice.foldStages = foldStages
        voice.foldSymmetry = foldSymmetry
        voice.modToFold = modToFold
        voice.lpgMode = lpgMode
        voice.strike = strike
        voice.damp = damp
        voice.color = color
        voice.rise = rise
        voice.fall = fall
        voice.funcShape = funcShape
        voice.funcLoop = funcLoop
    }

    /// Render one sample: sum all 8 voices (manually unrolled).
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

extension WestCoastVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // frequency parameter ignored — WestCoastVoice computes its own from pitch
        allocateVoice(pitch: pitch, velocity: velocity, sampleRate: 44100)
    }

    mutating func noteOff(pitch: Int) {
        // Release all voices playing this pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && voiceAt(i).isActive {
                releaseVoiceAt(i, sampleRate: 44100)
                return
            }
        }
    }
}
