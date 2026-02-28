import Foundation

/// Utility for converting between linear amplitude, dB, and fader position.
enum VolumeConversion {
    /// Convert linear amplitude (0–1+) to decibels.
    /// Returns `-Double.infinity` for 0.
    static func linearToDb(_ linear: Double) -> Double {
        guard linear > 0 else { return -.infinity }
        return 20.0 * log10(linear)
    }

    /// Convert decibels to linear amplitude.
    /// Returns 0 for values below -120dB.
    static func dbToLinear(_ db: Double) -> Double {
        guard db > -120 else { return 0 }
        return pow(10.0, db / 20.0)
    }

    /// Convert fader position (0–1) to dB using a piecewise curve.
    ///
    /// - `0.0`        → -∞ (silence)
    /// - `0.0–0.05`   → dead zone (silence)
    /// - `0.05–0.75`  → -60dB to 0dB (linear in dB)
    /// - `0.75–1.0`   → 0dB to +6dB (headroom)
    static func faderToDb(_ position: Double) -> Double {
        let p = max(0, min(1, position))
        if p < 0.05 { return -.infinity }
        if p <= 0.75 {
            // Map [0.05, 0.75] → [-60, 0] dB
            let t = (p - 0.05) / (0.75 - 0.05)
            return -60.0 + t * 60.0
        }
        // Map [0.75, 1.0] → [0, +6] dB
        let t = (p - 0.75) / (1.0 - 0.75)
        return t * 6.0
    }

    /// Convert dB to fader position (0–1). Inverse of `faderToDb`.
    static func dbToFader(_ db: Double) -> Double {
        if db <= -60 || db == -.infinity { return 0 }
        if db <= 0 {
            // Map [-60, 0] → [0.05, 0.75]
            let t = (db + 60.0) / 60.0
            return 0.05 + t * (0.75 - 0.05)
        }
        // Map [0, +6] → [0.75, 1.0]
        let t = min(db / 6.0, 1.0)
        return 0.75 + t * (1.0 - 0.75)
    }

    /// Convert fader position to linear amplitude.
    static func faderToLinear(_ position: Double) -> Double {
        let db = faderToDb(position)
        return dbToLinear(db)
    }

    /// Convert linear amplitude to fader position.
    static func linearToFader(_ linear: Double) -> Double {
        let db = linearToDb(linear)
        return dbToFader(db)
    }

    /// Format dB value for display. Returns "-∞" for silence.
    static func formatDb(_ db: Double) -> String {
        if db == -.infinity || db < -60 { return "-∞" }
        if abs(db) < 0.1 { return "0.0" }
        if db > 0 { return String(format: "+%.1f", db) }
        return String(format: "%.1f", db)
    }
}
