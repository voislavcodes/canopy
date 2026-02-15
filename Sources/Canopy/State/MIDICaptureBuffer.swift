import Foundation

/// A single completed note event captured from keyboard performance.
struct MIDIBufferEvent {
    var pitch: Int
    var velocity: Double
    var startBeat: Double
    var durationBeats: Double
}

/// How captured notes are written into a node's sequence.
enum CaptureMode {
    case replace
    case merge
}

/// Circular buffer that records keyboard note events as they are played.
/// Main-thread only, not persisted.
class MIDICaptureBuffer {
    /// Completed note events (noteOn matched with noteOff).
    private(set) var events: [MIDIBufferEvent] = []

    /// Tracks pending noteOn timestamps by pitch for duration calculation.
    private var pendingNoteOns: [Int: (beat: Double, velocity: Double)] = [:]

    /// Maximum age in beats before events are pruned.
    private let maxAgeBeat: Double = 128

    /// Record a note-on event.
    func noteOn(pitch: Int, velocity: Double, atBeat beat: Double) {
        pendingNoteOns[pitch] = (beat: beat, velocity: velocity)
    }

    /// Record a note-off event. Matches with pending noteOn, computes duration, appends to events.
    func noteOff(pitch: Int, atBeat beat: Double) {
        guard let pending = pendingNoteOns.removeValue(forKey: pitch) else { return }
        let duration = max(0.01, beat - pending.beat)
        events.append(MIDIBufferEvent(
            pitch: pitch,
            velocity: pending.velocity,
            startBeat: pending.beat,
            durationBeats: duration
        ))
        pruneOldEvents(currentBeat: beat)
    }

    /// Remove events older than maxAgeBeat from the most recent event.
    private func pruneOldEvents(currentBeat: Double) {
        let cutoff = currentBeat - maxAgeBeat
        events.removeAll { $0.startBeat < cutoff }
    }

    /// Clear all events and pending notes.
    func clear() {
        events.removeAll()
        pendingNoteOns.removeAll()
    }

    /// Whether there are any completed events in the buffer.
    var isEmpty: Bool {
        events.isEmpty
    }

    /// Number of completed events.
    var count: Int {
        events.count
    }
}
