import Foundation

/// 8-voice QUAKE percussion manager for audio-thread rendering.
/// Tuple storage for stack allocation — no ARC, no indirection.
/// GM-standard MIDI pitch mapping (same as FMDrumKit).
struct QuakeVoiceManager {
    /// Voices stored as tuple for stack allocation.
    var voices: (QuakeVoice, QuakeVoice, QuakeVoice, QuakeVoice,
                 QuakeVoice, QuakeVoice, QuakeVoice, QuakeVoice)

    static let voiceCount = 8

    /// Voice names for UI display.
    static let voiceNames = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]

    /// GM-standard MIDI pitch mapping per voice index.
    static let midiPitches = [36, 38, 42, 46, 41, 43, 49, 51]

    /// Create a default kit with regime presets.
    static func defaultKit() -> QuakeVoiceManager {
        QuakeVoiceManager(voices: (
            .kick(),
            .snare(),
            .closedHat(),
            .openHat(),
            .tomLow(),
            .tomHigh(),
            .crash(),
            .ride()
        ))
    }

    /// Map a MIDI pitch to a voice index. Returns -1 if no match.
    static func voiceIndex(forPitch pitch: Int) -> Int {
        for i in 0..<midiPitches.count {
            if midiPitches[i] == pitch { return i }
        }
        return -1
    }

    /// Configure physics controls on a single voice by index.
    mutating func configureVoice(index: Int, mass: Double, surface: Double, force: Double, sustain: Double) {
        guard index >= 0 && index < 8 else { return }
        withUnsafeMutablePointer(to: &voices) { ptr in
            ptr.withMemoryRebound(to: QuakeVoice.self, capacity: 8) { p in
                p[index].mass = mass
                p[index].surface = surface
                p[index].force = force
                p[index].sustain = sustain
            }
        }
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

    /// Trigger a voice with orbital coupling state.
    mutating func triggerWithOrbitalState(voiceIndex: Int, velocity: Double,
                                          orbitalSpeed: Double, orbitalStress: Double) {
        switch voiceIndex {
        case 0: voices.0.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 1: voices.1.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 2: voices.2.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 3: voices.3.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 4: voices.4.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 5: voices.5.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 6: voices.6.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        case 7: voices.7.trigger(velocity: velocity, orbitalSpeed: orbitalSpeed, orbitalStress: orbitalStress)
        default: break
        }
    }

    /// Render one sample: sum all 8 voices (manually unrolled) with soft limiting.
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
        // Soft limit the mix
        return tanhf(mix * 0.5)
    }

    /// Deactivate all voices.
    mutating func allNotesOff() {
        // Voices are one-shot; just let them decay
    }
}

// MARK: - NoteReceiver Conformance

extension QuakeVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // Ignore frequency — quake voices use their own regime freqs
        trigger(pitch: pitch, velocity: velocity)
    }

    mutating func noteOff(pitch: Int) {
        // Drums are one-shot — note-off is a no-op
    }
}
