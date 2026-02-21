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

    /// Semitone offset from C (C=0, C#=1, ... B=11)
    var semitone: Int {
        switch self {
        case .C: return 0
        case .Cs: return 1
        case .D: return 2
        case .Ds: return 3
        case .E: return 4
        case .F: return 5
        case .Fs: return 6
        case .G: return 7
        case .Gs: return 8
        case .A: return 9
        case .As: return 10
        case .B: return 11
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
    case harmonicMinor
    case melodicMinor
    case phrygian
    case lydian
    case locrian
    case pentatonicMajor
    case pentatonicMinor
    case wholeTone
    case hirajoshi
    case inSen
    case diminished

    /// Semitone intervals from root for this scale mode.
    var intervals: [Int] {
        switch self {
        case .major:          return [0, 2, 4, 5, 7, 9, 11]
        case .minor:          return [0, 2, 3, 5, 7, 8, 10]
        case .dorian:         return [0, 2, 3, 5, 7, 9, 10]
        case .mixolydian:     return [0, 2, 4, 5, 7, 9, 10]
        case .pentatonic:     return [0, 2, 4, 7, 9]
        case .blues:          return [0, 3, 5, 6, 7, 10]
        case .chromatic:      return [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        case .harmonicMinor:  return [0, 2, 3, 5, 7, 8, 11]
        case .melodicMinor:   return [0, 2, 3, 5, 7, 9, 11]
        case .phrygian:       return [0, 1, 3, 5, 7, 8, 10]
        case .lydian:         return [0, 2, 4, 6, 7, 9, 11]
        case .locrian:        return [0, 1, 3, 5, 6, 8, 10]
        case .pentatonicMajor: return [0, 2, 4, 7, 9]
        case .pentatonicMinor: return [0, 3, 5, 7, 10]
        case .wholeTone:      return [0, 2, 4, 6, 8, 10]
        case .hirajoshi:      return [0, 2, 3, 7, 8]
        case .inSen:          return [0, 1, 5, 7, 10]
        case .diminished:     return [0, 2, 3, 5, 6, 8, 9, 11]
        }
    }
}

typealias Scale = ScaleMode

struct MusicalKey: Codable, Equatable {
    var root: PitchClass
    var mode: ScaleMode

    var displayName: String {
        "\(root.displayName) \(mode.rawValue.capitalized)"
    }
}
