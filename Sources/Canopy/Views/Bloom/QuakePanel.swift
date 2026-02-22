import SwiftUI

/// Bloom panel: QUAKE physics-based percussion engine controls.
/// Per-voice physics sliders (Mass, Surface, Force, Sustain) for each of 8 drum voices.
/// Voice selector buttons with audition. Volume and pan output controls.
struct QuakePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    @State private var selectedVoiceIndex: Int = 0

    // Per-voice local drag state
    @State private var localMass: Double = 0.5
    @State private var localSurface: Double = 0.3
    @State private var localForce: Double = 0.5
    @State private var localSustain: Double = 0.3

    // Global output
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var quakeConfig: QuakeConfig? {
        guard let patch else { return nil }
        if case .quake(let config) = patch.soundType { return config }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            HStack {
                Text("QUAKE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse")],
                    current: "quake",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "osc" {
                            projectState.swapEngine(nodeID: nodeID, to: .oscillator(OscillatorConfig()))
                        } else if type == "drum" {
                            projectState.swapEngine(nodeID: nodeID, to: .drumKit(DrumKitConfig()))
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
                        }
                    }
                )
            }

            if quakeConfig != nil {
                // Voice selector
                voiceSelector

                Divider()
                    .background(CanopyColors.bloomPanelBorder.opacity(0.3))

                // Per-voice physics controls
                physicsSliders

                Divider()
                    .background(CanopyColors.bloomPanelBorder.opacity(0.3))

                // Output controls
                outputControls
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
        guard let config = quakeConfig else { return }
        localVolume = config.volume
        localPan = config.pan
        syncVoiceFromModel()
    }

    private func syncVoiceFromModel() {
        guard let config = quakeConfig,
              selectedVoiceIndex < config.voices.count else { return }
        let slot = config.voices[selectedVoiceIndex]
        localMass = slot.mass
        localSurface = slot.surface
        localForce = slot.force
        localSustain = slot.sustain
    }

    // MARK: - Voice Selector

    private var voiceSelector: some View {
        let names = QuakeVoiceManager.voiceNames
        let quakeColor = CanopyColors.nodeRhythmic

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3 * cs), count: 4), spacing: 3 * cs) {
            ForEach(0..<QuakeVoiceManager.voiceCount, id: \.self) { i in
                let isSelected = selectedVoiceIndex == i
                Button(action: {
                    selectedVoiceIndex = i
                    // Audition: trigger voice via audio engine
                    guard let nodeID = projectState.selectedNodeID else { return }
                    let pitch = QuakeVoiceManager.midiPitches[i]
                    AudioEngine.shared.noteOn(pitch: pitch, velocity: 0.8, nodeID: nodeID)
                }) {
                    Text(names[i])
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isSelected ? quakeColor.opacity(0.5) : quakeColor.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isSelected ? quakeColor.opacity(0.8) : quakeColor.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Physics Sliders

    private var physicsSliders: some View {
        let quakeColor = CanopyColors.nodeRhythmic

        return VStack(spacing: 5 * cs) {
            paramSlider(label: "MASS", value: $localMass, range: 0...1, color: quakeColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.mass = localMass }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "SURFACE", value: $localSurface, range: 0...1, color: quakeColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.surface = localSurface }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "FORCE", value: $localForce, range: 0...1, color: quakeColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.force = localForce }
            } onDrag: {
                pushVoiceToEngine()
            }

            paramSlider(label: "SUSTAIN", value: $localSustain, range: 0...1, color: quakeColor, format: { "\(Int($0 * 100))%" }) {
                commitVoice { $0.sustain = localSustain }
            } onDrag: {
                pushVoiceToEngine()
            }
        }
    }

    // MARK: - Output Controls

    private var outputControls: some View {
        VStack(spacing: 5 * cs) {
            paramSlider(label: "VOL", value: $localVolume, range: 0...1, color: CanopyColors.nodeRhythmic, format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.volume = localVolume }
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
                        commitConfig { $0.pan = localPan }
                    }
            )
        }
        .frame(height: 10 * cs)
    }

    // MARK: - Param Slider

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              color: Color, format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 48 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
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
                            value.wrappedValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
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
                .frame(width: 36 * cs, alignment: .trailing)
        }
    }

    // MARK: - Commit Helpers

    /// Commit per-voice physics controls to the model.
    private func commitVoice(_ transform: (inout QuakeVoiceSlot) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .quake(var config) = node.patch.soundType,
               selectedVoiceIndex < config.voices.count {
                transform(&config.voices[selectedVoiceIndex])
                node.patch.soundType = .quake(config)
            }
        }
        pushVoiceToEngine()
    }

    /// Commit global config (volume, pan) to the model.
    private func commitConfig(_ transform: (inout QuakeConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .quake(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .quake(config)
            }
        }
    }

    /// Push current voice's physics controls to the audio engine.
    private func pushVoiceToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        AudioEngine.shared.configureQuakeVoice(
            index: selectedVoiceIndex,
            mass: localMass, surface: localSurface,
            force: localForce, sustain: localSustain,
            nodeID: nodeID
        )
    }
}
