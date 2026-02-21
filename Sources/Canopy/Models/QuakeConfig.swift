import Foundation

/// QUAKE engine: physics-based percussion synthesizer.
/// One physical model generates all 8 drum voices through 4 shared controls.
/// Mass/Surface/Force/Sustain modulate the underlying regime parameters
/// for each voice slot, producing an entire kit from a single interface.
struct QuakeConfig: Codable, Equatable {
    // The four physics controls (all 0–1)
    var mass: Double        // 0–1: body mass — freq scaling, pitch sweep, noise cutoff
    var surface: Double     // 0–1: surface material — FM index, ratio bend, noise blend
    var force: Double       // 0–1: impact force — attack, noise burst, saturation, sweep boost
    var sustain: Double     // 0–1: resonance sustain — decay time, body Q, tail, drone mode

    // Output
    var volume: Double      // 0–1
    var pan: Double         // -1 to +1

    init(
        mass: Double = 0.5,
        surface: Double = 0.3,
        force: Double = 0.5,
        sustain: Double = 0.3,
        volume: Double = 0.8,
        pan: Double = 0.0
    ) {
        self.mass = mass
        self.surface = surface
        self.force = force
        self.sustain = sustain
        self.volume = volume
        self.pan = pan
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mass = try container.decode(Double.self, forKey: .mass)
        surface = try container.decode(Double.self, forKey: .surface)
        force = try container.decode(Double.self, forKey: .force)
        sustain = try container.decode(Double.self, forKey: .sustain)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0
    }

    // MARK: - Preset Seeds

    /// Balanced starting point. Clean analog-style kit.
    static let cleanKit = QuakeConfig(mass: 0.5, surface: 0.3, force: 0.5, sustain: 0.3)
    /// Deep sub kick, crispy hats, long tails. The classic.
    static let eightOhEight = QuakeConfig(mass: 0.7, surface: 0.2, force: 0.4, sustain: 0.6)
    /// Heavy mass, hard surface, maximum force. Clangs and thuds.
    static let industrial = QuakeConfig(mass: 0.8, surface: 0.7, force: 0.9, sustain: 0.2)
    /// Low mass, smooth surface. Crystal-clear transients.
    static let glassy = QuakeConfig(mass: 0.2, surface: 0.1, force: 0.3, sustain: 0.4)
    /// Mid mass, natural surface. Organic hand percussion.
    static let tribal = QuakeConfig(mass: 0.6, surface: 0.4, force: 0.6, sustain: 0.3)
    /// Tight, precise, mechanical. Short decays.
    static let machine = QuakeConfig(mass: 0.4, surface: 0.5, force: 0.7, sustain: 0.1)
    /// Bell-like resonances. High surface, moderate sustain.
    static let gamelan = QuakeConfig(mass: 0.3, surface: 0.8, force: 0.4, sustain: 0.5)
    /// Maximum mass, high force. Deep booming impacts.
    static let thunder = QuakeConfig(mass: 0.9, surface: 0.3, force: 0.8, sustain: 0.7)
    /// Minimum force, low mass. Gentle ghost notes.
    static let whisper = QuakeConfig(mass: 0.2, surface: 0.2, force: 0.1, sustain: 0.3)
    /// High sustain pushes into drone territory. Self-sustaining resonance.
    static let droneKit = QuakeConfig(mass: 0.5, surface: 0.4, force: 0.3, sustain: 0.9)
}
