import Foundation

enum Waveform: String, Codable, Equatable {
    case sine
    case triangle
    case sawtooth
    case square
    case noise
}

struct OscillatorConfig: Codable, Equatable {
    var waveform: Waveform
    var detune: Double      // cents
    var pulseWidth: Double  // 0.0-1.0, relevant for square

    init(waveform: Waveform = .sine, detune: Double = 0, pulseWidth: Double = 0.5) {
        self.waveform = waveform
        self.detune = detune
        self.pulseWidth = pulseWidth
    }
}

struct EnvelopeConfig: Codable, Equatable {
    var attack: Double   // seconds
    var decay: Double
    var sustain: Double  // 0.0-1.0
    var release: Double

    init(attack: Double = 0.01, decay: Double = 0.1, sustain: Double = 0.7, release: Double = 0.3) {
        self.attack = attack
        self.decay = decay
        self.sustain = sustain
        self.release = release
    }
}

struct SamplerConfig: Codable, Equatable {
    var sampleName: String

    init(sampleName: String = "") {
        self.sampleName = sampleName
    }
}

struct AUv3Config: Codable, Equatable {
    var componentName: String

    init(componentName: String = "") {
        self.componentName = componentName
    }
}

enum SoundType: Codable, Equatable {
    case oscillator(OscillatorConfig)
    case sampler(SamplerConfig)
    case auv3(AUv3Config)
}

struct FilterConfig: Codable, Equatable {
    var enabled: Bool
    var cutoff: Double   // Hz, 20–20000
    var resonance: Double // 0.0–1.0

    init(enabled: Bool = false, cutoff: Double = 8000.0, resonance: Double = 0.0) {
        self.enabled = enabled
        self.cutoff = cutoff
        self.resonance = resonance
    }
}

struct SoundPatch: Codable, Equatable {
    var id: UUID
    var name: String
    var soundType: SoundType
    var envelope: EnvelopeConfig
    var volume: Double  // 0.0-1.0
    var pan: Double     // -1.0 (left) to 1.0 (right)
    var filter: FilterConfig

    init(
        id: UUID = UUID(),
        name: String = "Default",
        soundType: SoundType = .oscillator(OscillatorConfig()),
        envelope: EnvelopeConfig = EnvelopeConfig(),
        volume: Double = 0.8,
        pan: Double = 0.0,
        filter: FilterConfig = FilterConfig()
    ) {
        self.id = id
        self.name = name
        self.soundType = soundType
        self.envelope = envelope
        self.volume = volume
        self.pan = pan
        self.filter = filter
    }

    // Custom decoder for backward compatibility with old .canopy files
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        soundType = try container.decode(SoundType.self, forKey: .soundType)
        envelope = try container.decode(EnvelopeConfig.self, forKey: .envelope)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        filter = try container.decodeIfPresent(FilterConfig.self, forKey: .filter) ?? FilterConfig()
    }
}
