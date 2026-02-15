import Foundation

/// Which parameter on a node an LFO can modulate.
enum ModulationParameter: String, Codable, Equatable, CaseIterable {
    case volume
    case pan
    case filterCutoff
    case filterResonance
}

/// LFO waveform shapes.
enum LFOWaveform: String, Codable, Equatable, CaseIterable {
    case sine
    case triangle
    case sawtooth
    case square
    case sampleAndHold
}

/// A project-level LFO definition. Multiple routings can reference the same LFO.
struct LFODefinition: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var waveform: LFOWaveform
    var rateHz: Double
    var phase: Double
    var enabled: Bool
    var colorIndex: Int

    init(
        id: UUID = UUID(),
        name: String = "LFO 1",
        waveform: LFOWaveform = .sine,
        rateHz: Double = 1.0,
        phase: Double = 0.0,
        enabled: Bool = true,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.waveform = waveform
        self.rateHz = rateHz
        self.phase = phase
        self.enabled = enabled
        self.colorIndex = colorIndex
    }
}

/// Routes an LFO to a specific parameter on a specific node.
/// Depth lives on the routing so one LFO can modulate different targets at different intensities.
struct ModulationRouting: Codable, Equatable, Identifiable {
    var id: UUID
    var lfoID: UUID
    var nodeID: UUID
    var parameter: ModulationParameter
    var depth: Double

    init(
        id: UUID = UUID(),
        lfoID: UUID,
        nodeID: UUID,
        parameter: ModulationParameter,
        depth: Double = 0.5
    ) {
        self.id = id
        self.lfoID = lfoID
        self.nodeID = nodeID
        self.parameter = parameter
        self.depth = depth
    }
}
