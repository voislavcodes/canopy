import Foundation

/// Circuit topology selection for VOLT layers.
enum VoltTopology: String, Codable, Equatable, CaseIterable {
    case resonant
    case noise
    case metallic
    case tonal
}

/// VOLT engine: analog circuit drum synthesis.
/// Four circuit topologies (Resonant, Noise, Metallic, Tonal) modeled at the
/// component level. Two layers can be active simultaneously with continuous mix.
/// The envelope IS a capacitor discharging — amplitude, pitch, timbre, and FM depth
/// all decay from one mechanism.
struct VoltConfig: Codable, Equatable {
    // MARK: - Layer Selection

    var layerA: VoltTopology = .resonant
    var layerB: VoltTopology? = nil   // nil = single layer
    var mix: Double = 0.5             // A/B balance when B active

    // MARK: - RESONANT (10 params)

    var resPitch: Double = 0.3        // 0–1 → 15–500 Hz exponential
    var resSweep: Double = 0.25       // 0–1: voltage leakage rate
    var resDecay: Double = 0.4        // 0–1: feedback gain (0.9 to ~1.0)
    var resDrive: Double = 0.2        // 0–1: BJT saturation depth
    var resPunch: Double = 0.4        // 0–1: trigger pulse energy
    var resHarmonics: Double = 0.0    // 0–1: parabolic waveshaper depth
    var resClick: Double = 0.0        // 0–1: transient click level
    var resNoise: Double = 0.0        // 0–1: transient noise burst level
    var resBody: Double = 0.0         // 0–1: envelope sustain reshaping
    var resTone: Double = 0.0         // 0–1: output LP filter

    // MARK: - NOISE (6 params)

    var noiseColor: Double = 0.5      // 0–1: RC filter cutoff (dark → bright)
    var noiseSnap: Double = 0.5       // 0–1: envelope cap charge rate
    var noiseBody: Double = 0.3       // 0–1: envelope cap discharge rate
    var noiseClap: Double = 0.0       // 0–1: number of envelope caps in burst chain
    var noiseTone: Double = 0.0       // 0–1: tonal component (Schmitt trigger)
    var noiseFilter: Double = 0.0     // 0–1: RC filter resonance

    // MARK: - METALLIC (5 params)

    var metSpread: Double = 0.3       // 0–1: frequency ratio spread between oscillators
    var metTune: Double = 0.5         // 0–1 → 200–16000 Hz: center frequency
    var metRing: Double = 0.3         // 0–1: envelope cap discharge rate
    var metBand: Double = 0.35        // 0–1: bandpass filter Q
    var metDensity: Double = 1.0      // 0–1 → 2–6 oscillators

    // MARK: - TONAL (5 params)

    var tonPitch: Double = 0.4        // 0–1 → 20–2000 Hz: carrier frequency
    var tonFM: Double = 0.3           // 0–1: coupling strength
    var tonShape: Double = 0.25       // 0–1: carrier Soul / operating point
    var tonBend: Double = 0.2         // 0–1: pitch bend cap depth
    var tonDecay: Double = 0.3        // 0–1: envelope cap discharge rate

    // MARK: - Output

    var warm: Double = 0.3            // 0–1: component tolerance / analog imperfection
    var volume: Double = 0.8          // 0–1
    var pan: Double = 0.0             // -1 to +1

    init(
        layerA: VoltTopology = .resonant,
        layerB: VoltTopology? = nil,
        mix: Double = 0.5,
        resPitch: Double = 0.3, resSweep: Double = 0.25, resDecay: Double = 0.4,
        resDrive: Double = 0.2, resPunch: Double = 0.4,
        resHarmonics: Double = 0.0, resClick: Double = 0.0, resNoise: Double = 0.0,
        resBody: Double = 0.0, resTone: Double = 0.0,
        noiseColor: Double = 0.5, noiseSnap: Double = 0.5, noiseBody: Double = 0.3,
        noiseClap: Double = 0.0, noiseTone: Double = 0.0, noiseFilter: Double = 0.0,
        metSpread: Double = 0.3, metTune: Double = 0.5, metRing: Double = 0.3,
        metBand: Double = 0.35, metDensity: Double = 1.0,
        tonPitch: Double = 0.4, tonFM: Double = 0.3, tonShape: Double = 0.25,
        tonBend: Double = 0.2, tonDecay: Double = 0.3,
        warm: Double = 0.3, volume: Double = 0.8, pan: Double = 0.0
    ) {
        self.layerA = layerA
        self.layerB = layerB
        self.mix = mix
        self.resPitch = resPitch; self.resSweep = resSweep; self.resDecay = resDecay
        self.resDrive = resDrive; self.resPunch = resPunch
        self.resHarmonics = resHarmonics; self.resClick = resClick; self.resNoise = resNoise
        self.resBody = resBody; self.resTone = resTone
        self.noiseColor = noiseColor; self.noiseSnap = noiseSnap; self.noiseBody = noiseBody
        self.noiseClap = noiseClap; self.noiseTone = noiseTone; self.noiseFilter = noiseFilter
        self.metSpread = metSpread; self.metTune = metTune; self.metRing = metRing
        self.metBand = metBand; self.metDensity = metDensity
        self.tonPitch = tonPitch; self.tonFM = tonFM; self.tonShape = tonShape
        self.tonBend = tonBend; self.tonDecay = tonDecay
        self.warm = warm; self.volume = volume; self.pan = pan
    }

    // MARK: - Backward-compatible decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layerA = try container.decodeIfPresent(VoltTopology.self, forKey: .layerA) ?? .resonant
        layerB = try container.decodeIfPresent(VoltTopology.self, forKey: .layerB)
        mix = try container.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5
        resPitch = try container.decodeIfPresent(Double.self, forKey: .resPitch) ?? 0.3
        resSweep = try container.decodeIfPresent(Double.self, forKey: .resSweep) ?? 0.25
        resDecay = try container.decodeIfPresent(Double.self, forKey: .resDecay) ?? 0.4
        resDrive = try container.decodeIfPresent(Double.self, forKey: .resDrive) ?? 0.2
        resPunch = try container.decodeIfPresent(Double.self, forKey: .resPunch) ?? 0.4
        resHarmonics = try container.decodeIfPresent(Double.self, forKey: .resHarmonics) ?? 0.0
        resClick = try container.decodeIfPresent(Double.self, forKey: .resClick) ?? 0.0
        resNoise = try container.decodeIfPresent(Double.self, forKey: .resNoise) ?? 0.0
        resBody = try container.decodeIfPresent(Double.self, forKey: .resBody) ?? 0.0
        resTone = try container.decodeIfPresent(Double.self, forKey: .resTone) ?? 0.0
        noiseColor = try container.decodeIfPresent(Double.self, forKey: .noiseColor) ?? 0.5
        noiseSnap = try container.decodeIfPresent(Double.self, forKey: .noiseSnap) ?? 0.5
        noiseBody = try container.decodeIfPresent(Double.self, forKey: .noiseBody) ?? 0.3
        noiseClap = try container.decodeIfPresent(Double.self, forKey: .noiseClap) ?? 0.0
        noiseTone = try container.decodeIfPresent(Double.self, forKey: .noiseTone) ?? 0.0
        noiseFilter = try container.decodeIfPresent(Double.self, forKey: .noiseFilter) ?? 0.0
        metSpread = try container.decodeIfPresent(Double.self, forKey: .metSpread) ?? 0.3
        metTune = try container.decodeIfPresent(Double.self, forKey: .metTune) ?? 0.5
        metRing = try container.decodeIfPresent(Double.self, forKey: .metRing) ?? 0.3
        metBand = try container.decodeIfPresent(Double.self, forKey: .metBand) ?? 0.35
        metDensity = try container.decodeIfPresent(Double.self, forKey: .metDensity) ?? 1.0
        tonPitch = try container.decodeIfPresent(Double.self, forKey: .tonPitch) ?? 0.4
        tonFM = try container.decodeIfPresent(Double.self, forKey: .tonFM) ?? 0.3
        tonShape = try container.decodeIfPresent(Double.self, forKey: .tonShape) ?? 0.25
        tonBend = try container.decodeIfPresent(Double.self, forKey: .tonBend) ?? 0.2
        tonDecay = try container.decodeIfPresent(Double.self, forKey: .tonDecay) ?? 0.3
        warm = try container.decodeIfPresent(Double.self, forKey: .warm) ?? 0.3
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0
    }

    // MARK: - Preset Seeds

    /// Classic 808 kick: deep boom with pitch sweep from cap leakage.
    static let kick808 = VoltConfig(resPitch: 0.25, resSweep: 0.25, resDecay: 0.5, resDrive: 0.2, resPunch: 0.4)
    /// 909 kick: punchy, clicky, tight. Resonant body + noise click.
    static let kick909 = VoltConfig(layerA: .resonant, layerB: .noise, mix: 0.2,
        resPitch: 0.35, resSweep: 0.15, resDecay: 0.25, resDrive: 0.45, resPunch: 0.4,
        noiseColor: 0.7, noiseSnap: 0.8, noiseBody: 0.05)
    /// Self-oscillating sub bass. Tune via MIDI.
    static let subBass = VoltConfig(resPitch: 0.15, resSweep: 0.0, resDecay: 0.8, resDrive: 0.1, resPunch: 0.1)
    /// Analog snare: resonant body + noise wires.
    static let analogSnare = VoltConfig(layerA: .resonant, layerB: .noise, mix: 0.5,
        resPitch: 0.55, resDecay: 0.2,
        noiseColor: 0.6, noiseSnap: 0.7, noiseBody: 0.3, noiseTone: 0.25)
    /// Trap snare: bright, long, tonal noise.
    static let trapSnare = VoltConfig(layerA: .noise,
        noiseColor: 0.75, noiseSnap: 0.9, noiseBody: 0.45, noiseTone: 0.4, noiseFilter: 0.3)
    /// 808 clap: multi-burst sequential cap discharge.
    static let clap808 = VoltConfig(layerA: .noise,
        noiseColor: 0.55, noiseSnap: 0.5, noiseBody: 0.5, noiseClap: 0.55, noiseFilter: 0.15)
    /// Closed hi-hat: tight 808 shimmer.
    static let closedHat = VoltConfig(layerA: .metallic,
        metSpread: 0.3, metTune: 0.6, metRing: 0.05, metBand: 0.35, metDensity: 1.0)
    /// Open hi-hat: same circuits, longer envelope cap.
    static let openHat = VoltConfig(layerA: .metallic,
        metSpread: 0.3, metTune: 0.6, metRing: 0.5, metBand: 0.3, metDensity: 1.0)
    /// Cowbell: two Schmitt triggers beating.
    static let cowbell = VoltConfig(layerA: .metallic,
        metSpread: 0.08, metTune: 0.3, metRing: 0.3, metBand: 0.65, metDensity: 0.0)
    /// Crash cymbal: metallic shimmer + noise attack.
    static let crash = VoltConfig(layerA: .metallic, layerB: .noise, mix: 0.7,
        noiseColor: 0.7, noiseSnap: 0.8, noiseBody: 0.05,
        metSpread: 0.6, metTune: 0.45, metRing: 0.7, metDensity: 1.0)
    /// Rim shot: sharp crack + pitched ring.
    static let rimShot = VoltConfig(layerA: .noise, layerB: .resonant, mix: 0.4,
        resPitch: 0.65, resDecay: 0.05,
        noiseColor: 0.8, noiseSnap: 1.0, noiseBody: 0.05)
    /// Classic electronic bleep.
    static let bleep = VoltConfig(layerA: .tonal,
        tonPitch: 0.5, tonFM: 0.3, tonShape: 0.15, tonBend: 0.2, tonDecay: 0.25)
    /// Dramatic pitch sweep zap.
    static let zap = VoltConfig(resPitch: 0.65, resSweep: 0.9, resDecay: 0.15, resDrive: 0.5, resPunch: 0.8)
    /// Deep tom: dual-layer resonant + tonal.
    static let deepTom = VoltConfig(layerA: .resonant, layerB: .tonal, mix: 0.4,
        resPitch: 0.4, resSweep: 0.3, resDecay: 0.35,
        tonPitch: 0.38, tonDecay: 0.3)
    /// Glitchy, chaotic, alien.
    static let circuitBent = VoltConfig(layerA: .tonal, layerB: .metallic, mix: 0.55,
        metSpread: 0.7, metDensity: 0.5,
        tonFM: 0.8, tonShape: 0.6, tonBend: 0.5)
    /// Soft, dark, gentle.
    static let brush = VoltConfig(layerA: .noise,
        noiseColor: 0.3, noiseSnap: 0.1, noiseBody: 0.6, noiseFilter: 0.05)
    /// Maximum aggression.
    static let industrial = VoltConfig(layerA: .resonant, layerB: .noise, mix: 0.5,
        resDrive: 0.95, resPunch: 1.0,
        noiseColor: 0.9, noiseSnap: 1.0)
    /// Low, sustained, shimmering gong.
    static let gong = VoltConfig(layerA: .metallic, layerB: .resonant, mix: 0.6,
        resPitch: 0.3, resDecay: 0.7,
        metSpread: 0.45, metTune: 0.2, metRing: 0.85, metDensity: 1.0)
    /// Jomox-style kick: harmonics + click + fat body.
    static let jomoxKick = VoltConfig(
        resPitch: 0.3, resSweep: 0.3, resDecay: 0.5, resDrive: 0.3, resPunch: 0.5,
        resHarmonics: 0.6, resClick: 0.4, resNoise: 0.15, resBody: 0.5, resTone: 0.2)
    /// Sub-bass: ultra-deep (15 Hz range) with body sustain.
    static let subKick = VoltConfig(
        resPitch: 0.1, resSweep: 0.15, resDecay: 0.7, resDrive: 0.1, resPunch: 0.3,
        resBody: 0.7, resTone: 0.6)
}

// MARK: - 8-Slot Drum Kit

/// 8-voice drum kit configuration wrapping independent VoltConfig per slot.
/// Same architecture as DrumKitConfig for FM drums: fixed MIDI mapping, per-slot params.
struct VoltDrumKitConfig: Codable, Equatable {
    var voices: [VoltConfig]  // exactly 8

    static let voiceNames = ["KICK", "SNARE", "C.HAT", "O.HAT", "TOM L", "TOM H", "CRASH", "RIDE"]
    static let midiPitches = [36, 38, 42, 46, 41, 43, 49, 51]

    static func defaultKit() -> VoltDrumKitConfig {
        VoltDrumKitConfig(voices: [
            .kick808,       // KICK
            .analogSnare,   // SNARE
            .closedHat,     // C.HAT
            .openHat,       // O.HAT
            .deepTom,       // TOM L
            {               // TOM H — higher tuned
                var t = VoltConfig.deepTom
                t.resPitch = 0.5
                t.tonPitch = 0.48
                return t
            }(),
            .crash,         // CRASH
            .cowbell,       // RIDE
        ])
    }

    /// Map a MIDI pitch to a voice index. Returns -1 if no match.
    static func voiceIndex(forPitch pitch: Int) -> Int {
        for i in 0..<midiPitches.count {
            if midiPitches[i] == pitch { return i }
        }
        return -1
    }
}
