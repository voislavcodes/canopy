import Foundation

enum EffectType: String, Codable, Equatable {
    case reverb
    case delay
    case chorus
    case distortion
    case filter
    case compressor
    case eq
}

struct Effect: Codable, Equatable {
    var id: UUID
    var type: EffectType
    var mix: Double         // 0.0-1.0, dry/wet
    var parameters: [String: Double]
    var bypassed: Bool

    init(
        id: UUID = UUID(),
        type: EffectType = .reverb,
        mix: Double = 0.3,
        parameters: [String: Double] = [:],
        bypassed: Bool = false
    ) {
        self.id = id
        self.type = type
        self.mix = mix
        self.parameters = parameters
        self.bypassed = bypassed
    }
}
