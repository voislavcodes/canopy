import Foundation

/// Single LFO oscillator for per-sample modulation on the audio thread.
/// All value types — no ARC, no allocations. Waveform and parameter are stored
/// as Int to avoid enum overhead in the render loop.
struct LFOProcessor {
    var phase: Double = 0
    var rateHz: Double = 1.0
    var initialPhase: Double = 0
    var depth: Double = 0.5
    /// Waveform: 0=sine, 1=triangle, 2=sawtooth, 3=square, 4=sample&hold
    var waveform: Int = 0
    /// Target parameter: 0=volume, 1=pan, 2=filterCutoff, 3=filterResonance
    var parameter: Int = 0
    var enabled: Bool = false

    // Sample & hold state
    private var shValue: Double = 0
    private var shSeed: UInt64 = 12345
    private var prevPhase: Double = 0

    /// Advance one sample and return the modulation value in [-depth, +depth].
    /// Zero allocations, no ARC.
    mutating func tick(sampleRate: Double) -> Double {
        guard enabled else { return 0 }

        phase += rateHz / sampleRate

        // Detect phase wrap for S&H
        let wrappedPhase = phase - floor(phase)

        let raw: Double
        switch waveform {
        case 0: // sine
            raw = sin(2.0 * .pi * wrappedPhase)
        case 1: // triangle
            raw = 4.0 * abs(wrappedPhase - 0.5) - 1.0
        case 2: // sawtooth
            raw = 2.0 * wrappedPhase - 1.0
        case 3: // square
            raw = wrappedPhase < 0.5 ? 1.0 : -1.0
        case 4: // sample & hold
            // New random value on phase wrap (when fractional part resets)
            if wrappedPhase < prevPhase {
                // LCG pseudo-random (deterministic, no allocation)
                shSeed = shSeed &* 6364136223846793005 &+ 1442695040888963407
                shValue = Double(Int64(bitPattern: shSeed >> 1)) / Double(Int64.max)
            }
            prevPhase = wrappedPhase
            raw = shValue
        default:
            raw = 0
        }

        return raw * depth
    }

    /// Reset phase to initial offset.
    mutating func reset() {
        phase = initialPhase
        prevPhase = 0
        shValue = 0
    }
}

/// Fixed-size bank of 4 LFO slots stored as a tuple to avoid array/ARC on the audio thread.
/// `tick()` is manually unrolled over the tuple — no subscript, no dynamic dispatch.
struct LFOBank {
    static let maxSlots = 4

    var slots: (LFOProcessor, LFOProcessor, LFOProcessor, LFOProcessor) = (
        LFOProcessor(), LFOProcessor(), LFOProcessor(), LFOProcessor()
    )
    var slotCount: Int = 0

    /// Advance all active slots by one sample and return accumulated per-parameter modulation.
    mutating func tick(sampleRate: Double) -> (volMod: Double, panMod: Double, cutMod: Double, resMod: Double) {
        var vol = 0.0, pan = 0.0, cut = 0.0, res = 0.0

        if slotCount > 0 {
            let v0 = slots.0.tick(sampleRate: sampleRate)
            switch slots.0.parameter {
            case 0: vol += v0
            case 1: pan += v0
            case 2: cut += v0
            case 3: res += v0
            default: break
            }
        }
        if slotCount > 1 {
            let v1 = slots.1.tick(sampleRate: sampleRate)
            switch slots.1.parameter {
            case 0: vol += v1
            case 1: pan += v1
            case 2: cut += v1
            case 3: res += v1
            default: break
            }
        }
        if slotCount > 2 {
            let v2 = slots.2.tick(sampleRate: sampleRate)
            switch slots.2.parameter {
            case 0: vol += v2
            case 1: pan += v2
            case 2: cut += v2
            case 3: res += v2
            default: break
            }
        }
        if slotCount > 3 {
            let v3 = slots.3.tick(sampleRate: sampleRate)
            switch slots.3.parameter {
            case 0: vol += v3
            case 1: pan += v3
            case 2: cut += v3
            case 3: res += v3
            default: break
            }
        }

        return (vol, pan, cut, res)
    }

    /// Configure a specific slot. Index must be 0..<maxSlots.
    mutating func configureSlot(_ index: Int, enabled: Bool, waveform: Int,
                                 rateHz: Double, initialPhase: Double,
                                 depth: Double, parameter: Int) {
        var proc = LFOProcessor()
        proc.enabled = enabled
        proc.waveform = waveform
        proc.rateHz = rateHz
        proc.initialPhase = initialPhase
        proc.phase = initialPhase
        proc.depth = depth
        proc.parameter = parameter

        switch index {
        case 0: slots.0 = proc
        case 1: slots.1 = proc
        case 2: slots.2 = proc
        case 3: slots.3 = proc
        default: break
        }
    }

    /// Reset all slot phases to their initial offsets.
    mutating func resetAll() {
        slots.0.reset()
        slots.1.reset()
        slots.2.reset()
        slots.3.reset()
    }
}
