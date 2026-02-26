import Foundation

/// Describes a musical transformation applied to create a new tree from an existing one.
enum VariationType: Codable, Equatable {
    // PITCH
    case transpose(semitones: Int)
    case invert(pivot: Int)
    case fifth(targetRoot: PitchClass)

    // RHYTHM
    case density(amount: Double)
    case mirror
    case rotate(steps: Int)
    case euclideanRefill(hits: Int, steps: Int, rotation: Int)

    // MELODY
    case bloom(amount: Double)
    case drift(ticks: Double)
    case scramble(seed: UInt64)

    // CHARACTER
    case human(amount: Double)
    case mutate(amount: Double, range: Int)
    case engineSwap(soundType: SoundType)

    // COMPOSITE
    case surprise(variations: [VariationType])

    /// Short display name for UI.
    var displayName: String {
        switch self {
        case .transpose: return "Transpose"
        case .invert: return "Invert"
        case .fifth: return "Fifth"
        case .density: return "Density"
        case .mirror: return "Mirror"
        case .rotate: return "Rotate"
        case .euclideanRefill: return "Euclidean"
        case .bloom: return "Bloom"
        case .drift: return "Drift"
        case .scramble: return "Scramble"
        case .human: return "Human"
        case .mutate: return "Mutate"
        case .engineSwap: return "Engine Swap"
        case .surprise: return "Surprise"
        }
    }

    /// Category for grouping in the variation menu.
    var category: VariationCategory {
        switch self {
        case .transpose, .invert, .fifth: return .pitch
        case .density, .mirror, .rotate, .euclideanRefill: return .rhythm
        case .bloom, .drift, .scramble: return .melody
        case .human, .mutate, .engineSwap: return .character
        case .surprise: return .character
        }
    }
}

enum VariationCategory: String, CaseIterable {
    case pitch = "PITCH"
    case rhythm = "RHYTHM"
    case melody = "MELODY"
    case character = "CHARACTER"
}
