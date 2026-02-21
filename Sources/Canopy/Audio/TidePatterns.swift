import Foundation

/// A single frame in a Tide pattern: 16 band levels and 16 band Q values,
/// plus spectral shaping hints.
/// Stored as inline tuples — no heap, no CoW, audio-thread safe.
struct TideFrame {
    /// Per-band amplitude levels (0–1). 16 bands from 75Hz to 16kHz.
    var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)
    /// Per-band Q values (0.5–8). Higher Q = narrower resonance.
    var qs: (Float, Float, Float, Float, Float, Float, Float, Float,
             Float, Float, Float, Float, Float, Float, Float, Float)
    /// Odd/even balance: -1 = odd bands only, 0 = equal, +1 = even bands only.
    var oddEvenBalance: Float
    /// Spectral tilt: -1 = bass-heavy, 0 = flat, +1 = treble-heavy.
    var spectralTilt: Float

    static func level(_ frame: TideFrame, at index: Int) -> Float {
        withUnsafePointer(to: frame.levels) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                p[index]
            }
        }
    }

    static func q(_ frame: TideFrame, at index: Int) -> Float {
        withUnsafePointer(to: frame.qs) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                p[index]
            }
        }
    }
}

/// 16 spectral animation patterns for the Tide engine.
/// Patterns 0–13 are deterministic frame sequences.
/// Patterns 14–15 are generative (chaos) and computed at runtime.
enum TidePatterns {
    static let patternCount = 17
    static let bandCount = 16

    /// Index for the Imprint pattern (frames stored externally on the voice manager).
    static let imprintPatternIndex = 16

    /// Pattern names for UI display.
    static let names: [String] = [
        "Rising Tide", "Falling Tide", "Ebb and Flow", "Spotlight", "Horizon",
        "Heartbeat", "Ping-Pong", "Cascade", "Staccato", "Syncopation",
        "Vowels", "Bells", "Fifths", "Octaves",
        "Wanderer", "Storm",
        "Imprint"
    ]

    // MARK: - Default Q (moderate resonance)

    private static let defaultQ: (Float, Float, Float, Float, Float, Float, Float, Float,
                                  Float, Float, Float, Float, Float, Float, Float, Float)
        = (2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5,
           2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5)

    private static let narrowQ: (Float, Float, Float, Float, Float, Float, Float, Float,
                                 Float, Float, Float, Float, Float, Float, Float, Float)
        = (5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0,
           5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0)

    // MARK: - Pattern Data

    /// Get frames for a given pattern index.
    /// Returns nil for chaos patterns (14, 15) which are generated at runtime.
    static func frames(for pattern: Int) -> [TideFrame]? {
        switch pattern {
        case 0: return risingTide
        case 1: return fallingTide
        case 2: return ebbAndFlow
        case 3: return spotlight
        case 4: return horizon
        case 5: return heartbeat
        case 6: return pingPong
        case 7: return cascade
        case 8: return staccato
        case 9: return syncopation
        case 10: return vowels
        case 11: return bells
        case 12: return fifths
        case 13: return octaves
        default: return nil // chaos patterns
        }
    }

    /// Whether this pattern is generative (non-repeating).
    static func isChaos(_ pattern: Int) -> Bool {
        pattern == 14 || pattern == 15
    }

    /// Whether this pattern uses externally-provided imprint frames.
    static func isImprint(_ pattern: Int) -> Bool {
        pattern == imprintPatternIndex
    }

    // MARK: - Sweep Patterns (0–4)

    /// 0: Rising Tide — bands activate low-to-high sequentially.
    private static let risingTide: [TideFrame] = (0..<8).map { step in
        var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &levels) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                let center = step * 2
                for i in 0..<16 {
                    let dist = abs(i - center)
                    p[i] = max(0, 1.0 - Float(dist) * 0.3)
                }
            }
        }
        return TideFrame(levels: levels, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0)
    }

    /// 1: Falling Tide — bands activate high-to-low.
    private static let fallingTide: [TideFrame] = risingTide.reversed()

    /// 2: Ebb and Flow — sweep up then back down.
    private static let ebbAndFlow: [TideFrame] = {
        let up = risingTide
        let down = Array(up.dropFirst().dropLast().reversed())
        return up + down
    }()

    /// 3: Spotlight — narrow peak sweeps across spectrum.
    private static let spotlight: [TideFrame] = (0..<16).map { step in
        var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &levels) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                for i in 0..<16 {
                    let dist = abs(i - step)
                    p[i] = dist == 0 ? 1.0 : (dist == 1 ? 0.4 : 0.05)
                }
            }
        }
        return TideFrame(levels: levels, qs: narrowQ, oddEvenBalance: 0, spectralTilt: 0)
    }

    /// 4: Horizon — slow broad sweep, bass and treble alternate.
    private static let horizon: [TideFrame] = (0..<8).map { step in
        var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let t = Float(step) / 7.0
        withUnsafeMutablePointer(to: &levels) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                for i in 0..<16 {
                    let norm = Float(i) / 15.0
                    // Crossfade between bass-heavy and treble-heavy
                    p[i] = (1.0 - t) * max(0, 1.0 - norm * 2) + t * max(0, norm * 2 - 1.0)
                    p[i] = max(0.05, p[i])
                }
            }
        }
        return TideFrame(levels: levels, qs: defaultQ, oddEvenBalance: 0, spectralTilt: t * 2 - 1)
    }

    // MARK: - Rhythmic Patterns (5–9)

    /// 5: Heartbeat — pulsing emphasis on low bands with occasional high splash.
    private static let heartbeat: [TideFrame] = {
        let baseline: (Float, Float, Float, Float, Float, Float, Float, Float,
                       Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.3, 0.2, 0.15, 0.1, 0.08, 0.05, 0.03, 0.02,
               0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02, 0.02)
        let pulse: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (1.0, 0.9, 0.7, 0.5, 0.3, 0.2, 0.1, 0.05,
               0.05, 0.05, 0.05, 0.1, 0.15, 0.2, 0.15, 0.1)
        return [
            TideFrame(levels: pulse, qs: defaultQ, oddEvenBalance: 0, spectralTilt: -0.5),
            TideFrame(levels: baseline, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: pulse, qs: defaultQ, oddEvenBalance: 0, spectralTilt: -0.3),
            TideFrame(levels: baseline, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: baseline, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: baseline, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
        ]
    }()

    /// 6: Ping-Pong — alternates between odd and even bands.
    private static let pingPong: [TideFrame] = {
        let odd: (Float, Float, Float, Float, Float, Float, Float, Float,
                  Float, Float, Float, Float, Float, Float, Float, Float)
            = (1.0, 0.05, 0.9, 0.05, 0.8, 0.05, 0.7, 0.05,
               0.6, 0.05, 0.5, 0.05, 0.4, 0.05, 0.3, 0.05)
        let even: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.05, 1.0, 0.05, 0.9, 0.05, 0.8, 0.05, 0.7,
               0.05, 0.6, 0.05, 0.5, 0.05, 0.4, 0.05, 0.3)
        return [
            TideFrame(levels: odd, qs: defaultQ, oddEvenBalance: -1, spectralTilt: 0),
            TideFrame(levels: even, qs: defaultQ, oddEvenBalance: 1, spectralTilt: 0),
        ]
    }()

    /// 7: Cascade — bands activate in rapid succession, top to bottom.
    private static let cascade: [TideFrame] = (0..<16).map { step in
        var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let pos = 15 - step // high to low
        withUnsafeMutablePointer(to: &levels) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                p[pos] = 1.0
                if pos > 0 { p[pos - 1] = 0.5 }
                if pos < 15 { p[pos + 1] = 0.3 }
                // Leave a trail
                for i in (pos + 1)..<16 {
                    let trail = Float(i - pos)
                    p[i] = max(p[i], 0.2 * max(0, 1.0 - trail * 0.15))
                }
            }
        }
        return TideFrame(levels: levels, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0)
    }

    /// 8: Staccato — short bursts of full spectrum, then silence.
    private static let staccato: [TideFrame] = {
        let full: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6, 0.55,
               0.5, 0.45, 0.4, 0.35, 0.3, 0.25, 0.2, 0.15)
        let quiet: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05,
               0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05)
        return [
            TideFrame(levels: full, qs: defaultQ, oddEvenBalance: 0, spectralTilt: -0.3),
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
        ]
    }()

    /// 9: Syncopation — accent on off-beats with varied spectral content.
    private static let syncopation: [TideFrame] = {
        let accent1: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.1, 0.2, 0.8, 0.9, 1.0, 0.9, 0.8, 0.2,
               0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1)
        let quiet: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05,
               0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05)
        let accent2: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1,
               0.2, 0.5, 0.8, 1.0, 0.8, 0.5, 0.2, 0.1)
        return [
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: accent1, qs: defaultQ, oddEvenBalance: 0, spectralTilt: -0.3),
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: accent2, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0.3),
            TideFrame(levels: quiet, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: accent1, qs: defaultQ, oddEvenBalance: 0, spectralTilt: 0),
        ]
    }()

    // MARK: - Harmonic Patterns (10–13)

    /// 10: Vowels — cycles through formant-like configurations.
    private static let vowels: [TideFrame] = {
        // Approximate formant positions mapped to our 16 bands (75Hz–16kHz log-spaced)
        // "ah" — low formants (bands 2-3, 6-7)
        let ah: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.3, 0.5, 1.0, 0.8, 0.2, 0.3, 0.9, 0.7,
               0.2, 0.1, 0.1, 0.05, 0.05, 0.05, 0.05, 0.05)
        // "ee" — mid-high formants (bands 1-2, 9-10)
        let ee: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.4, 0.9, 0.7, 0.1, 0.1, 0.1, 0.1, 0.1,
               0.3, 1.0, 0.8, 0.3, 0.1, 0.05, 0.05, 0.05)
        // "oo" — low formants only (bands 1-2)
        let oo: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.6, 1.0, 0.9, 0.3, 0.1, 0.05, 0.05, 0.05,
               0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05)
        // "eh" — spread formants (bands 2-4, 7-8)
        let eh: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.2, 0.6, 1.0, 0.9, 0.6, 0.2, 0.4, 0.8,
               0.6, 0.2, 0.1, 0.05, 0.05, 0.05, 0.05, 0.05)
        let formantQ: (Float, Float, Float, Float, Float, Float, Float, Float,
                       Float, Float, Float, Float, Float, Float, Float, Float)
            = (3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0,
               3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0, 3.0)
        return [
            TideFrame(levels: ah, qs: formantQ, oddEvenBalance: 0, spectralTilt: -0.2),
            TideFrame(levels: ee, qs: formantQ, oddEvenBalance: 0, spectralTilt: 0.2),
            TideFrame(levels: oo, qs: formantQ, oddEvenBalance: 0, spectralTilt: -0.5),
            TideFrame(levels: eh, qs: formantQ, oddEvenBalance: 0, spectralTilt: 0),
        ]
    }()

    /// 11: Bells — emphasizes harmonically-related bands with sharp Q.
    private static let bells: [TideFrame] = {
        let bellQ: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0,
               6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0)
        // Strike 1 — fundamental + odd harmonics
        let strike1: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)
            = (1.0, 0.05, 0.7, 0.05, 0.5, 0.05, 0.4, 0.05,
               0.3, 0.05, 0.2, 0.05, 0.15, 0.05, 0.1, 0.05)
        // Ring — decay to mid harmonics
        let ring: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.3, 0.1, 0.5, 0.2, 0.7, 0.3, 0.5, 0.2,
               0.3, 0.1, 0.15, 0.05, 0.1, 0.05, 0.05, 0.05)
        // Shimmer — high partials
        let shimmer: (Float, Float, Float, Float, Float, Float, Float, Float,
                      Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.1, 0.05, 0.15, 0.1, 0.2, 0.15, 0.3, 0.25,
               0.5, 0.4, 0.6, 0.3, 0.2, 0.1, 0.05, 0.05)
        let decay: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.05, 0.05, 0.1, 0.05, 0.1, 0.05, 0.15, 0.1,
               0.2, 0.15, 0.1, 0.05, 0.05, 0.05, 0.05, 0.05)
        return [
            TideFrame(levels: strike1, qs: bellQ, oddEvenBalance: -0.3, spectralTilt: -0.3),
            TideFrame(levels: ring, qs: bellQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: shimmer, qs: bellQ, oddEvenBalance: 0.2, spectralTilt: 0.4),
            TideFrame(levels: decay, qs: bellQ, oddEvenBalance: 0, spectralTilt: 0.2),
        ]
    }()

    /// 12: Fifths — emphasizes bands at ~perfect fifth intervals.
    private static let fifths: [TideFrame] = {
        // Bands 0,4,7,11 approximate fifths in log-frequency space
        let root: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
            = (1.0, 0.1, 0.1, 0.1, 0.8, 0.1, 0.1, 0.6,
               0.1, 0.1, 0.1, 0.4, 0.1, 0.1, 0.1, 0.2)
        let fifth: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.2, 0.1, 0.1, 0.1, 1.0, 0.1, 0.1, 0.8,
               0.1, 0.1, 0.1, 0.6, 0.1, 0.1, 0.1, 0.4)
        return [
            TideFrame(levels: root, qs: narrowQ, oddEvenBalance: 0, spectralTilt: -0.2),
            TideFrame(levels: fifth, qs: narrowQ, oddEvenBalance: 0, spectralTilt: 0.1),
        ]
    }()

    /// 13: Octaves — emphasizes octave-spaced bands.
    private static let octaves: [TideFrame] = {
        // Bands 0,3,6,9,12,15 are roughly octave-spaced
        let low: (Float, Float, Float, Float, Float, Float, Float, Float,
                  Float, Float, Float, Float, Float, Float, Float, Float)
            = (1.0, 0.05, 0.05, 0.8, 0.05, 0.05, 0.6, 0.05,
               0.05, 0.4, 0.05, 0.05, 0.2, 0.05, 0.05, 0.1)
        let high: (Float, Float, Float, Float, Float, Float, Float, Float,
                   Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.1, 0.05, 0.05, 0.2, 0.05, 0.05, 0.4, 0.05,
               0.05, 0.6, 0.05, 0.05, 0.8, 0.05, 0.05, 1.0)
        let mid: (Float, Float, Float, Float, Float, Float, Float, Float,
                  Float, Float, Float, Float, Float, Float, Float, Float)
            = (0.3, 0.05, 0.05, 0.5, 0.05, 0.05, 1.0, 0.05,
               0.05, 0.7, 0.05, 0.05, 0.5, 0.05, 0.05, 0.3)
        return [
            TideFrame(levels: low, qs: narrowQ, oddEvenBalance: 0, spectralTilt: -0.5),
            TideFrame(levels: mid, qs: narrowQ, oddEvenBalance: 0, spectralTilt: 0),
            TideFrame(levels: high, qs: narrowQ, oddEvenBalance: 0, spectralTilt: 0.5),
            TideFrame(levels: mid, qs: narrowQ, oddEvenBalance: 0, spectralTilt: 0),
        ]
    }()

    // NOTE: Patterns 14 (Wanderer) and 15 (Storm) are generative —
    // computed per control block in TideVoice using noise state.
}
