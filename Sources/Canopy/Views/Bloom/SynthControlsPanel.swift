import SwiftUI

/// Left bloom panel: waveform picker, detune slider, ADSR envelope, volume.
/// Reads from the selected node's SoundPatch and writes changes back to both
/// the data model (via ProjectState) and the audio engine (via AudioEngine).
struct SynthControlsPanel: View {
    @ObservedObject var projectState: ProjectState

    private var node: Node? {
        projectState.selectedNode
    }

    private var patch: SoundPatch? {
        node?.patch
    }

    private var oscillatorConfig: OscillatorConfig? {
        guard let patch else { return nil }
        if case .oscillator(let config) = patch.soundType {
            return config
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SYNTH")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)

            if let osc = oscillatorConfig, let patch {
                // Waveform picker
                waveformPicker(current: osc.waveform)

                Divider().background(CanopyColors.chromeBorder)

                // Detune
                labeledSlider(label: "DETUNE", value: osc.detune, range: -100...100, suffix: "ct") { val in
                    updateOscillator { $0.detune = val }
                }

                Divider().background(CanopyColors.chromeBorder)

                // ADSR Envelope
                Text("ENVELOPE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                labeledSlider(label: "ATK", value: patch.envelope.attack, range: 0.001...2.0, suffix: "s") { val in
                    updateEnvelope { $0.attack = val }
                }
                labeledSlider(label: "DEC", value: patch.envelope.decay, range: 0.001...2.0, suffix: "s") { val in
                    updateEnvelope { $0.decay = val }
                }
                labeledSlider(label: "SUS", value: patch.envelope.sustain, range: 0...1.0, suffix: "") { val in
                    updateEnvelope { $0.sustain = val }
                }
                labeledSlider(label: "REL", value: patch.envelope.release, range: 0.01...5.0, suffix: "s") { val in
                    updateEnvelope { $0.release = val }
                }

                Divider().background(CanopyColors.chromeBorder)

                // Volume
                labeledSlider(label: "VOL", value: patch.volume, range: 0...1.0, suffix: "") { val in
                    updatePatch { $0.volume = val }
                }
            } else {
                Text("Select a node")
                    .font(.system(size: 12))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }

            Spacer()
        }
        .padding(12)
        .frame(width: 180)
        .background(CanopyColors.chromeBackground)
    }

    // MARK: - Waveform Picker

    private func waveformPicker(current: Waveform) -> some View {
        HStack(spacing: 8) {
            ForEach(Waveform.allCases, id: \.self) { wf in
                Button(action: {
                    updateOscillator { $0.waveform = wf }
                }) {
                    waveformIcon(wf)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(current == wf ? CanopyColors.glowColor.opacity(0.2) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(current == wf ? CanopyColors.glowColor : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func waveformIcon(_ waveform: Waveform) -> some View {
        let color = CanopyColors.chromeTextBright
        switch waveform {
        case .sine:
            Image(systemName: "waveform.path")
                .font(.system(size: 12))
                .foregroundColor(color)
        case .triangle:
            Image(systemName: "triangle")
                .font(.system(size: 12))
                .foregroundColor(color)
        case .sawtooth:
            Image(systemName: "waveform")
                .font(.system(size: 12))
                .foregroundColor(color)
        case .square:
            Image(systemName: "square")
                .font(.system(size: 12))
                .foregroundColor(color)
        case .noise:
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(color)
        }
    }

    // MARK: - Slider Component

    private func labeledSlider(label: String, value: Double, range: ClosedRange<Double>, suffix: String, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)
                Spacer()
                Text(suffix.isEmpty ? String(format: "%.2f", value) : String(format: "%.2f%@", value, suffix))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.7))
            }
            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range)
            .tint(CanopyColors.glowColor)
        }
    }

    // MARK: - Update Helpers

    private func updateOscillator(_ transform: (inout OscillatorConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .oscillator(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .oscillator(config)
            }
        }
        pushPatchToEngine()
    }

    private func updateEnvelope(_ transform: (inout EnvelopeConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch.envelope)
        }
        pushPatchToEngine()
    }

    private func updatePatch(_ transform: (inout SoundPatch) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch)
        }
        pushPatchToEngine()
    }

    private func pushPatchToEngine() {
        guard let patch = projectState.selectedNode?.patch else { return }
        let waveformIndex: Int
        if case .oscillator(let config) = patch.soundType {
            waveformIndex = waveformToIndex(config.waveform)
            AudioEngine.shared.configurePatch(
                waveform: waveformIndex,
                detune: config.detune,
                attack: patch.envelope.attack,
                decay: patch.envelope.decay,
                sustain: patch.envelope.sustain,
                release: patch.envelope.release,
                volume: patch.volume
            )
        }
    }

    private func waveformToIndex(_ wf: Waveform) -> Int {
        switch wf {
        case .sine: return 0
        case .triangle: return 1
        case .sawtooth: return 2
        case .square: return 3
        case .noise: return 4
        }
    }
}

// Make Waveform CaseIterable for the picker
extension Waveform: CaseIterable {
    static var allCases: [Waveform] {
        [.sine, .triangle, .sawtooth, .square, .noise]
    }
}
