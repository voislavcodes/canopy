import Foundation

/// MIDI note number and frequency conversion utilities.
/// All functions are pure and safe for audio-thread use.
enum MIDIUtilities {
    /// A4 reference frequency in Hz
    static let a4Frequency: Double = 440.0

    /// A4 MIDI note number
    static let a4NoteNumber: Int = 69

    /// Converts a MIDI note number (0-127) to frequency in Hz.
    /// Uses equal temperament tuning: f = 440 * 2^((note - 69) / 12)
    static func frequency(forNote note: Int) -> Double {
        a4Frequency * pow(2.0, Double(note - a4NoteNumber) / 12.0)
    }

    /// Converts a frequency in Hz to the nearest MIDI note number.
    static func noteNumber(forFrequency frequency: Double) -> Int {
        guard frequency > 0 else { return 0 }
        return a4NoteNumber + Int(round(12.0 * log2(frequency / a4Frequency)))
    }

    /// Converts detune in cents to a frequency ratio.
    /// 100 cents = 1 semitone, so ratio = 2^(cents/1200)
    static func detuneRatio(cents: Double) -> Double {
        pow(2.0, cents / 1200.0)
    }

    /// Applies detune in cents to a base frequency.
    static func detunedFrequency(base: Double, cents: Double) -> Double {
        base * detuneRatio(cents: cents)
    }

    /// Note name for display (e.g., "C4", "F#5")
    static func noteName(forNote note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (note / 12) - 1
        let nameIndex = note % 12
        return "\(names[nameIndex])\(octave)"
    }
}
