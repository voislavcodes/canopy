import Foundation

/// 8-voice FM drum kit for audio-thread rendering.
/// Tuple storage for stack allocation — no ARC, no indirection.
/// GM-standard MIDI pitch mapping.
struct FMDrumKit {
    /// Voices stored as tuple for stack allocation (matches LFOBank pattern).
    var voices: (FMDrumVoice, FMDrumVoice, FMDrumVoice, FMDrumVoice,
                 FMDrumVoice, FMDrumVoice, FMDrumVoice, FMDrumVoice)

    static let voiceCount = 8

    /// Voice names for UI display.
    static let voiceNames = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]

    /// GM-standard MIDI pitch mapping per voice index.
    static let midiPitches = [36, 38, 42, 46, 41, 43, 49, 51]

    /// Create a default kit with sensible drum presets.
    static func defaultKit() -> FMDrumKit {
        FMDrumKit(voices: (
            .kickPreset(),
            .snarePreset(),
            .closedHatPreset(),
            .openHatPreset(),
            .tomLowPreset(),
            .tomHighPreset(),
            .crashPreset(),
            .ridePreset()
        ))
    }

    /// Map a MIDI pitch to a voice index. Returns -1 if no match.
    static func voiceIndex(forPitch pitch: Int) -> Int {
        for i in 0..<midiPitches.count {
            if midiPitches[i] == pitch { return i }
        }
        return -1
    }

    /// Trigger a voice by MIDI pitch. Returns true if a voice was found.
    @discardableResult
    mutating func trigger(pitch: Int, velocity: Double) -> Bool {
        let index = Self.voiceIndex(forPitch: pitch)
        guard index >= 0 else { return false }
        triggerVoice(index: index, velocity: velocity)
        return true
    }

    /// Trigger a voice by index directly.
    mutating func triggerVoice(index: Int, velocity: Double) {
        switch index {
        case 0: voices.0.trigger(velocity: velocity)
        case 1: voices.1.trigger(velocity: velocity)
        case 2: voices.2.trigger(velocity: velocity)
        case 3: voices.3.trigger(velocity: velocity)
        case 4: voices.4.trigger(velocity: velocity)
        case 5: voices.5.trigger(velocity: velocity)
        case 6: voices.6.trigger(velocity: velocity)
        case 7: voices.7.trigger(velocity: velocity)
        default: break
        }
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
        return mix
    }

    /// Configure a voice's parameters by index.
    mutating func configureVoice(index: Int, carrierFreq: Double, modulatorRatio: Double,
                                  fmDepth: Double, noiseMix: Double, ampDecay: Double,
                                  pitchEnvAmount: Double, pitchDecay: Double, level: Double) {
        switch index {
        case 0: applyConfig(&voices.0, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 1: applyConfig(&voices.1, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 2: applyConfig(&voices.2, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 3: applyConfig(&voices.3, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 4: applyConfig(&voices.4, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 5: applyConfig(&voices.5, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 6: applyConfig(&voices.6, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        case 7: applyConfig(&voices.7, carrierFreq: carrierFreq, modulatorRatio: modulatorRatio,
                            fmDepth: fmDepth, noiseMix: noiseMix, ampDecay: ampDecay,
                            pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay, level: level)
        default: break
        }
    }

    private func applyConfig(_ voice: inout FMDrumVoice, carrierFreq: Double, modulatorRatio: Double,
                              fmDepth: Double, noiseMix: Double, ampDecay: Double,
                              pitchEnvAmount: Double, pitchDecay: Double, level: Double) {
        voice.carrierFreq = carrierFreq
        voice.modulatorRatio = modulatorRatio
        voice.fmDepth = fmDepth
        voice.noiseMix = noiseMix
        voice.ampDecay = ampDecay
        voice.pitchEnvAmount = pitchEnvAmount
        voice.pitchDecay = pitchDecay
        voice.level = level
    }

    /// Deactivate all voices.
    mutating func allNotesOff() {
        // Voices are one-shot; just let them decay
        // For immediate silence, we'd need to zero their envelopes
    }
}

// MARK: - NoteReceiver Conformance

extension FMDrumKit: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // Ignore frequency — drum voices use their own carrier freq
        trigger(pitch: pitch, velocity: velocity)
    }

    mutating func noteOff(pitch: Int) {
        // Drums are one-shot — note-off is a no-op
    }
}
