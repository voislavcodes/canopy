import SwiftUI

/// Bloom panel: FUSE virtual analog circuit synthesis controls.
/// 5 circuit parameters (Soul, Tune, Couple, Body, Color) + WARM + Volume/Pan output section.
/// Uses same local-drag-state pattern as FlowPanel / WestCoastPanel.
struct FusePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    @State private var localSoul: Double = 0.25
    @State private var localTune: Double = 0.05
    @State private var localCouple: Double = 0.08
    @State private var localBody: Double = 0.15
    @State private var localColor: Double = 0.35
    @State private var localWarm: Double = 0.3
    @State private var localKeyTracking: Bool = true
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var fuseConfig: FuseConfig? {
        guard let patch else { return nil }
        if case .fuse(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeFuse

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("FUSE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse")],
                    current: "fuse",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "osc" {
                            projectState.swapEngine(nodeID: nodeID, to: .oscillator(OscillatorConfig()))
                        } else if type == "drum" {
                            projectState.swapEngine(nodeID: nodeID, to: .drumKit(DrumKitConfig()))
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
                        }
                    }
                )
            }

            if fuseConfig != nil {
                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Circuit
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("CIRCUIT")

                        paramSlider(label: "SOUL", value: $localSoul, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.soul = localSoul }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "TUNE", value: $localTune, range: 0...1,
                                    format: { tuneDisplayText($0) }) {
                            commitConfig { $0.tune = localTune }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "CPLE", value: $localCouple, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.couple = localCouple }
                        } onDrag: { pushConfigToEngine() }

                        HStack(spacing: 4 * cs) {
                            Text("KEY")
                                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                                .frame(width: 38 * cs, alignment: .trailing)

                            Button(action: {
                                localKeyTracking.toggle()
                                commitConfig { $0.keyTracking = localKeyTracking }
                            }) {
                                Text(localKeyTracking ? "TRACK" : "FREE")
                                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                                    .foregroundColor(localKeyTracking ? accentColor : CanopyColors.chromeText.opacity(0.6))
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Body + Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("RESONANCE")

                        paramSlider(label: "BODY", value: $localBody, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.body = localBody }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "COLR", value: $localColor, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.color = localColor }
                        } onDrag: { pushConfigToEngine() }

                        sectionDivider

                        outputSection
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 360 * cs)
        .fixedSize(horizontal: false, vertical: true)
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
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = fuseConfig else { return }
        localSoul = config.soul
        localTune = config.tune
        localCouple = config.couple
        localBody = config.body
        localColor = config.color
        localWarm = config.warm
        localKeyTracking = config.keyTracking
        localVolume = config.volume
        localPan = config.pan
        guard let p = patch else { return }
        localVolume = p.volume
        localPan = p.pan
    }

    // MARK: - Section Divider

    private var sectionDivider: some View {
        Divider()
            .background(CanopyColors.bloomPanelBorder.opacity(0.3))
    }

    // MARK: - Output Section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("OUTPUT")

            paramSlider(label: "WARM", value: $localWarm, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.warm = localWarm }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "VOL", value: $localVolume, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitPatch { $0.volume = localVolume }
                commitConfig { $0.volume = localVolume }
            } onDrag: { pushConfigToEngine() }

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

    // MARK: - Pan Slider

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
                    .fill(accentColor.opacity(0.8))
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
                        commitConfig { $0.pan = localPan }
                    }
            )
        }
        .frame(height: 10 * cs)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor.opacity(0.7))
    }

    // MARK: - Param Slider

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 38 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledWidth = max(0, min(width, width * fraction))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                        .frame(height: 8 * cs)

                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(accentColor.opacity(0.5))
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
                .frame(width: 40 * cs, alignment: .trailing)
        }
    }

    // MARK: - Display Helpers

    private func tuneDisplayText(_ v: Double) -> String {
        if v < 0.10 {
            let cents = (v / 0.10) * 7.0
            return String(format: "%.1fc", cents)
        } else if v < 0.25 {
            let t = (v - 0.10) / 0.15
            let ratio = 1.0 + t * 0.5
            return String(format: "%.2f×", ratio)
        } else if v < 0.50 {
            let t = (v - 0.25) / 0.25
            let ratio = 1.5 + t * 1.5
            return String(format: "%.1f×", ratio)
        } else if v < 0.75 {
            let t = (v - 0.50) / 0.25
            let ratio = 3.0 + t * 4.0
            return String(format: "%.1f×", ratio)
        } else {
            let t = (v - 0.75) / 0.25
            let ratio = 7.0 + t * 10.0
            return String(format: "%.0f×", ratio)
        }
    }

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout FuseConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .fuse(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .fuse(config)
            }
        }
        pushConfigToEngine()
    }

    private func commitPatch(_ transform: (inout SoundPatch) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch)
        }
    }

    private func pushConfigToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        let config = FuseConfig(
            soul: localSoul,
            tune: localTune,
            couple: localCouple,
            body: localBody,
            color: localColor,
            warm: localWarm,
            keyTracking: localKeyTracking,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureFuse(config, nodeID: nodeID)
    }
}
