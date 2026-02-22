import SwiftUI

/// Bloom panel: FUSE engine controls.
/// 5 coupled oscillator parameters + volume/pan/warmth output section.
/// Uses same local-drag-state pattern as FlowPanel.
struct FusePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Coupled oscillator parameters
    @State private var localCharacter: Double = 0.1
    @State private var localTune: Double = 0.0
    @State private var localMatrix: Double = 0.0
    @State private var localFilter: Double = 0.7
    @State private var localFeedback: Double = 0.0
    @State private var localFilterFB: Double = 0.0

    // Envelope
    @State private var localAttack: Double = 0.1
    @State private var localDecay: Double = 0.5

    // Output
    @State private var localWarmth: Double = 0.3
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
                    // Left column: Coupled oscillator controls
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("OSCILLATORS")

                        paramSlider(label: "CHAR", value: $localCharacter, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.character = localCharacter }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "TUNE", value: $localTune, range: 0...1,
                                    format: { tuneDisplayText($0) }) {
                            commitConfig { $0.tune = localTune }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "MTRX", value: $localMatrix, range: 0...1,
                                    format: { matrixDisplayText($0) }) {
                            commitConfig { $0.matrix = localMatrix }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "FILT", value: $localFilter, range: 0...1,
                                    format: { filterDisplayText($0) }) {
                            commitConfig { $0.filter = localFilter }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "FDBK", value: $localFeedback, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.feedback = localFeedback }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "FLFB", value: $localFilterFB, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.filterFB = localFilterFB }
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

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = fuseConfig else { return }
        localCharacter = config.character
        localTune = config.tune
        localMatrix = config.matrix
        localFilter = config.filter
        localFeedback = config.feedback
        localFilterFB = config.filterFB
        localAttack = config.attack
        localDecay = config.decay
        localWarmth = config.warmth
        localVolume = config.volume
        localPan = config.pan
        guard let p = patch else { return }
        localVolume = p.volume
        localPan = p.pan
    }

    // MARK: - Output Section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("OUTPUT")

            paramSlider(label: "ATK", value: $localAttack, range: 0...1,
                        format: { attackDisplayText($0) }) {
                commitConfig { $0.attack = localAttack }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DCY", value: $localDecay, range: 0...1,
                        format: { decayDisplayText($0) }) {
                commitConfig { $0.decay = localDecay }
            } onDrag: { pushConfigToEngine() }

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
        let t2 = v * v
        let ratioB = pow(7.3, t2)
        let ratioC = pow(11.7, t2)
        if ratioB < 1.01 {
            // Near-unison: show cents detune
            let cents = 1200.0 * log2(ratioB)
            return String(format: "%.0fc", cents)
        } else {
            return String(format: "1:%.1f:%.1f", ratioB, ratioC)
        }
    }

    private func matrixDisplayText(_ v: Double) -> String {
        if v < 0.05 { return "NONE" }
        if v < 0.2 { return "SYM" }
        if v < 0.45 { return "FM" }
        if v < 0.7 { return "ASYM" }
        if v > 0.95 { return "FULL" }
        return "\(Int(v * 100))%"
    }

    private func attackDisplayText(_ v: Double) -> String {
        let ms = 1.0 * pow(500.0, v)
        if ms < 10 { return String(format: "%.1fms", ms) }
        if ms < 1000 { return "\(Int(ms))ms" }
        return String(format: "%.1fs", ms / 1000.0)
    }

    private func decayDisplayText(_ v: Double) -> String {
        let ms = 50.0 * pow(100.0, v)
        if ms < 1000 { return "\(Int(ms))ms" }
        return String(format: "%.1fs", ms / 1000.0)
    }

    private func filterDisplayText(_ v: Double) -> String {
        let hz = 60.0 * pow(300.0, v)
        if hz < 1000 { return "\(Int(hz))Hz" }
        if hz >= 17000 { return "OPEN" }
        return String(format: "%.1fk", hz / 1000.0)
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
            character: localCharacter,
            tune: localTune,
            matrix: localMatrix,
            filter: localFilter,
            feedback: localFeedback,
            filterFB: localFilterFB,
            attack: localAttack,
            decay: localDecay,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureFuse(config, nodeID: nodeID)
    }
}
