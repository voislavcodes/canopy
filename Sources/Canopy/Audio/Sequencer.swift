import Foundation

/// A note event for the sequencer to schedule, derived from NoteSequence.
struct SequencerEvent {
    let pitch: Int
    let velocity: Double
    let startBeat: Double
    let endBeat: Double  // startBeat + duration
}

/// Audio-thread sequencer that advances a beat clock sample-by-sample
/// and triggers noteOn/noteOff events from a loaded sequence.
///
/// This struct is owned by the AudioEngine render callback.
/// All mutation happens on the audio thread — no locks needed.
struct Sequencer {
    var bpm: Double = 120
    var currentBeat: Double = 0
    var isPlaying: Bool = false

    private var events: [SequencerEvent] = []
    private var lengthInBeats: Double = 16

    // Track which events have been triggered this loop cycle
    // to avoid double-triggering. Reset on loop wrap.
    private var triggeredOnFlags: [Bool] = []
    private var triggeredOffFlags: [Bool] = []

    /// Load a sequence of events. Safe to call from main thread
    /// when sequencer is stopped.
    mutating func load(events: [SequencerEvent], lengthInBeats: Double) {
        self.events = events
        self.lengthInBeats = max(lengthInBeats, 1)
        self.triggeredOnFlags = Array(repeating: false, count: events.count)
        self.triggeredOffFlags = Array(repeating: false, count: events.count)
    }

    /// Start playback from beat 0.
    mutating func start(bpm: Double) {
        self.bpm = bpm
        self.currentBeat = 0
        self.isPlaying = true
        resetFlags()
    }

    /// Stop playback.
    mutating func stop() {
        isPlaying = false
        currentBeat = 0
    }

    /// Advance the beat clock by one sample and trigger any pending events.
    /// Called from the audio render callback per sample frame.
    mutating func advanceOneSample(sampleRate: Double, voices: inout VoiceManager, detune: Double) {
        guard isPlaying else { return }

        let beatsPerSample = bpm / (60.0 * sampleRate)

        currentBeat += beatsPerSample

        // Check for loop wrap
        if currentBeat >= lengthInBeats {
            // Trigger any remaining note-offs before wrapping
            for i in 0..<events.count {
                if triggeredOnFlags[i] && !triggeredOffFlags[i] {
                    voices.noteOff(pitch: events[i].pitch)
                    triggeredOffFlags[i] = true
                }
            }
            currentBeat -= lengthInBeats
            resetFlags()
        }

        // Check note events — flags prevent double-triggering within a cycle
        for i in 0..<events.count {
            let event = events[i]

            // Note on: trigger once we've reached the start beat
            if !triggeredOnFlags[i] && currentBeat >= event.startBeat {
                let freq = MIDIUtilities.detunedFrequency(
                    base: MIDIUtilities.frequency(forNote: event.pitch),
                    cents: detune
                )
                voices.noteOn(pitch: event.pitch, velocity: event.velocity, frequency: freq)
                triggeredOnFlags[i] = true
            }

            // Note off: trigger once we've reached the end beat
            if triggeredOnFlags[i] && !triggeredOffFlags[i] && currentBeat >= event.endBeat {
                voices.noteOff(pitch: event.pitch)
                triggeredOffFlags[i] = true
            }
        }
    }

    private mutating func resetFlags() {
        for i in 0..<triggeredOnFlags.count {
            triggeredOnFlags[i] = false
            triggeredOffFlags[i] = false
        }
    }
}
