import Foundation

/// Color identity for a preset, mapped to theme colors.
enum PresetColor: String, Codable, CaseIterable, Equatable {
    case blue
    case purple
    case orange
    case green
    case cyan
    case pink
    case indigo
}

/// Static preset definitions that give each branch a character.
/// Only `presetID` is persisted on Node — all other properties are derived at runtime.
struct NodePreset: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let color: PresetColor
    let nodeType: NodeType
    let defaultPatch: SoundPatch
    let defaultLengthInBeats: Double
    let defaultPitchRange: PitchRange
    let defaultArpConfig: ArpConfig?

    /// All built-in presets.
    static let builtIn: [NodePreset] = [
        NodePreset(
            id: "melody",
            name: "Melody",
            icon: "music.note",
            color: .blue,
            nodeType: .melodic,
            defaultPatch: SoundPatch(
                name: "Melody",
                soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
                envelope: EnvelopeConfig(attack: 0.01, decay: 0.15, sustain: 0.6, release: 0.3),
                filter: FilterConfig(enabled: true, cutoff: 4000, resonance: 0.0)
            ),
            defaultLengthInBeats: 4,
            defaultPitchRange: PitchRange(low: 60, high: 84), // C4–C6
            defaultArpConfig: nil
        ),
        NodePreset(
            id: "bass",
            name: "Bass",
            icon: "speaker.wave.2",
            color: .purple,
            nodeType: .harmonic,
            defaultPatch: SoundPatch(
                name: "Bass",
                soundType: .oscillator(OscillatorConfig(waveform: .square)),
                envelope: EnvelopeConfig(attack: 0.02, decay: 0.2, sustain: 0.8, release: 0.2),
                filter: FilterConfig(enabled: true, cutoff: 800, resonance: 0.0)
            ),
            defaultLengthInBeats: 4,
            defaultPitchRange: PitchRange(low: 28, high: 48), // E1–C3
            defaultArpConfig: nil
        ),
        NodePreset(
            id: "drums",
            name: "Drums",
            icon: "circle.grid.2x2",
            color: .orange,
            nodeType: .rhythmic,
            defaultPatch: SoundPatch(
                name: "Drums",
                soundType: .drumKit(DrumKitConfig()),
                envelope: EnvelopeConfig(attack: 0.001, decay: 0.1, sustain: 0.0, release: 0.05)
            ),
            defaultLengthInBeats: 4,
            defaultPitchRange: PitchRange(low: 36, high: 52), // C2–E3
            defaultArpConfig: nil
        ),
        NodePreset(
            id: "pad",
            name: "Pad",
            icon: "cloud",
            color: .green,
            nodeType: .melodic,
            defaultPatch: SoundPatch(
                name: "Pad",
                soundType: .oscillator(OscillatorConfig(waveform: .sine)),
                envelope: EnvelopeConfig(attack: 0.8, decay: 0.3, sustain: 0.7, release: 1.5)
            ),
            defaultLengthInBeats: 8,
            defaultPitchRange: PitchRange(low: 48, high: 72), // C3–C5
            defaultArpConfig: nil
        ),
        NodePreset(
            id: "arp",
            name: "Arp",
            icon: "waveform.path.ecg",
            color: .cyan,
            nodeType: .melodic,
            defaultPatch: SoundPatch(
                name: "Arp",
                soundType: .oscillator(OscillatorConfig(waveform: .triangle)),
                envelope: EnvelopeConfig(attack: 0.005, decay: 0.1, sustain: 0.4, release: 0.4),
                filter: FilterConfig(enabled: true, cutoff: 6000, resonance: 0.0)
            ),
            defaultLengthInBeats: 4,
            defaultPitchRange: PitchRange(low: 48, high: 84), // C3–C6
            defaultArpConfig: ArpConfig(mode: .up, rate: .sixteenth, octaveRange: 1, gateLength: 0.5)
        ),
        NodePreset(
            id: "west",
            name: "West",
            icon: "waveform.path.ecg.rectangle",
            color: .indigo,
            nodeType: .melodic,
            defaultPatch: SoundPatch(
                name: "West",
                soundType: .westCoast(WestCoastConfig())
            ),
            defaultLengthInBeats: 8,
            defaultPitchRange: PitchRange(low: 48, high: 84), // C3–C6
            defaultArpConfig: nil
        ),
    ]

    /// Lookup a preset by ID.
    static func find(_ id: String) -> NodePreset? {
        builtIn.first { $0.id == id }
    }
}
