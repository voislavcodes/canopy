import SwiftUI

/// Bloom panel: SWARM engine controls.
/// 4 physics parameters (Gravity, Energy, Flock, Scatter) + output section.
/// 64-dot visualization showing partials in frequency space.
struct SwarmPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Physics
    @State private var localGravity: Double = 0.5
    @State private var localEnergy: Double = 0.3
    @State private var localFlock: Double = 0.2
    @State private var localScatter: Double = 0.3

    // Output
    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.7
    @State private var localPan: Double = 0.0

    // Imprint
    @StateObject private var imprintRecorder = ImprintRecorder()

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var swarmConfig: SwarmConfig? {
        guard let patch else { return nil }
        if case .swarm(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeSwarm

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("SWARM")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Text("\u{2726}")
                    .font(.system(size: 10 * cs))
                    .foregroundColor(accentColor.opacity(0.6))

                ImprintButton(
                    recorder: imprintRecorder,
                    accentColor: accentColor,
                    onImprint: { imprint in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = imprint
                            $0.triggerSource = .imprint
                        }
                        AudioEngine.shared.configureSwarmImprint(
                            positions: imprint.peakRatios,
                            amplitudes: imprint.peakAmplitudes,
                            nodeID: nodeID
                        )
                    },
                    onClear: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = nil
                            $0.triggerSource = .harmonic
                        }
                        AudioEngine.shared.configureSwarmImprint(
                            positions: nil, amplitudes: nil, nodeID: nodeID
                        )
                    },
                    hasImprint: swarmConfig?.triggerSource == .imprint
                )

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("Drum Kit", "drum"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm")],
                    current: "swarm",
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
                        }
                    }
                )
            }

            // Spectral silhouette when imprinted
            if let imprint = swarmConfig?.imprint, swarmConfig?.triggerSource == .imprint {
                SpectralSilhouetteView(values: imprint.peakAmplitudes, accentColor: accentColor)
            }

            if swarmConfig != nil {
                // Visualization: 64 dots on frequency axis
                swarmVisualization
                    .frame(height: 60 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * cs)
                            .fill(Color.black.opacity(0.3))
                    )

                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Physics
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("PHYSICS")

                        paramSlider(label: "GRAV", value: $localGravity, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.gravity = localGravity }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "ENRG", value: $localEnergy, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.energy = localEnergy }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "FLOC", value: $localFlock, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.flock = localFlock }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "SCTR", value: $localScatter, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.scatter = localScatter }
                        } onDrag: { pushConfigToEngine() }
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
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

    // MARK: - Visualization

    /// 64 dots showing partial positions and amplitudes.
    /// Static preview based on current control values (no audio-thread bridge needed).
    private var swarmVisualization: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let w = size.width
                let h = size.height

                // Draw faint harmonic lines
                for harmonic in 1...16 {
                    let x = (CGFloat(harmonic) / 32.0) * w
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    context.stroke(path, with: .color(accentColor.opacity(0.1)), lineWidth: 1)
                }

                // Compute approximate partial positions from control values
                let gravity = Float(localGravity)
                let scatter = Float(localScatter)
                let range = 0.12 + scatter * 0.88
                let timeBits = Int(timeline.date.timeIntervalSinceReferenceDate * 100)
                let seed = UInt32(truncatingIfNeeded: timeBits) &+ 42

                for i in 0..<64 {
                    let harmonicRatio = Float(i + 1)
                    let rangeScale = range * 0.75 + 0.25
                    let basePosition = harmonicRatio * rangeScale

                    // Simple drift simulation based on controls
                    var noiseSeed = seed &+ UInt32(i) &* 2654435761
                    noiseSeed = noiseSeed &* 1664525 &+ 1013904223
                    let noise = Float(Int32(bitPattern: noiseSeed)) / Float(Int32.max)
                    let drift = noise * (1.0 - gravity) * 0.5

                    let position = max(0.5, min(32.0, basePosition + drift))

                    // Amplitude from bloom
                    let nearestHarmonic = roundf(position)
                    let bloom = 0.2 + gravity * 0.6
                    let naturalAmp = 1.0 / max(1.0, Float(i + 1))
                    let harmonicDist = abs(position - nearestHarmonic)
                    let proximityReward = max(0.0, 1.0 - harmonicDist * 4.0 * bloom)
                    let amp = naturalAmp * (1.0 - bloom + bloom * proximityReward)

                    // Map to screen
                    let x = CGFloat(position / 32.0) * w
                    let y = h - CGFloat(amp) * h * 0.85 - h * 0.05

                    let dotSize: CGFloat = max(2 * cs, 3 * cs * CGFloat(amp))
                    let brightness = max(0.2, CGFloat(amp))

                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)),
                        with: .color(accentColor.opacity(brightness))
                    )
                }
            }
        }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = swarmConfig else { return }
        localGravity = config.gravity
        localEnergy = config.energy
        localFlock = config.flock
        localScatter = config.scatter
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

    private func commitConfig(_ transform: (inout SwarmConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .swarm(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .swarm(config)
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
        let config = SwarmConfig(
            gravity: localGravity,
            energy: localEnergy,
            flock: localFlock,
            scatter: localScatter,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureSwarm(config, nodeID: nodeID)
    }
}
