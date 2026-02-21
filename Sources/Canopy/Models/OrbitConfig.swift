import Foundation

/// ORBIT sequencer: gravitational rhythm generator.
/// Bodies orbit a central point, triggering drum voices when crossing
/// beat-grid-anchored zones. Inter-body gravity creates elastic timing.
struct OrbitConfig: Codable, Equatable {
    var gravity: Double     // 0–1: inter-body gravitational attraction
    var bodyCount: Int      // 2–6: number of orbiting bodies
    var tension: Double     // 0–1: ratio complexity (simple integers → irrational ratios)
    var density: Double     // 0–1: trigger zone count per orbit (1 → 16)

    init(
        gravity: Double = 0.3,
        bodyCount: Int = 4,
        tension: Double = 0.0,
        density: Double = 0.5
    ) {
        self.gravity = gravity
        self.bodyCount = min(6, max(2, bodyCount))
        self.tension = tension
        self.density = density
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gravity = try container.decode(Double.self, forKey: .gravity)
        bodyCount = try container.decode(Int.self, forKey: .bodyCount)
        tension = try container.decode(Double.self, forKey: .tension)
        density = try container.decode(Double.self, forKey: .density)
    }

    // MARK: - Preset Seeds

    /// Strict timing. Minimal gravity. Clock-like.
    static let metronome = OrbitConfig(gravity: 0.0, bodyCount: 2, tension: 0.0, density: 0.25)
    /// Slight pull creates natural pocket feel.
    static let pocket = OrbitConfig(gravity: 0.2, bodyCount: 4, tension: 0.1, density: 0.5)
    /// Complex ratios, many bodies. Polyrhythmic web.
    static let poly = OrbitConfig(gravity: 0.3, bodyCount: 6, tension: 0.5, density: 0.5)
    /// High gravity, simple ratios. Rubber-band timing.
    static let elastic = OrbitConfig(gravity: 0.7, bodyCount: 3, tension: 0.1, density: 0.5)
    /// Many zones, many bodies. Dense triggering.
    static let dense = OrbitConfig(gravity: 0.2, bodyCount: 6, tension: 0.3, density: 0.9)
    /// Few zones, few bodies. Minimal and spacious.
    static let sparse = OrbitConfig(gravity: 0.1, bodyCount: 2, tension: 0.0, density: 0.0)
    /// Phase-music inspired. Simple ratios slowly drifting.
    static let reich = OrbitConfig(gravity: 0.05, bodyCount: 4, tension: 0.05, density: 0.5)
    /// Maximum complexity. All parameters high.
    static let chaos = OrbitConfig(gravity: 0.8, bodyCount: 6, tension: 0.9, density: 0.75)
    /// Moderate gravity, medium density. Ceremonial pulse.
    static let ritual = OrbitConfig(gravity: 0.4, bodyCount: 3, tension: 0.2, density: 0.5)
    /// Low gravity, complex ratios. Slowly evolving pattern.
    static let drift = OrbitConfig(gravity: 0.1, bodyCount: 5, tension: 0.7, density: 0.25)
}
