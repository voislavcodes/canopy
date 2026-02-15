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

/// Per-voice FM drum synthesis parameters.
struct DrumVoiceConfig: Codable, Equatable {
    var carrierFreq: Double      // Hz
    var modulatorRatio: Double   // freq multiplier
    var fmDepth: Double          // modulation index
    var noiseMix: Double         // 0-1
    var ampDecay: Double         // seconds
    var pitchEnvAmount: Double   // octaves of sweep
    var pitchDecay: Double       // seconds
    var level: Double            // 0-1

    init(carrierFreq: Double = 180, modulatorRatio: Double = 1.5,
         fmDepth: Double = 5.0, noiseMix: Double = 0.0,
         ampDecay: Double = 0.3, pitchEnvAmount: Double = 2.0,
         pitchDecay: Double = 0.05, level: Double = 0.8) {
        self.carrierFreq = carrierFreq
        self.modulatorRatio = modulatorRatio
        self.fmDepth = fmDepth
        self.noiseMix = noiseMix
        self.ampDecay = ampDecay
        self.pitchEnvAmount = pitchEnvAmount
        self.pitchDecay = pitchDecay
        self.level = level
    }
}

/// 8-voice drum kit configuration for persistence.
struct DrumKitConfig: Codable, Equatable {
    var voices: [DrumVoiceConfig] // always exactly 8

    init() {
        voices = [
            // Kick
            DrumVoiceConfig(carrierFreq: 60, modulatorRatio: 1.0, fmDepth: 4.0,
                           noiseMix: 0.02, ampDecay: 0.4, pitchEnvAmount: 3.0,
                           pitchDecay: 0.03, level: 0.9),
            // Snare
            DrumVoiceConfig(carrierFreq: 180, modulatorRatio: 2.3, fmDepth: 3.0,
                           noiseMix: 0.5, ampDecay: 0.2, pitchEnvAmount: 1.0,
                           pitchDecay: 0.02, level: 0.8),
            // Closed hat
            DrumVoiceConfig(carrierFreq: 400, modulatorRatio: 3.7, fmDepth: 6.0,
                           noiseMix: 0.7, ampDecay: 0.05, pitchEnvAmount: 0.5,
                           pitchDecay: 0.01, level: 0.6),
            // Open hat
            DrumVoiceConfig(carrierFreq: 400, modulatorRatio: 3.7, fmDepth: 6.0,
                           noiseMix: 0.7, ampDecay: 0.3, pitchEnvAmount: 0.5,
                           pitchDecay: 0.01, level: 0.6),
            // Tom low
            DrumVoiceConfig(carrierFreq: 100, modulatorRatio: 1.2, fmDepth: 3.0,
                           noiseMix: 0.05, ampDecay: 0.35, pitchEnvAmount: 2.5,
                           pitchDecay: 0.04, level: 0.8),
            // Tom high
            DrumVoiceConfig(carrierFreq: 150, modulatorRatio: 1.2, fmDepth: 3.0,
                           noiseMix: 0.05, ampDecay: 0.3, pitchEnvAmount: 2.0,
                           pitchDecay: 0.03, level: 0.8),
            // Crash
            DrumVoiceConfig(carrierFreq: 300, modulatorRatio: 4.5, fmDepth: 8.0,
                           noiseMix: 0.6, ampDecay: 1.0, pitchEnvAmount: 0.3,
                           pitchDecay: 0.02, level: 0.5),
            // Ride
            DrumVoiceConfig(carrierFreq: 500, modulatorRatio: 3.1, fmDepth: 5.0,
                           noiseMix: 0.4, ampDecay: 0.6, pitchEnvAmount: 0.2,
                           pitchDecay: 0.01, level: 0.5),
        ]
    }
}

enum SoundType: Codable, Equatable {
    case oscillator(OscillatorConfig)
    case drumKit(DrumKitConfig)
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
