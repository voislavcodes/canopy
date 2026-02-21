import SwiftUI

/// Bloom panel: FLOW engine controls.
/// 5 fluid dynamics parameters + volume/pan output section.
/// Uses same local-drag-state pattern as WestCoastPanel.
struct FlowPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Fluid parameters
    @State private var localCurrent: Double = 0.2
    @State private var localViscosity: Double = 0.5
    @State private var localObstacle: Double = 0.3
    @State private var localChannel: Double = 0.5
    @State private var localDensity: Double = 0.5

    // Output
    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    // Imprint
    @StateObject private var imprintRecorder = ImprintRecorder()

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var flowConfig: FlowConfig? {
        guard let patch else { return nil }
        if case .flow(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeFlow

    /// Compute approximate regime label from current parameters.
    private var regimeLabel: (String, Color) {
        let currentScaled = max(localCurrent * 10.0, 0.001)
        let viscosityScaled = max(localViscosity * 5.0, 0.001)
        let channelScaled = max(localChannel * 2.0, 0.001)
        let densityScaled = max(localDensity * 2.0, 0.001)
        let re = (currentScaled * densityScaled * channelScaled) / viscosityScaled

        if re < 30 {
            return ("LAMINAR", Color(red: 0.3, green: 0.8, blue: 0.9))
        } else if re < 350 {
            return ("TRANSITION", Color(red: 0.9, green: 0.7, blue: 0.3))
        } else {
            return ("TURBULENT", Color(red: 0.9, green: 0.35, blue: 0.3))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("FLOW")
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
                        AudioEngine.shared.configureFlowImprint(imprint.harmonicAmplitudes, nodeID: nodeID)
                    },
                    onClear: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = nil
                            $0.spectralSource = .default
                        }
                        AudioEngine.shared.configureFlowImprint(nil, nodeID: nodeID)
                    },
                    hasImprint: flowConfig?.spectralSource == .imprint
                )

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm")],
                    current: "flow",
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
                        } else if type == "tide" {
                            projectState.swapEngine(nodeID: nodeID, to: .tide(TideConfig()))
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        }
                    }
                )
            }

            // Spectral silhouette when imprinted
            if let imprint = flowConfig?.imprint, flowConfig?.spectralSource == .imprint {
                SpectralSilhouetteView(values: imprint.harmonicAmplitudes, accentColor: accentColor)
            }

            if flowConfig != nil {
                // Regime indicator
                let regime = regimeLabel
                Text(regime.0)
                    .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(regime.1)
                    .padding(.horizontal, 8 * cs)
                    .padding(.vertical, 2 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 3 * cs)
                            .fill(regime.1.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3 * cs)
                            .stroke(regime.1.opacity(0.3), lineWidth: 1)
                    )

                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Fluid
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("FLUID")

                        paramSlider(label: "CURR", value: $localCurrent, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.current = localCurrent }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "VISC", value: $localViscosity, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.viscosity = localViscosity }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "DENS", value: $localDensity, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.density = localDensity }
                        } onDrag: { pushConfigToEngine() }
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Geometry + Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("GEOMETRY")

                        paramSlider(label: "OBST", value: $localObstacle, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.obstacle = localObstacle }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "CHAN", value: $localChannel, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.channel = localChannel }
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
        guard let config = flowConfig else { return }
        localCurrent = config.current
        localViscosity = config.viscosity
        localObstacle = config.obstacle
        localChannel = config.channel
        localDensity = config.density
        localWarmth = config.warmth
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
                              logarithmic: Bool = false,
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
                        .fill(accentColor.opacity(0.5))
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

    private func commitConfig(_ transform: (inout FlowConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .flow(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .flow(config)
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
        let config = FlowConfig(
            current: localCurrent,
            viscosity: localViscosity,
            obstacle: localObstacle,
            channel: localChannel,
            density: localDensity,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureFlow(config, nodeID: nodeID)
    }
}
