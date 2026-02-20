import Foundation

/// Tagged enum for effect DSP — no protocol existentials, no dynamic dispatch,
/// no existential containers on the audio thread.
///
/// Same pattern as `SoundType` and `AudioCommand`: a single switch in `process()`
/// compiles to a branch prediction, fully inline.
enum EffectSlot {
    case color(ColorEffect)
    case heat(HeatEffect)
    case echo(EchoEffect)
    case space(SpaceEffect)
    case pressure(PressureEffect)

    /// Process a single sample through the effect.
    mutating func process(sample: Float, sampleRate: Float) -> Float {
        switch self {
        case .color(var fx):
            let out = fx.process(sample: sample, sampleRate: sampleRate)
            self = .color(fx)
            return out
        case .heat(var fx):
            let out = fx.process(sample: sample, sampleRate: sampleRate)
            self = .heat(fx)
            return out
        case .echo(var fx):
            let out = fx.process(sample: sample, sampleRate: sampleRate)
            self = .echo(fx)
            return out
        case .space(var fx):
            let out = fx.process(sample: sample, sampleRate: sampleRate)
            self = .space(fx)
            return out
        case .pressure(var fx):
            let out = fx.process(sample: sample, sampleRate: sampleRate)
            self = .pressure(fx)
            return out
        }
    }

    /// Update effect parameters from a dictionary.
    mutating func updateParameters(_ params: [String: Double]) {
        switch self {
        case .color(var fx):
            fx.updateParameters(params)
            self = .color(fx)
        case .heat(var fx):
            fx.updateParameters(params)
            self = .heat(fx)
        case .echo(var fx):
            fx.updateParameters(params)
            self = .echo(fx)
        case .space(var fx):
            fx.updateParameters(params)
            self = .space(fx)
        case .pressure(var fx):
            fx.updateParameters(params)
            self = .pressure(fx)
        }
    }

    /// Reset effect state.
    mutating func reset() {
        switch self {
        case .color(var fx):
            fx.reset()
            self = .color(fx)
        case .heat(var fx):
            fx.reset()
            self = .heat(fx)
        case .echo(var fx):
            fx.reset()
            self = .echo(fx)
        case .space(var fx):
            fx.reset()
            self = .space(fx)
        case .pressure(var fx):
            fx.reset()
            self = .pressure(fx)
        }
    }

    /// Create an EffectSlot from an EffectType and parameters.
    static func create(type: EffectType, parameters: [String: Double]) -> EffectSlot {
        let canonical = type.canonical
        var slot: EffectSlot
        switch canonical {
        case .color:    slot = .color(ColorEffect())
        case .heat:     slot = .heat(HeatEffect())
        case .echo:     slot = .echo(EchoEffect())
        case .space:    slot = .space(SpaceEffect())
        case .pressure: slot = .pressure(PressureEffect())
        default:        slot = .color(ColorEffect()) // fallback
        }
        slot.updateParameters(parameters)
        return slot
    }
}
