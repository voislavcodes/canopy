import Foundation

enum EffectType: String, Codable, Equatable, CaseIterable {
    // Canopy vocabulary
    case color      // filter (wraps MoogLadderFilter)
    case heat       // distortion / saturation
    case echo       // delay
    case space      // reverb (Freeverb)
    case pressure   // compressor
    case drift      // chorus
    case tide       // phaser
    case terrain    // EQ
    case level      // gain staging utility
    case ghost      // living decay (true stereo)
    case nebula     // evolving FDN reverb (true stereo)
    case melt       // spectral gravity (true stereo)

    // Legacy cases (backward compatibility for old project files)
    case reverb
    case delay
    case chorus
    case distortion
    case filter
    case compressor
    case eq

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .color:       return "Color"
        case .heat:        return "Heat"
        case .echo:        return "Echo"
        case .space:       return "Space"
        case .pressure:    return "Pressure"
        case .drift:       return "Drift"
        case .tide:        return "Tide"
        case .terrain:     return "Terrain"
        case .level:       return "Level"
        case .ghost:       return "Ghost"
        case .nebula:      return "Nebula"
        case .melt:        return "Melt"
        // Legacy
        case .reverb:      return "Reverb"
        case .delay:       return "Delay"
        case .chorus:      return "Chorus"
        case .distortion:  return "Distortion"
        case .filter:      return "Filter"
        case .compressor:  return "Compressor"
        case .eq:          return "EQ"
        }
    }

    /// Canonical Canopy type (migrates legacy types).
    var canonical: EffectType {
        switch self {
        case .reverb:      return .space
        case .delay:       return .echo
        case .chorus:      return .drift
        case .distortion:  return .heat
        case .filter:      return .color
        case .compressor:  return .pressure
        case .eq:          return .terrain
        default:           return self
        }
    }

    /// Whether this is a legacy type that should be migrated.
    var isLegacy: Bool {
        switch self {
        case .reverb, .delay, .chorus, .distortion, .filter, .compressor, .eq:
            return true
        default:
            return false
        }
    }

    /// Active Canopy effect types available in the FX picker.
    static var canopyTypes: [EffectType] {
        [.color, .heat, .echo, .space, .pressure, .drift, .tide, .terrain, .level, .ghost, .nebula, .melt]
    }

    /// Default parameters for this effect type.
    var defaultParameters: [String: Double] {
        switch canonical {
        case .color:
            return ["hue": 0.7, "resonance": 0.0, "type": 0]
        case .heat:
            return ["temperature": 0.3, "tone": 0.7]
        case .echo:
            return ["distance": 0.3, "decay": 0.4, "diffuse": 0.3]
        case .space:
            return ["size": 0.5, "damp": 0.5]
        case .pressure:
            return ["weight": 0.5, "squeeze": 0.3, "speed": 0.5]
        case .drift:
            return ["rate": 0.3, "depth": 0.5]
        case .tide:
            return ["rate": 0.3, "depth": 0.5, "stages": 4]
        case .terrain:
            return ["low": 0.5, "mid": 0.5, "high": 0.5]
        case .level:
            return ["amount": 0.5]
        case .ghost:
            return ["life": 0.6, "blur": 0.4, "shift": 0.3, "wander": 0.2, "delayTime": 0.25]
        case .nebula:
            return ["cloud": 0.5, "depth": 0.5, "glow": 0.3, "drift": 0.2]
        case .melt:
            return ["gravity": 0.4, "viscosity": 0.3, "floor": 0.0, "heat": 0.2]
        default:
            return [:]
        }
    }

    /// Default wet/dry mix for this effect type.
    var defaultWetDry: Double {
        switch canonical {
        case .color:    return 1.0   // filter is typically fully wet
        case .heat:     return 0.5
        case .echo:     return 0.3
        case .space:    return 0.3
        case .pressure: return 1.0   // compressor is typically fully wet
        case .drift:    return 0.5
        case .tide:     return 0.5
        case .terrain:  return 1.0   // EQ is typically fully wet
        case .level:    return 1.0   // gain utility is always fully wet
        case .ghost:    return 0.4
        case .nebula:   return 0.35
        case .melt:     return 0.5
        default:        return 0.5
        }
    }
}

struct Effect: Codable, Equatable, Identifiable {
    var id: UUID
    var type: EffectType
    var wetDry: Double      // 0.0-1.0, dry/wet
    var parameters: [String: Double]
    var bypassed: Bool

    /// Backward-compatible alias for `wetDry`.
    var mix: Double {
        get { wetDry }
        set { wetDry = newValue }
    }

    init(
        id: UUID = UUID(),
        type: EffectType = .space,
        wetDry: Double? = nil,
        parameters: [String: Double]? = nil,
        bypassed: Bool = false
    ) {
        self.id = id
        self.type = type
        self.wetDry = wetDry ?? type.defaultWetDry
        self.parameters = parameters ?? type.defaultParameters
        self.bypassed = bypassed
    }

    // Backward-compatible decoding: old files use "mix" field
    enum CodingKeys: String, CodingKey {
        case id, type, wetDry, mix, parameters, bypassed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(EffectType.self, forKey: .type)
        // Try wetDry first, fall back to mix
        if let wd = try container.decodeIfPresent(Double.self, forKey: .wetDry) {
            wetDry = wd
        } else {
            wetDry = try container.decodeIfPresent(Double.self, forKey: .mix) ?? 0.3
        }
        parameters = try container.decode([String: Double].self, forKey: .parameters)
        bypassed = try container.decode(Bool.self, forKey: .bypassed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(wetDry, forKey: .wetDry)
        try container.encode(parameters, forKey: .parameters)
        try container.encode(bypassed, forKey: .bypassed)
    }
}
