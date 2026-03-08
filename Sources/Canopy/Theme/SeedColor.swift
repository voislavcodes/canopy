import SwiftUI

/// 15-anchor color palette for tree identity, with two-tier deterministic drift.
/// Tier 1: Tree seed drifts from its anchor → unique per-tree color.
/// Tier 2: Child branches drift from the seed's color → unique per-branch shades.
enum SeedColor {

    // MARK: - Anchor Enum

    enum SeedAnchor: Int, Codable, CaseIterable, Equatable {
        // Cool
        case slate = 0, frost, teal
        // Green
        case canopy, moss, sage, lichen
        // Warm
        case gold, copper, bark, berry, terra
        // Violet
        case nightshade, thistle
        // Neutral
        case ash
    }

    // MARK: - Anchor HSL Table

    /// Returns the anchor HSL values (hue 0–360, saturation 0–1, lightness 0–1).
    static func anchorHSL(_ anchor: SeedAnchor) -> (h: Double, s: Double, l: Double) {
        switch anchor {
        case .slate:      return (214, 0.25, 0.64)
        case .frost:      return (219, 0.31, 0.73)
        case .teal:       return (180, 0.30, 0.52)
        case .canopy:     return (142, 0.69, 0.58)
        case .moss:       return (144, 0.68, 0.32)
        case .sage:       return (83,  0.78, 0.55)
        case .lichen:     return (85,  0.85, 0.35)
        case .gold:       return (45,  0.93, 0.47)
        case .copper:     return (26,  0.66, 0.48)
        case .bark:       return (35,  0.92, 0.33)
        case .berry:      return (330, 0.32, 0.55)
        case .terra:      return (9,   0.43, 0.56)
        case .nightshade: return (275, 0.28, 0.51)
        case .thistle:    return (285, 0.30, 0.67)
        case .ash:        return (95,  0.04, 0.41)
        }
    }

    // MARK: - HSL ↔ Color Conversion

    /// Convert HSL (h: 0–360, s: 0–1, l: 0–1) to SwiftUI Color.
    static func hslToColor(h: Double, s: Double, l: Double) -> Color {
        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hp = h / 60.0
        let x = c * (1.0 - abs(hp.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - c / 2.0

        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }

        return Color(red: r1 + m, green: g1 + m, blue: b1 + m)
    }

    /// Extract HSL from a SwiftUI Color. Returns (h: 0–360, s: 0–1, l: 0–1).
    static func colorToHSL(_ color: Color) -> (h: Double, s: Double, l: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Double(resolved.redComponent)
        let g = Double(resolved.greenComponent)
        let b = Double(resolved.blueComponent)

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        // Lightness
        let l = (maxC + minC) / 2.0

        guard delta > 0.0001 else {
            return (0, 0, l)
        }

        // Saturation
        let s = delta / (1.0 - abs(2.0 * l - 1.0))

        // Hue
        var h: Double
        if maxC == r {
            h = 60.0 * (((g - b) / delta).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == g {
            h = 60.0 * (((b - r) / delta) + 2.0)
        } else {
            h = 60.0 * (((r - g) / delta) + 4.0)
        }
        if h < 0 { h += 360.0 }

        return (h, min(1.0, s), l)
    }

    // MARK: - Seeded Random (Splitmix64)

    /// Deterministic PRNG: same seed always produces same output in [0, 1).
    static func seededRandom(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x = x ^ (x >> 31)
        return Double(x & 0x7FFFFFFFFFFFFFFF) / Double(Int64.max)
    }

    // MARK: - Tier 1: Tree Seed Drift

    /// Drift from a palette anchor for the tree's seed node.
    /// ±14° hue, ±18% sat, ±15% lit.
    static func driftedColor(anchor: SeedAnchor, seedId: Int) -> Color {
        let base = anchorHSL(anchor)
        let rH = seededRandom(seedId)
        let rS = seededRandom(seedId &+ 100)
        let rL = seededRandom(seedId &+ 200)

        let h = (base.h + (rH * 28.0 - 14.0)).truncatingRemainder(dividingBy: 360.0) + (base.h + (rH * 28.0 - 14.0) < 0 ? 360.0 : 0.0)
        let s = max(0.0, min(1.0, base.s + (rS * 0.36 - 0.18)))
        let l = max(0.15, min(0.85, base.l + (rL * 0.30 - 0.15)))

        return hslToColor(h: h, s: s, l: l)
    }

    /// Returns the drifted HSL for a tree seed (needed as base for tier-2 drift).
    static func driftedHSL(anchor: SeedAnchor, seedId: Int) -> (h: Double, s: Double, l: Double) {
        let base = anchorHSL(anchor)
        let rH = seededRandom(seedId)
        let rS = seededRandom(seedId &+ 100)
        let rL = seededRandom(seedId &+ 200)

        var h = base.h + (rH * 28.0 - 14.0)
        h = h.truncatingRemainder(dividingBy: 360.0)
        if h < 0 { h += 360.0 }
        let s = max(0.0, min(1.0, base.s + (rS * 0.36 - 0.18)))
        let l = max(0.15, min(0.85, base.l + (rL * 0.30 - 0.15)))

        return (h, s, l)
    }

    // MARK: - Tier 2: Branch Drift

    /// Drift from an arbitrary HSL base for child branches.
    /// ±15° hue, ±14% sat, ±12% lit — visible variety while staying in the seed's family.
    static func driftedColor(baseH: Double, baseS: Double, baseL: Double, seedId: Int) -> Color {
        let rH = seededRandom(seedId)
        let rS = seededRandom(seedId &+ 100)
        let rL = seededRandom(seedId &+ 200)

        var h = baseH + (rH * 30.0 - 15.0)
        h = h.truncatingRemainder(dividingBy: 360.0)
        if h < 0 { h += 360.0 }
        let s = max(0.0, min(1.0, baseS + (rS * 0.28 - 0.14)))
        let l = max(0.15, min(0.85, baseL + (rL * 0.24 - 0.12)))

        return hslToColor(h: h, s: s, l: l)
    }

    // MARK: - Butterfly Palette

    /// A 5-color palette derived from a single base color for multi-layer butterfly rendering.
    struct ButterflyPalette {
        let outerWing: Color    // Primary wing fill
        let innerWing: Color    // Inner wing spot/accent (shifted hue)
        let lowerWing: Color    // Lower wings (warmer/cooler shift)
        let vein: Color         // Wing edge detail (darker, desaturated)
        let body: Color         // Body + antennae (darkest)
    }

    /// Generates a 5-color butterfly palette from a single base color.
    /// Each slot gets a different HSL offset to create natural wing variation.
    static func butterflyPalette(from baseColor: Color) -> ButterflyPalette {
        let hsl = colorToHSL(baseColor)

        let outerWing = baseColor

        // innerWing: +45° hue, +15% sat, +10% lightness — distinct accent, visibly different
        var innerH = (hsl.h + 45.0).truncatingRemainder(dividingBy: 360.0)
        if innerH < 0 { innerH += 360.0 }
        let innerWing = hslToColor(
            h: innerH,
            s: min(1.0, hsl.s + 0.15),
            l: min(0.85, hsl.l + 0.10)
        )

        // lowerWing: -30° hue, +5% sat, -12% lightness — noticeably warmer/darker
        var lowerH = (hsl.h - 30.0).truncatingRemainder(dividingBy: 360.0)
        if lowerH < 0 { lowerH += 360.0 }
        let lowerWing = hslToColor(
            h: lowerH,
            s: min(1.0, hsl.s + 0.05),
            l: max(0.1, hsl.l - 0.12)
        )

        // vein: same hue, -30% sat, -25% lightness — desaturated dark
        let vein = hslToColor(
            h: hsl.h,
            s: max(0.0, hsl.s - 0.30),
            l: max(0.1, hsl.l - 0.25)
        )

        // body: same hue, -40% sat, -35% lightness — near-dark
        let body = hslToColor(
            h: hsl.h,
            s: max(0.0, hsl.s - 0.40),
            l: max(0.08, hsl.l - 0.35)
        )

        return ButterflyPalette(
            outerWing: outerWing,
            innerWing: innerWing,
            lowerWing: lowerWing,
            vein: vein,
            body: body
        )
    }

    // MARK: - Session Color

    /// A random color generated once per app launch, using the seed color palette.
    /// Each Canopy session gets a unique butterfly tint.
    static let sessionColor: Color = {
        let sessionId = deterministicSeedId(from: UUID())
        let anchorIndex = sessionId % SeedAnchor.allCases.count
        let anchor = SeedAnchor.allCases[anchorIndex]
        return driftedColor(anchor: anchor, seedId: sessionId)
    }()

    /// Session butterfly palette — derived from sessionColor, stable for the app's lifetime.
    static let sessionPalette: ButterflyPalette = butterflyPalette(from: sessionColor)

    // MARK: - Convenience: Color for Catch

    /// Returns a deterministic color for a catch (HarvestedLoop) from the full anchor palette.
    /// Same UUID always produces the same color across sessions.
    static func colorForCatch(_ catchId: UUID) -> Color {
        let seedId = deterministicSeedId(from: catchId)
        let anchorIndex = seedId % SeedAnchor.allCases.count
        let anchor = SeedAnchor.allCases[anchorIndex]
        return driftedColor(anchor: anchor, seedId: seedId)
    }

    /// Returns a deterministic butterfly palette for a catch.
    /// Same UUID always produces the same palette across sessions.
    static func paletteForCatch(_ catchId: UUID) -> ButterflyPalette {
        return butterflyPalette(from: colorForCatch(catchId))
    }

    // MARK: - Convenience: Color for Any Node

    /// Returns the resolved color for any node in a tree.
    /// Root node → tier-1 drift from anchor. Child node → tier-2 drift from seed's drifted HSL.
    static func colorForNode(_ nodeId: UUID, in tree: NodeTree) -> Color {
        if nodeId == tree.rootNode.id {
            return driftedColor(anchor: tree.anchor, seedId: tree.colorSeedId)
        }

        let baseHSL = driftedHSL(anchor: tree.anchor, seedId: tree.colorSeedId)
        let nodeSeed = deterministicSeedId(from: nodeId)
        return driftedColor(baseH: baseHSL.h, baseS: baseHSL.s, baseL: baseHSL.l, seedId: nodeSeed)
    }

    /// Derive a deterministic integer seed from a UUID (for stable color mapping).
    static func deterministicSeedId(from uuid: UUID) -> Int {
        let u = uuid.uuid
        let hash = Int(u.0) &+ Int(u.1) &* 31 &+ Int(u.2) &* 97 &+ Int(u.3) &* 127
            &+ Int(u.4) &* 251 &+ Int(u.5) &* 397 &+ Int(u.6) &* 521 &+ Int(u.7) &* 677
            &+ Int(u.8) &* 811 &+ Int(u.9) &* 947 &+ Int(u.10) &* 1087 &+ Int(u.11) &* 1223
            &+ Int(u.12) &* 1381 &+ Int(u.13) &* 1511 &+ Int(u.14) &* 1657 &+ Int(u.15) &* 1801
        return abs(hash) % 1_000_000
    }
}
