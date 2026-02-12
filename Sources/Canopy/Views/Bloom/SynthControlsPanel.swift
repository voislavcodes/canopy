import SwiftUI

/// Bloom panel: synth controls with waveform picker, sliders.
/// Positioned in canvas space around the selected node.
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
        VStack(alignment: .leading, spacing: 10) {
            Text("SYNTH")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)

            if let osc = oscillatorConfig, let patch {
                // Volume / level slider
                bloomSlider(value: patch.volume, range: 0...1) { val in
                    updatePatch { $0.volume = val }
                }

                // ADSR compact
                HStack(spacing: 6) {
                    miniSlider(label: "A", value: patch.envelope.attack, range: 0.001...2.0) { val in
                        updateEnvelope { $0.attack = val }
                    }
                    miniSlider(label: "D", value: patch.envelope.decay, range: 0.001...2.0) { val in
                        updateEnvelope { $0.decay = val }
                    }
                    miniSlider(label: "S", value: patch.envelope.sustain, range: 0...1.0) { val in
                        updateEnvelope { $0.sustain = val }
                    }
                    miniSlider(label: "R", value: patch.envelope.release, range: 0.01...5.0) { val in
                        updateEnvelope { $0.release = val }
                    }
                }

                // Waveform label
                Text("waveform")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))

                // Waveform text buttons
                waveformPicker(current: osc.waveform)
            }
        }
        .padding(14)
        .frame(width: 220)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Waveform Picker

    private func waveformPicker(current: Waveform) -> some View {
        HStack(spacing: 6) {
            ForEach(waveformOptions, id: \.0) { (label, wf) in
                Button(action: {
                    updateOscillator { $0.waveform = wf }
                }) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(current == wf ? CanopyColors.glowColor : CanopyColors.chromeText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(current == wf ? CanopyColors.glowColor.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    current == wf ? CanopyColors.glowColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var waveformOptions: [(String, Waveform)] {
        [("saw", .sawtooth), ("sq", .square), ("tri", .triangle), ("sin", .sine)]
    }

    // MARK: - Sliders

    private func bloomSlider(value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let filledWidth = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8)

                // Filled portion
                RoundedRectangle(cornerRadius: 3)
                    .fill(CanopyColors.glowColor.opacity(0.6))
                    .frame(width: filledWidth, height: 8)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = max(0, min(1, drag.location.x / width))
                        let newValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                        onChange(newValue)
                    }
            )
        }
        .frame(height: 8)
    }

    private func miniSlider(label: String, value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            GeometryReader { geo in
                let height = geo.size.height
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledHeight = max(0, min(height, height * fraction))

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(CanopyColors.glowColor.opacity(0.4))
                        .frame(height: filledHeight)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = max(0, min(1, 1 - drag.location.y / height))
                            let newValue = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                            onChange(newValue)
                        }
                )
            }
            .frame(width: 16, height: 32)
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
        if case .oscillator(let config) = patch.soundType {
            AudioEngine.shared.configurePatch(
                waveform: waveformToIndex(config.waveform),
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

extension Waveform: CaseIterable {
    static var allCases: [Waveform] {
        [.sine, .triangle, .sawtooth, .square, .noise]
    }
}
