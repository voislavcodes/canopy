import SwiftUI

/// Bloom panel: SPORE engine controls.
/// 4 grain parameters + warmth/volume/pan output section.
struct SporePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    @State private var localDensity: Double = 0.5
    @State private var localFocus: Double = 0.5
    @State private var localGrain: Double = 0.4
    @State private var localEvolve: Double = 0.3

    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.7
    @State private var localPan: Double = 0.0

    // Imprint
    @StateObject private var imprintRecorder = ImprintRecorder()

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var sporeConfig: SporeConfig? {
        guard let patch else { return nil }
        if case .spore(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeSpore

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("SPORE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ImprintButton(
                    recorder: imprintRecorder,
                    accentColor: accentColor,
                    onImprint: { imprint in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = imprint
                            $0.spectralSource = .imprint
                        }
                        AudioEngine.shared.configureSporeImprint(imprint.harmonicAmplitudes, nodeID: nodeID)
                    },
                    onClear: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = nil
                            $0.spectralSource = .default
                        }
                        AudioEngine.shared.configureSporeImprint(nil, nodeID: nodeID)
                    },
                    hasImprint: sporeConfig?.spectralSource == .imprint
                )

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore")],
                    current: "spore",
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
                        }
                    }
                )
            }

            // Spectral silhouette when imprinted
            if let imprint = sporeConfig?.imprint, sporeConfig?.spectralSource == .imprint {
                SpectralSilhouetteView(values: imprint.harmonicAmplitudes, accentColor: accentColor)
            }

            if sporeConfig != nil {
                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Source
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("SOURCE")

                        paramSlider(label: "DENS", value: $localDensity, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.density = localDensity }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "FOCS", value: $localFocus, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.focus = localFocus }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "GRNS", value: $localGrain, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.grain = localGrain }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "EVLV", value: $localEvolve, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.evolve = localEvolve }
                        } onDrag: { pushConfigToEngine() }
                    }
                    .frame(maxWidth: .infinity)

                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("OUTPUT")

                        paramSlider(label: "WARM", value: $localWarmth, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.warmth = localWarmth }
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
        guard let config = sporeConfig else { return }
        localDensity = config.density
        localFocus = config.focus
        localGrain = config.grain
        localEvolve = config.evolve
        localWarmth = config.warmth
        localVolume = config.volume
        localPan = config.pan
        guard let p = patch else { return }
        localVolume = p.volume
        localPan = p.pan
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

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout SporeConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .spore(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .spore(config)
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
        let config = SporeConfig(
            density: localDensity,
            focus: localFocus,
            grain: localGrain,
            evolve: localEvolve,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureSpore(config, nodeID: nodeID)
    }
}
