import Foundation

/// Manages a fixed pool of polyphonic voices.
/// All methods are designed for audio-thread use unless noted otherwise.
struct VoiceManager {
    static let voiceCount = 16

    /// Each voice tracks which MIDI pitch it's playing (or -1 if free).
    var voices: [OscillatorRenderer]
    var voicePitches: [Int]  // MIDI note per voice, -1 = free

    init() {
        voices = Array(repeating: OscillatorRenderer(), count: Self.voiceCount)
        voicePitches = Array(repeating: -1, count: Self.voiceCount)
    }

    /// Allocate a voice for a note-on event. Uses voice stealing (oldest active) if all voices are busy.
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // First: reuse a voice already playing this pitch
        for i in 0..<Self.voiceCount {
            if voicePitches[i] == pitch {
                voices[i].noteOn(frequency: frequency, velocity: velocity)
                return
            }
        }

        // Second: find an idle voice
        for i in 0..<Self.voiceCount {
            if !voices[i].isActive {
                voicePitches[i] = pitch
                voices[i].noteOn(frequency: frequency, velocity: velocity)
                return
            }
        }

        // Third: steal the voice with the lowest envelope level (quietest)
        var quietest = 0
        var lowestLevel = voices[0].envelopeLevel
        for i in 1..<Self.voiceCount {
            if voices[i].envelopeLevel < lowestLevel {
                lowestLevel = voices[i].envelopeLevel
                quietest = i
            }
        }
        voicePitches[quietest] = pitch
        voices[quietest].noteOn(frequency: frequency, velocity: velocity)
    }

    /// Release a voice playing a specific pitch.
    mutating func noteOff(pitch: Int) {
        for i in 0..<Self.voiceCount {
            if voicePitches[i] == pitch && voices[i].isActive {
                voices[i].noteOff()
                // Don't clear voicePitches yet — voice is still in release phase
                return
            }
        }
    }

    /// Release all voices immediately.
    mutating func allNotesOff() {
        for i in 0..<Self.voiceCount {
            voices[i].noteOff()
        }
    }

    /// Configure all voices with updated patch parameters.
    mutating func configurePatch(waveform: Int, detune: Double, attack: Double, decay: Double, sustain: Double, release: Double, sampleRate: Double) {
        for i in 0..<Self.voiceCount {
            voices[i].waveform = waveform
            voices[i].configureEnvelope(attack: attack, decay: decay, sustain: sustain, release: release, sampleRate: sampleRate)
        }
    }

    /// Render all active voices and mix to a single sample.
    mutating func renderSample(sampleRate: Double) -> Float {
        var mix: Float = 0
        for i in 0..<Self.voiceCount {
            if voices[i].isActive {
                mix += voices[i].renderSample(sampleRate: sampleRate)
            }
            // Clear pitch assignment when voice finishes release
            if !voices[i].isActive && voicePitches[i] != -1 {
                voicePitches[i] = -1
            }
        }
        return mix
    }
}
