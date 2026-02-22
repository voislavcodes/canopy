import SwiftUI

/// Bloom panel: FM drum voice editor with per-voice parameter sliders.
/// Voice selector: 8 small labeled buttons. Per-voice sliders for FM synthesis parameters.
/// Uses same local-drag-state pattern as SynthControlsPanel.
struct DrumVoicePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    @State private var selectedVoiceIndex: Int = 0

    // Local drag state for continuous sliders
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0
    @State private var localCarrierFreq: Double = 180
    @State private var localModRatio: Double = 1.5
    @State private var localFMDepth: Double = 5.0
    @State private var localNoiseMix: Double = 0.0
    @State private var localAmpDecay: Double = 0.3
    @State private var localPitchEnv: Double = 2.0
    @State private var localPitchDecay: Double = 0.05
    @State private var localLevel: Double = 0.8

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var drumKitConfig: DrumKitConfig? {
        guard let patch else { return nil }
        if case .drumKit(let config) = patch.soundType { return config }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            HStack {
                Text("FM DRUM")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt")],
                    current: "drum",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "osc" {
                            projectState.swapEngine(nodeID: nodeID, to: .oscillator(OscillatorConfig()))
                        } else if type == "quake" {
                            projectState.swapEngine(nodeID: nodeID, to: .quake(QuakeConfig()))
                        } else if type == "west" {
                            projectState.swapEngine(nodeID: nodeID, to: .westCoast(WestCoastConfig()))
                        } else if type == "flow" {
                            projectState.swapEngine(nodeID: nodeID, to: .flow(FlowConfig()))
                        } else if type == "tide" {
                            projectState.swapEngine(nodeID: nodeID, to: .tide(TideConfig()))
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        } else if type == "spore" {
                            projectState.swapEngine(nodeID: nodeID, to: .spore(SporeConfig()))
                        } else if type == "fuse" {
                            projectState.swapEngine(nodeID: nodeID, to: .fuse(FuseConfig()))
                        } else if type == "volt" {
                            projectState.swapEngine(nodeID: nodeID, to: .volt(VoltConfig()))
                        }
                    }
                )
            }

            if let kit = drumKitConfig {
                // Voice selector
                voiceSelector

                // Per-voice sliders
                voiceSliders(kit: kit)

                Divider()
                    .background(CanopyColors.bloomPanelBorder.opacity(0.3))

                // Global volume/pan
                globalControls
            }
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 220 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear { syncFromModel() }
        .onChange(of: projectState.selectedNodeID) { _ in syncFromModel() }
        .onChange(of: selectedVoiceIndex) { _ in syncVoiceFromModel() }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let patch else { return }
        localVolume = patch.volume
        localPan = patch.pan
        syncVoiceFromModel()
    }

    private func syncVoiceFromModel() {
        guard let kit = drumKitConfig,
              selectedVoiceIndex < kit.voices.count else { return }
        let voice = kit.voices[selectedVoiceIndex]
        localCarrierFreq = voice.carrierFreq
        localModRatio = voice.modulatorRatio
        localFMDepth = voice.fmDepth
        localNoiseMix = voice.noiseMix
        localAmpDecay = voice.ampDecay
        localPitchEnv = voice.pitchEnvAmount
        localPitchDecay = voice.pitchDecay
        localLevel = voice.level
    }

    // MARK: - Voice Selector

    private var voiceSelector: some View {
        let names = FMDrumKit.voiceNames
        let drumColor = CanopyColors.nodeRhythmic

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3 * cs), count: 4), spacing: 3 * cs) {
            ForEach(0..<FMDrumKit.voiceCount, id: \.self) { i in
                let isSelected = selectedVoiceIndex == i
                Button(action: { selectedVoiceIndex = i }) {
                    Text(names[i])
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isSelected ? drumColor.opacity(0.5) : drumColor.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isSelected ? drumColor.opacity(0.8) : drumColor.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Voice Sliders

    @ViewBuilder
    private func voiceSliders(kit: DrumKitConfig) -> some View {
        let drumColor = CanopyColors.nodeRhythmic

        VStack(spacing: 5 * cs) {
            paramSlider(label: "FREQ", value: $localCarrierFreq, range: 20...2000, logarithmic: true, color: drumColor, format: { "\(Int($0))Hz" }) {
                commitVoice { $0.carrierFreq = localCarrierFreq }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "RATIO", value: $localModRatio, range: 0.1...16.0, color: drumColor, format: { String(format: "%.1f", $0) }) {
                commitVoice { $0.modulatorRatio = localModRatio }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "FM", value: $localFMDepth, range: 0...20, color: drumColor, format: { String(format: "%.1f", $0) }) {
                commitVoice { $0.fmDepth = localFMDepth }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "NOISE", value: $localNoiseMix, range: 0...1, color: drumColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.noiseMix = localNoiseMix }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "DECAY", value: $localAmpDecay, range: 0.01...3.0, color: drumColor, format: { String(format: "%.2fs", $0) }) {
                commitVoice { $0.ampDecay = localAmpDecay }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "P.ENV", value: $localPitchEnv, range: 0...8, color: drumColor, format: { String(format: "%.1f", $0) }) {
                commitVoice { $0.pitchEnvAmount = localPitchEnv }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "P.DEC", value: $localPitchDecay, range: 0.001...0.5, color: drumColor, format: { String(format: "%.3fs", $0) }) {
                commitVoice { $0.pitchDecay = localPitchDecay }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "LEVEL", value: $localLevel, range: 0...1, color: drumColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.level = localLevel }
            } onDrag: {
                pushVoiceToEngine()
            }
        }
    }

    // MARK: - Global Controls

    private var globalControls: some View {
        VStack(spacing: 5 * cs) {
            paramSlider(label: "VOL", value: $localVolume, range: 0...1, color: CanopyColors.nodeRhythmic, format: { "\(Int($0 * 100))%" }) {
                commitPatch { $0.volume = localVolume }
            } onDrag: {
                guard let nodeID = projectState.selectedNodeID else { return }
                AudioEngine.shared.setNodeVolume(Float(localVolume), nodeID: nodeID)
            }

            HStack(spacing: 4 * cs) {
                Text("L")
                    .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                panSlider

                Text("R")
                    .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
        }
    }

    private var panSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((localPan + 1) / 2)
            let indicatorX = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8 * cs)

                Rectangle()
                    .fill(CanopyColors.chromeText.opacity(0.2))
                    .frame(width: 1, height: 8 * cs)
                    .position(x: width / 2, y: 4 * cs)

                Circle()
                    .fill(CanopyColors.nodeRhythmic.opacity(0.8))
                    .frame(width: 10 * cs, height: 10 * cs)
                    .position(x: indicatorX, y: 4 * cs)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = max(0, min(1, drag.location.x / width))
                        localPan = Double(frac) * 2 - 1
                        guard let nodeID = projectState.selectedNodeID else { return }
                        AudioEngine.shared.setNodePan(Float(localPan), nodeID: nodeID)
                    }
                    .onEnded { _ in
                        commitPatch { $0.pan = localPan }
                    }
            )
        }
        .frame(height: 10 * cs)
    }

    // MARK: - Param Slider

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              logarithmic: Bool = false, color: Color,
                              format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 38 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction: CGFloat = logarithmic
                    ? CGFloat((log(value.wrappedValue) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
                    : CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledWidth = max(0, min(width, width * fraction))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                        .frame(height: 8 * cs)

                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(color.opacity(0.5))
                        .frame(width: filledWidth, height: 8 * cs)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let frac = Double(max(0, min(1, drag.location.x / width)))
                            if logarithmic {
                                value.wrappedValue = exp(log(range.lowerBound) + frac * (log(range.upperBound) - log(range.lowerBound)))
                            } else {
                                value.wrappedValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                            }
                            onDrag()
                        }
                        .onEnded { _ in
                            onCommit()
                        }
                )
            }
            .frame(height: 8 * cs)

            Text(format(value.wrappedValue))
                .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 40 * cs, alignment: .trailing)
        }
    }

    // MARK: - Commit Helpers

    private func commitVoice(_ transform: (inout DrumVoiceConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .drumKit(var kit) = node.patch.soundType,
               selectedVoiceIndex < kit.voices.count {
                transform(&kit.voices[selectedVoiceIndex])
                node.patch.soundType = .drumKit(kit)
            }
        }
        pushVoiceToEngine()
    }

    private func commitPatch(_ transform: (inout SoundPatch) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch)
        }
    }

    private func pushVoiceToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        let config = DrumVoiceConfig(
            carrierFreq: localCarrierFreq,
            modulatorRatio: localModRatio,
            fmDepth: localFMDepth,
            noiseMix: localNoiseMix,
            ampDecay: localAmpDecay,
            pitchEnvAmount: localPitchEnv,
            pitchDecay: localPitchDecay,
            level: localLevel
        )
        AudioEngine.shared.configureDrumVoice(index: selectedVoiceIndex, config: config, nodeID: nodeID)
    }
}
