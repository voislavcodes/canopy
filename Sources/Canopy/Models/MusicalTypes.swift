import Foundation

enum PitchClass: String, Codable, Equatable, CaseIterable {
    case C, Cs, D, Ds, E, F, Fs, G, Gs, A, As, B

    var displayName: String {
        switch self {
        case .C: return "C"
        case .Cs: return "C#"
        case .D: return "D"
        case .Ds: return "D#"
        case .E: return "E"
        case .F: return "F"
        case .Fs: return "F#"
        case .G: return "G"
        case .Gs: return "G#"
        case .A: return "A"
        case .As: return "A#"
        case .B: return "B"
        }
    }
}

enum ScaleMode: String, Codable, Equatable, CaseIterable {
    case major
    case minor
    case dorian
    case mixolydian
    case pentatonic
    case blues
    case chromatic
}

typealias Scale = ScaleMode

struct MusicalKey: Codable, Equatable {
    var root: PitchClass
    var mode: ScaleMode

    var displayName: String {
        "\(root.displayName) \(mode.rawValue.capitalized)"
    }
}
