import Foundation

// MARK: - Spectral Imprint (IMPRINT feature)

/// Spectral fingerprint extracted from a mic recording via FFT analysis.
/// One recording → three engines → three completely different instruments.
/// This is NOT a sampler — only spectral data survives, not audio.
struct SpectralImprint: Codable, Equatable {
    /// Detected fundamental pitch in Hz. Nil for unpitched/noisy sources.
    var fundamental: Float?
    /// 64 harmonic amplitudes (0–1), normalized. Used by FLOW engine.
    var harmonicAmplitudes: [Float]
    /// 64 frequency ratios (relative to fundamental or lowest peak). Used by SWARM engine.
    var peakRatios: [Float]
    /// 64 peak amplitudes (0–1). Used by SWARM engine.
    var peakAmplitudes: [Float]
    /// 4–16 frames of 16 band levels. Used by TIDE engine.
    var spectralFrames: [[Float]]
    /// Sample rate of the original recording.
    var sampleRate: Float
    /// Duration of the original recording in seconds.
    var durationSeconds: Float
    /// When the imprint was captured.
    var timestamp: Date

    /// Convert spectral frames (arrays of 16 Float) to TideFrame structs.
    /// Uses narrower Q (5.0) than default patterns so the imprint's spectral
    /// shape cuts through clearly — wider bands blur the voice character.
    static func tideFrames(from spectralFrames: [[Float]]) -> [TideFrame] {
        let imprintQ: (Float, Float, Float, Float, Float, Float, Float, Float,
                       Float, Float, Float, Float, Float, Float, Float, Float)
            = (5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0,
               5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0)
        return spectralFrames.map { bandLevels in
            var levels: (Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float)
                = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutablePointer(to: &levels) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 16) { p in
                    for i in 0..<min(16, bandLevels.count) {
                        p[i] = bandLevels[i]
                    }
                }
            }
            return TideFrame(levels: levels, qs: imprintQ, oddEvenBalance: 0, spectralTilt: 0)
        }
    }
}

/// Whether an engine parameter uses default values or values from an imprint.
enum SpectralSource: String, Codable, Equatable {
    case `default`
    case imprint
}

/// Whether SWARM partials are triggered from harmonic series or imprint peaks.
enum TriggerSource: String, Codable, Equatable {
    case harmonic
    case imprint
}

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

/// West Coast primary oscillator waveform (sine or triangle only).
enum WCWaveform: String, Codable, Equatable {
    case sine
    case triangle
}

/// Low-pass gate operating mode.
enum LPGMode: String, Codable, Equatable {
    case filter
    case vca
    case both
}

/// Function generator shape (rise/fall curve).
enum FuncShape: String, Codable, Equatable {
    case linear
    case exponential
    case logarithmic
}

/// West Coast complex oscillator configuration.
/// Signal chain: primary osc → FM/ring mod → wavefolder → LPG → output.
struct WestCoastConfig: Codable, Equatable {
    // Primary oscillator
    var primaryWaveform: WCWaveform
    var modulatorRatio: Double      // freq multiplier (0.1–16.0)
    var modulatorFineTune: Double   // cents (-100 to +100)

    // FM synthesis
    var fmDepth: Double             // modulation index (0–20)
    var envToFM: Double             // function gen → FM depth (0–1)

    // Ring modulation
    var ringModMix: Double          // 0–1

    // Wavefolder
    var foldAmount: Double          // 0–1 (0 = bypass)
    var foldStages: Int             // 1–6
    var foldSymmetry: Double        // 0–1 (0.5 = symmetric)
    var modToFold: Double           // modulator → fold amount (0–1)

    // Low Pass Gate (vactrol model)
    var lpgMode: LPGMode
    var strike: Double              // attack intensity (0–1)
    var damp: Double                // decay time control (0–1, maps to 50ms–2000ms)
    var color: Double               // filter brightness (0–1)

    // Function generator (replaces ADSR)
    var rise: Double                // rise time in seconds (0.001–5.0)
    var fall: Double                // fall time in seconds (0.01–10.0)
    var funcShape: FuncShape
    var funcLoop: Bool              // true = LFO mode

    // Output
    var volume: Double              // 0–1
    var pan: Double                 // -1 to +1

    init(
        primaryWaveform: WCWaveform = .sine,
        modulatorRatio: Double = 1.0,
        modulatorFineTune: Double = 0,
        fmDepth: Double = 3.0,
        envToFM: Double = 0.5,
        ringModMix: Double = 0.0,
        foldAmount: Double = 0.3,
        foldStages: Int = 2,
        foldSymmetry: Double = 0.5,
        modToFold: Double = 0.0,
        lpgMode: LPGMode = .both,
        strike: Double = 0.7,
        damp: Double = 0.4,
        color: Double = 0.6,
        rise: Double = 0.005,
        fall: Double = 0.3,
        funcShape: FuncShape = .exponential,
        funcLoop: Bool = false,
        volume: Double = 0.8,
        pan: Double = 0.0
    ) {
        self.primaryWaveform = primaryWaveform
        self.modulatorRatio = modulatorRatio
        self.modulatorFineTune = modulatorFineTune
        self.fmDepth = fmDepth
        self.envToFM = envToFM
        self.ringModMix = ringModMix
        self.foldAmount = foldAmount
        self.foldStages = foldStages
        self.foldSymmetry = foldSymmetry
        self.modToFold = modToFold
        self.lpgMode = lpgMode
        self.strike = strike
        self.damp = damp
        self.color = color
        self.rise = rise
        self.fall = fall
        self.funcShape = funcShape
        self.funcLoop = funcLoop
        self.volume = volume
        self.pan = pan
    }
}

/// TIDE engine: spectral sequencing synthesizer.
/// A rich oscillator feeds 16 SVF bandpass filters whose levels are cycled
/// by an internal pattern sequencer. Holding a note produces self-animating
/// spectral movement.

/// Function generator shape for TIDE amplitude shaping.
/// Phase is derived from the tide position, guaranteeing perfect sync with spectral animation.
enum TideFuncShape: String, Codable, CaseIterable, Equatable {
    case off
    case sine
    case triangle
    case rampDown
    case rampUp
    case square
    case sAndH
}

/// Beat-synced rate division for TIDE spectral cycling.
enum TideRateDivision: String, Codable, CaseIterable, Equatable {
    case fourBars
    case twoBars
    case oneBar
    case half
    case quarter
    case eighth
    case sixteenth

    /// Number of beats for one full pattern cycle.
    var beats: Double {
        switch self {
        case .fourBars: return 16
        case .twoBars: return 8
        case .oneBar: return 4
        case .half: return 2
        case .quarter: return 1
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        }
    }

    var displayName: String {
        switch self {
        case .fourBars: return "4 BAR"
        case .twoBars: return "2 BAR"
        case .oneBar: return "1 BAR"
        case .half: return "1/2"
        case .quarter: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        }
    }
}

struct TideConfig: Codable, Equatable {
    var current: Double     // 0–1: oscillator richness (sine → tri → saw → pulse → noise layers)
    var pattern: Int        // 0–15: spectral journey pattern index (16 = imprint)
    var rate: Double        // 0–1: cycle speed through pattern frames (free mode)
    var rateSync: Bool      // true = lock cycle to tempo, false = free-running Hz
    var rateDivision: TideRateDivision // beat division when synced
    var depth: Double       // 0–1: contrast between active and inactive bands
    var warmth: Double      // 0–1: per-voice soft saturation (tanh drive)
    var volume: Double      // 0–1
    var pan: Double         // -1 to +1

    // Function generator — amplitude shaping synced to tide position
    var funcShape: TideFuncShape  // off = bypass (continuous sound)
    var funcAmount: Double        // 0–1: modulation depth
    var funcSkew: Double          // 0–1: phase warp (0.5 = symmetric)
    var funcCycles: Int           // 1, 2, 4, 8, 16: func gen cycles per pattern cycle

    // IMPRINT
    var imprint: SpectralImprint?

    init(
        current: Double = 0.4,
        pattern: Int = 0,
        rate: Double = 0.3,
        rateSync: Bool = false,
        rateDivision: TideRateDivision = .oneBar,
        depth: Double = 0.6,
        warmth: Double = 0.3,
        volume: Double = 0.8,
        pan: Double = 0.0,
        funcShape: TideFuncShape = .off,
        funcAmount: Double = 0.0,
        funcSkew: Double = 0.5,
        funcCycles: Int = 1,
        imprint: SpectralImprint? = nil
    ) {
        self.current = current
        self.pattern = pattern
        self.rate = rate
        self.rateSync = rateSync
        self.rateDivision = rateDivision
        self.depth = depth
        self.warmth = warmth
        self.volume = volume
        self.pan = pan
        self.funcShape = funcShape
        self.funcAmount = funcAmount
        self.funcSkew = funcSkew
        self.funcCycles = funcCycles
        self.imprint = imprint
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode(Double.self, forKey: .current)
        pattern = try container.decode(Int.self, forKey: .pattern)
        rate = try container.decode(Double.self, forKey: .rate)
        rateSync = try container.decodeIfPresent(Bool.self, forKey: .rateSync) ?? false
        rateDivision = try container.decodeIfPresent(TideRateDivision.self, forKey: .rateDivision) ?? .oneBar
        depth = try container.decode(Double.self, forKey: .depth)
        warmth = try container.decode(Double.self, forKey: .warmth)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        funcShape = try container.decodeIfPresent(TideFuncShape.self, forKey: .funcShape) ?? .off
        funcAmount = try container.decodeIfPresent(Double.self, forKey: .funcAmount) ?? 0.0
        funcSkew = try container.decodeIfPresent(Double.self, forKey: .funcSkew) ?? 0.5
        funcCycles = try container.decodeIfPresent(Int.self, forKey: .funcCycles) ?? 1
        imprint = try container.decodeIfPresent(SpectralImprint.self, forKey: .imprint)
    }

    // MARK: - Preset Seeds

    /// Gentle dawn: slow rising tide, warm and pure.
    static let sunrise = TideConfig(current: 0.2, pattern: 0, rate: 0.15, depth: 0.5, warmth: 0.4)
    /// Submerged: deep rich oscillator, slow ebb and flow.
    static let deepSea = TideConfig(current: 0.7, pattern: 2, rate: 0.1, depth: 0.8, warmth: 0.5)
    /// Beacon pulse: spotlight pattern, moderate speed.
    static let lighthouse = TideConfig(current: 0.3, pattern: 3, rate: 0.4, depth: 0.7, warmth: 0.2)
    /// Wide stereo: ping-pong pattern, full depth.
    static let stereoField = TideConfig(current: 0.5, pattern: 6, rate: 0.35, depth: 0.9, warmth: 0.3)
    /// Formant sweep: vowel pattern, rich source.
    static let robotChoir = TideConfig(current: 0.6, pattern: 10, rate: 0.25, depth: 0.7, warmth: 0.4)
    /// Cascading bands: waterfall of spectral energy.
    static let waterfall = TideConfig(current: 0.8, pattern: 7, rate: 0.5, depth: 0.6, warmth: 0.3)
    /// Metallic resonance: bells pattern, sparse source.
    static let gamelan = TideConfig(current: 0.35, pattern: 11, rate: 0.2, depth: 0.8, warmth: 0.2)
    /// Harmonic fifths: sacred intervals.
    static let sacred = TideConfig(current: 0.25, pattern: 12, rate: 0.15, depth: 0.6, warmth: 0.5)
    /// Staccato sparkle: fast rhythmic pattern.
    static let fireflies = TideConfig(current: 0.45, pattern: 8, rate: 0.7, depth: 0.9, warmth: 0.2)
    /// Suzanne Ciani-inspired: cascading sequences.
    static let ciani = TideConfig(current: 0.55, pattern: 7, rate: 0.45, depth: 0.75, warmth: 0.35)
    /// Morton Subotnick-inspired: wandering chaos.
    static let subotnick = TideConfig(current: 0.7, pattern: 14, rate: 0.3, depth: 0.8, warmth: 0.4)
    /// Ambient wash: slow, deep, warm.
    static let ambient = TideConfig(current: 0.3, pattern: 4, rate: 0.08, depth: 0.4, warmth: 0.6)
}

/// SWARM engine: emergent additive synthesis.
/// 64 sine oscillators as autonomous agents in frequency space.
/// Gravity pulls toward harmonics, turbulence tears apart, flocking aligns motion.
/// Four controls map divergently to physics parameters.
struct SwarmConfig: Codable, Equatable {
    // The four controls
    var gravity: Double = 0.5      // 0–1: harmonic attraction (0 = chaos, 1 = pure tone)
    var energy: Double = 0.3       // 0–1: system agitation (0 = still, 1 = violent)
    var flock: Double = 0.2        // 0–1: group behaviour (0 = independent, 1 = unison)
    var scatter: Double = 0.3      // 0–1: spectral spread (0 = tight cluster, 1 = wide)

    // Output
    var warmth: Double = 0.3       // 0–1: per-voice tanh drive
    var volume: Double = 0.7       // 0–1
    var pan: Double = 0.0          // -1 to +1

    // IMPRINT
    var imprint: SpectralImprint?
    var triggerSource: TriggerSource = .harmonic

    init(
        gravity: Double = 0.5,
        energy: Double = 0.3,
        flock: Double = 0.2,
        scatter: Double = 0.3,
        warmth: Double = 0.3,
        volume: Double = 0.7,
        pan: Double = 0.0,
        imprint: SpectralImprint? = nil,
        triggerSource: TriggerSource = .harmonic
    ) {
        self.gravity = gravity
        self.energy = energy
        self.flock = flock
        self.scatter = scatter
        self.warmth = warmth
        self.volume = volume
        self.pan = pan
        self.imprint = imprint
        self.triggerSource = triggerSource
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gravity = try container.decode(Double.self, forKey: .gravity)
        energy = try container.decode(Double.self, forKey: .energy)
        flock = try container.decode(Double.self, forKey: .flock)
        scatter = try container.decode(Double.self, forKey: .scatter)
        warmth = try container.decode(Double.self, forKey: .warmth)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        imprint = try container.decodeIfPresent(SpectralImprint.self, forKey: .imprint)
        triggerSource = try container.decodeIfPresent(TriggerSource.self, forKey: .triggerSource) ?? .harmonic
    }

    // MARK: - Preset Seeds

    /// Clean shimmering harmonics. Still.
    static let crystal = SwarmConfig(gravity: 0.8, energy: 0.1, flock: 0.1, scatter: 0.3)
    /// Slow glacial drift in groups. Deep space.
    static let nebula = SwarmConfig(gravity: 0.3, energy: 0.2, flock: 0.6, scatter: 0.4)
    /// Buzzy, alive, shifting. The namesake.
    static let swarm = SwarmConfig(gravity: 0.4, energy: 0.5, flock: 0.3, scatter: 0.5)
    /// Barely harmonic. Eerie. Whisper from beyond.
    static let ghost = SwarmConfig(gravity: 0.2, energy: 0.1, flock: 0.1, scatter: 0.3)
    /// Violent spectral chaos.
    static let storm = SwarmConfig(gravity: 0.5, energy: 0.9, flock: 0.2, scatter: 0.4)
    /// Vocal groups. Harmonic sweeps.
    static let choir = SwarmConfig(gravity: 0.7, energy: 0.2, flock: 0.8, scatter: 0.3)
    /// Scattered light. Twinkling.
    static let firefly = SwarmConfig(gravity: 0.5, energy: 0.4, flock: 0.4, scatter: 0.7)
    /// Locked harmonics. Pure additive.
    static let glass = SwarmConfig(gravity: 0.9, energy: 0.05, flock: 0.0, scatter: 0.5)
    /// Starling flock. Groups tearing through space.
    static let murmuration = SwarmConfig(gravity: 0.3, energy: 0.8, flock: 0.7, scatter: 0.3)
    /// Dense, independent, atomic.
    static let nucleus = SwarmConfig(gravity: 0.5, energy: 0.5, flock: 0.0, scatter: 0.1)
}

/// FLOW engine: 64 sine partials in a simulated fluid.
/// Reynolds number (derived from 5 controls) drives phase transitions
/// between laminar purity, vortex shedding rhythm, and turbulence.
struct FlowConfig: Codable, Equatable {
    var current: Double     // 0–1: flow velocity / Reynolds number driver
    var viscosity: Double   // 0–1: damping / dissipation
    var obstacle: Double    // 0–1: obstacle diameter (affects vortex shedding freq)
    var channel: Double     // 0–1: channel width (confinement)
    var density: Double     // 0–1: fluid density (affects inertia)
    var warmth: Double      // 0–1: per-voice soft saturation (tanh drive)
    var volume: Double      // 0–1
    var pan: Double         // -1 to +1

    // IMPRINT
    var imprint: SpectralImprint?
    var spectralSource: SpectralSource = .default

    init(
        current: Double = 0.2,
        viscosity: Double = 0.5,
        obstacle: Double = 0.3,
        channel: Double = 0.5,
        density: Double = 0.5,
        warmth: Double = 0.3,
        volume: Double = 0.8,
        pan: Double = 0.0,
        imprint: SpectralImprint? = nil,
        spectralSource: SpectralSource = .default
    ) {
        self.current = current
        self.viscosity = viscosity
        self.obstacle = obstacle
        self.channel = channel
        self.density = density
        self.warmth = warmth
        self.volume = volume
        self.pan = pan
        self.imprint = imprint
        self.spectralSource = spectralSource
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decode(Double.self, forKey: .current)
        viscosity = try container.decode(Double.self, forKey: .viscosity)
        obstacle = try container.decode(Double.self, forKey: .obstacle)
        channel = try container.decode(Double.self, forKey: .channel)
        density = try container.decode(Double.self, forKey: .density)
        warmth = try container.decode(Double.self, forKey: .warmth)
        volume = try container.decode(Double.self, forKey: .volume)
        pan = try container.decode(Double.self, forKey: .pan)
        imprint = try container.decodeIfPresent(SpectralImprint.self, forKey: .imprint)
        spectralSource = try container.decodeIfPresent(SpectralSource.self, forKey: .spectralSource) ?? .default
    }

    // MARK: - Preset Seeds

    /// Still water: near-zero flow, pure harmonics.
    static let stillWater = FlowConfig(current: 0.02, viscosity: 0.9, obstacle: 0.1, channel: 0.5, density: 0.5)
    /// Gentle stream: subtle laminar drift.
    static let gentleStream = FlowConfig(current: 0.1, viscosity: 0.7, obstacle: 0.2, channel: 0.4, density: 0.4)
    /// River: moderate flow, entering transition regime.
    static let river = FlowConfig(current: 0.35, viscosity: 0.4, obstacle: 0.4, channel: 0.5, density: 0.6)
    /// Rapids: strong vortex shedding.
    static let rapids = FlowConfig(current: 0.55, viscosity: 0.25, obstacle: 0.6, channel: 0.6, density: 0.7)
    /// Waterfall: fully turbulent cascade.
    static let waterfall = FlowConfig(current: 0.9, viscosity: 0.1, obstacle: 0.5, channel: 0.8, density: 0.8)
    /// Lava: high density, high viscosity, slow turbulence.
    static let lava = FlowConfig(current: 0.5, viscosity: 0.8, obstacle: 0.7, channel: 0.3, density: 1.0)
    /// Steam: low density, high current, fast dissipation.
    static let steam = FlowConfig(current: 0.7, viscosity: 0.6, obstacle: 0.2, channel: 0.9, density: 0.1)
    /// Whirlpool: high obstacle, strong vortex shedding.
    static let whirlpool = FlowConfig(current: 0.45, viscosity: 0.3, obstacle: 0.9, channel: 0.4, density: 0.6)
    /// Breath: gentle, organic, periodic flow.
    static let breath = FlowConfig(current: 0.15, viscosity: 0.5, obstacle: 0.3, channel: 0.3, density: 0.3)
    /// Jet: narrow channel, high velocity, turbulent.
    static let jet = FlowConfig(current: 0.85, viscosity: 0.15, obstacle: 0.3, channel: 1.0, density: 0.5)
}

enum SoundType: Codable, Equatable {
    case oscillator(OscillatorConfig)
    case drumKit(DrumKitConfig)
    case westCoast(WestCoastConfig)
    case flow(FlowConfig)
    case tide(TideConfig)
    case swarm(SwarmConfig)
    case quake(QuakeConfig)
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
