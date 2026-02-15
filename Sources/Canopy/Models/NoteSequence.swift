import Foundation

struct NoteEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var pitch: Int        // MIDI note number 0-127
    var velocity: Double  // 0.0-1.0
    var startBeat: Double
    var duration: Double  // in beats
    /// Probability this note fires on each cycle (0.0-1.0).
    var probability: Double
    /// Number of rapid hits within this step (1=normal, 2-4=subdivide).
    var ratchetCount: Int

    init(
        id: UUID = UUID(),
        pitch: Int,
        velocity: Double = 0.8,
        startBeat: Double,
        duration: Double = 1.0,
        probability: Double = 1.0,
        ratchetCount: Int = 1
    ) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.duration = duration
        self.probability = probability
        self.ratchetCount = ratchetCount
    }

    // Backward-compatible decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pitch = try container.decode(Int.self, forKey: .pitch)
        velocity = try container.decode(Double.self, forKey: .velocity)
        startBeat = try container.decode(Double.self, forKey: .startBeat)
        duration = try container.decode(Double.self, forKey: .duration)
        probability = try container.decodeIfPresent(Double.self, forKey: .probability) ?? 1.0
        ratchetCount = try container.decodeIfPresent(Int.self, forKey: .ratchetCount) ?? 1
    }
}

// MARK: - Euclidean Config

struct EuclideanConfig: Codable, Equatable {
    var pulses: Int
    var rotation: Int

    init(pulses: Int = 4, rotation: Int = 0) {
        self.pulses = pulses
        self.rotation = rotation
    }
}

// MARK: - Pitch Range

struct PitchRange: Codable, Equatable {
    var low: Int
    var high: Int

    init(low: Int = 48, high: Int = 72) {
        self.low = low
        self.high = high
    }
}

// MARK: - Playback Direction

enum PlaybackDirection: String, Codable, Equatable, CaseIterable {
    case forward
    case reverse
    case pingPong
    case random
    case brownian
}

// MARK: - Mutation Config

struct MutationConfig: Codable, Equatable {
    /// Probability per note per cycle that it mutates (0-1).
    var amount: Double
    /// Maximum scale degrees a note can drift per mutation.
    var range: Int

    init(amount: Double = 0.1, range: Int = 1) {
        self.amount = amount
        self.range = range
    }
}

// MARK: - Accumulator Config

enum AccumulatorTarget: String, Codable, Equatable, CaseIterable {
    case pitch
    case velocity
    case probability
}

enum AccumulatorMode: String, Codable, Equatable, CaseIterable {
    case clamp
    case wrap
    case pingPong
}

struct AccumulatorConfig: Codable, Equatable {
    var target: AccumulatorTarget
    var amount: Double
    var limit: Double
    var mode: AccumulatorMode

    init(target: AccumulatorTarget = .pitch, amount: Double = 1.0, limit: Double = 12.0, mode: AccumulatorMode = .clamp) {
        self.target = target
        self.amount = amount
        self.limit = limit
        self.mode = mode
    }
}

// MARK: - Arp Config

enum ArpMode: String, Codable, Equatable, CaseIterable {
    case up
    case down
    case upDown
    case downUp
    case random
    case asPlayed
}

enum ArpRate: String, Codable, Equatable, CaseIterable {
    case whole
    case half
    case quarter
    case eighth
    case sixteenth
    case thirtySecond
    case tripletEighth
    case tripletSixteenth

    /// How many beats each arp step lasts.
    var beatsPerStep: Double {
        switch self {
        case .whole: return 4.0
        case .half: return 2.0
        case .quarter: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        case .thirtySecond: return 0.125
        case .tripletEighth: return 1.0 / 3.0
        case .tripletSixteenth: return 1.0 / 6.0
        }
    }
}

struct ArpConfig: Codable, Equatable {
    var mode: ArpMode
    var rate: ArpRate
    var octaveRange: Int
    var gateLength: Double

    init(mode: ArpMode = .up, rate: ArpRate = .sixteenth, octaveRange: Int = 1, gateLength: Double = 0.5) {
        self.mode = mode
        self.rate = rate
        self.octaveRange = octaveRange
        self.gateLength = gateLength
    }
}

// MARK: - Note Sequence

struct NoteSequence: Codable, Equatable {
    /// Duration of one grid step in beats. 0.25 = 16th note.
    static let stepDuration: Double = 0.25

    var notes: [NoteEvent]
    var lengthInBeats: Double
    /// Global probability multiplier for all notes in this sequence (0.0-1.0).
    var globalProbability: Double
    /// Euclidean rhythm configuration. nil = manual pattern.
    var euclidean: EuclideanConfig?
    /// Pitch range for random/euclidean fills. nil = default 48...72.
    var pitchRange: PitchRange?
    /// Playback step order. nil = forward.
    var playbackDirection: PlaybackDirection?
    /// Pitch mutation configuration. nil = no mutation.
    var mutation: MutationConfig?
    /// Per-cycle accumulator. nil = no accumulation.
    var accumulator: AccumulatorConfig?
    /// Arpeggiator configuration. nil = normal step sequencer, non-nil = arp mode.
    var arpConfig: ArpConfig?

    init(
        notes: [NoteEvent] = [],
        lengthInBeats: Double = 4,
        globalProbability: Double = 1.0,
        euclidean: EuclideanConfig? = nil,
        pitchRange: PitchRange? = nil,
        playbackDirection: PlaybackDirection? = nil,
        mutation: MutationConfig? = nil,
        accumulator: AccumulatorConfig? = nil,
        arpConfig: ArpConfig? = nil
    ) {
        self.notes = notes
        self.lengthInBeats = lengthInBeats
        self.globalProbability = globalProbability
        self.euclidean = euclidean
        self.pitchRange = pitchRange
        self.playbackDirection = playbackDirection
        self.mutation = mutation
        self.accumulator = accumulator
        self.arpConfig = arpConfig
    }

    // Backward-compatible decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = try container.decode([NoteEvent].self, forKey: .notes)
        lengthInBeats = try container.decode(Double.self, forKey: .lengthInBeats)
        globalProbability = try container.decodeIfPresent(Double.self, forKey: .globalProbability) ?? 1.0
        euclidean = try container.decodeIfPresent(EuclideanConfig.self, forKey: .euclidean)
        pitchRange = try container.decodeIfPresent(PitchRange.self, forKey: .pitchRange)
        playbackDirection = try container.decodeIfPresent(PlaybackDirection.self, forKey: .playbackDirection)
        mutation = try container.decodeIfPresent(MutationConfig.self, forKey: .mutation)
        accumulator = try container.decodeIfPresent(AccumulatorConfig.self, forKey: .accumulator)
        arpConfig = try container.decodeIfPresent(ArpConfig.self, forKey: .arpConfig)
    }
}
