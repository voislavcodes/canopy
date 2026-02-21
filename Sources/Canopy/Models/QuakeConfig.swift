import Foundation

/// Per-voice physics controls for a single QUAKE drum slot.
struct QuakeVoiceSlot: Codable, Equatable {
    var mass: Double       // 0–1: body mass — freq scaling, pitch sweep, noise cutoff
    var surface: Double    // 0–1: surface material — FM index, ratio bend, noise blend
    var force: Double      // 0–1: impact force — attack, noise burst, saturation, sweep boost
    var sustain: Double    // 0–1: resonance sustain — decay time, body Q, tail, drone mode

    init(mass: Double = 0.5, surface: Double = 0.3, force: Double = 0.5, sustain: Double = 0.3) {
        self.mass = mass
        self.surface = surface
        self.force = force
        self.sustain = sustain
    }
}

/// QUAKE engine: physics-based percussion synthesizer.
/// Each of the 8 drum voices has independent Mass/Surface/Force/Sustain controls
/// that modulate the underlying regime parameters for that voice slot.
struct QuakeConfig: Codable, Equatable {
    /// Per-voice physics controls (8 slots).
    var voices: [QuakeVoiceSlot]

    // Output
    var volume: Double      // 0–1
    var pan: Double         // -1 to +1

    init(
        voices: [QuakeVoiceSlot]? = nil,
        volume: Double = 0.8,
        pan: Double = 0.0
    ) {
        self.voices = voices ?? Self.defaultVoices
        self.volume = volume
        self.pan = pan
    }

    /// Default per-voice controls — balanced starting point for each regime.
    static let defaultVoices: [QuakeVoiceSlot] = [
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // KICK
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // SNARE
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // C.HAT
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // O.HAT
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // TOM L
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // TOM H
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // CRASH
        QuakeVoiceSlot(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3),  // RIDE
    ]

    // MARK: - Backward-compatible decoding

    private enum CodingKeys: String, CodingKey {
        case voices, volume, pan
        // Legacy keys for shared-control format
        case mass, surface, force, sustain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0

        if let v = try container.decodeIfPresent([QuakeVoiceSlot].self, forKey: .voices) {
            // New per-voice format
            voices = v
            // Pad to 8 if needed
            while voices.count < 8 { voices.append(QuakeVoiceSlot()) }
        } else {
            // Legacy shared-control format: read single mass/surface/force/sustain
            let mass = try container.decodeIfPresent(Double.self, forKey: .mass) ?? 0.5
            let surface = try container.decodeIfPresent(Double.self, forKey: .surface) ?? 0.3
            let force = try container.decodeIfPresent(Double.self, forKey: .force) ?? 0.5
            let sustain = try container.decodeIfPresent(Double.self, forKey: .sustain) ?? 0.3
            let shared = QuakeVoiceSlot(mass: mass, surface: surface, force: force, sustain: sustain)
            voices = Array(repeating: shared, count: 8)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voices, forKey: .voices)
        try container.encode(volume, forKey: .volume)
        try container.encode(pan, forKey: .pan)
    }

    // MARK: - Preset Seeds

    /// Helper to create a config with all voices sharing the same controls.
    private static func shared(mass: Double, surface: Double, force: Double, sustain: Double) -> QuakeConfig {
        let slot = QuakeVoiceSlot(mass: mass, surface: surface, force: force, sustain: sustain)
        return QuakeConfig(voices: Array(repeating: slot, count: 8))
    }

    /// Balanced starting point. Clean analog-style kit.
    static let cleanKit = shared(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3)
    /// Deep sub kick, crispy hats, long tails. The classic.
    static let eightOhEight = shared(mass: 0.7, surface: 0.2, force: 0.4, sustain: 0.6)
    /// Heavy mass, hard surface, maximum force. Clangs and thuds.
    static let industrial = shared(mass: 0.8, surface: 0.7, force: 0.9, sustain: 0.2)
    /// Low mass, smooth surface. Crystal-clear transients.
    static let glassy = shared(mass: 0.2, surface: 0.1, force: 0.3, sustain: 0.4)
    /// Mid mass, natural surface. Organic hand percussion.
    static let tribal = shared(mass: 0.6, surface: 0.4, force: 0.6, sustain: 0.3)
    /// Tight, precise, mechanical. Short decays.
    static let machine = shared(mass: 0.4, surface: 0.5, force: 0.7, sustain: 0.1)
    /// Bell-like resonances. High surface, moderate sustain.
    static let gamelan = shared(mass: 0.3, surface: 0.8, force: 0.4, sustain: 0.5)
    /// Maximum mass, high force. Deep booming impacts.
    static let thunder = shared(mass: 0.9, surface: 0.3, force: 0.8, sustain: 0.7)
    /// Minimum force, low mass. Gentle ghost notes.
    static let whisper = shared(mass: 0.2, surface: 0.2, force: 0.1, sustain: 0.3)
    /// High sustain pushes into drone territory. Self-sustaining resonance.
    static let droneKit = shared(mass: 0.5, surface: 0.4, force: 0.3, sustain: 0.9)
}
