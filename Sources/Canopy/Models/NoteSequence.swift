import Foundation

struct NoteEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var pitch: Int        // MIDI note number 0-127
    var velocity: Double  // 0.0-1.0
    var startBeat: Double
    var duration: Double  // in beats

    init(id: UUID = UUID(), pitch: Int, velocity: Double = 0.8, startBeat: Double, duration: Double = 1.0) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.duration = duration
    }
}

struct NoteSequence: Codable, Equatable {
    var notes: [NoteEvent]
    var lengthInBeats: Double

    init(notes: [NoteEvent] = [], lengthInBeats: Double = 16) {
        self.notes = notes
        self.lengthInBeats = lengthInBeats
    }
}
