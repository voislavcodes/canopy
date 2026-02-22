import SwiftUI

/// Bloom panel: West Coast complex oscillator controls.
/// Signal-flow ordered sections: oscillator, FM, ring mod, wavefolder, LPG, function gen, output.
/// Uses same local-drag-state pattern as SynthControlsPanel.
struct WestCoastPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Oscillator
    @State private var localPrimaryWaveform: WCWaveform = .sine
    @State private var localModRatio: Double = 1.0
    @State private var localFineTune: Double = 0

    // FM
    @State private var localFMDepth: Double = 3.0
    @State private var localEnvToFM: Double = 0.5

    // Ring mod
    @State private var localRingMix: Double = 0.0

    // Wavefolder
    @State private var localFoldAmount: Double = 0.3
    @State private var localFoldStages: Int = 2
    @State private var localFoldSymmetry: Double = 0.5
    @State private var localModToFold: Double = 0.0

    // LPG
    @State private var localLPGMode: LPGMode = .both
    @State private var localStrike: Double = 0.7
    @State private var localDamp: Double = 0.4
    @State private var localColor: Double = 0.6

    // Function gen
    @State private var localRise: Double = 0.005
    @State private var localFall: Double = 0.3
    @State private var localFuncShape: FuncShape = .exponential
    @State private var localFuncLoop: Bool = false

    // Output
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var westCoastConfig: WestCoastConfig? {
        guard let patch else { return nil }
        if case .westCoast(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeWest

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("WEST COAST")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt")],
                    current: "west",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "osc" {
                            projectState.swapEngine(nodeID: nodeID, to: .oscillator(OscillatorConfig()))
                        } else if type == "drum" {
                            projectState.swapEngine(nodeID: nodeID, to: .drumKit(DrumKitConfig()))
                        } else if type == "quake" {
                            projectState.swapEngine(nodeID: nodeID, to: .quake(QuakeConfig()))
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
                            projectState.swapEngine(nodeID: nodeID, to: .volt(VoltDrumKitConfig.defaultKit()))
                        }
                    }
                )
            }

            if westCoastConfig != nil {
                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Timbre path
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        oscillatorSection
                        sectionDivider
                        fmSection
                        sectionDivider
                        ringModSection
                        sectionDivider
                        waveFolderSection
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Dynamics path
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        lpgSection
                        sectionDivider
                        funcGenSection
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
        guard let config = westCoastConfig else { return }
        localPrimaryWaveform = config.primaryWaveform
        localModRatio = config.modulatorRatio
        localFineTune = config.modulatorFineTune
        localFMDepth = config.fmDepth
        localEnvToFM = config.envToFM
        localRingMix = config.ringModMix
        localFoldAmount = config.foldAmount
        localFoldStages = config.foldStages
        localFoldSymmetry = config.foldSymmetry
        localModToFold = config.modToFold
        localLPGMode = config.lpgMode
        localStrike = config.strike
        localDamp = config.damp
        localColor = config.color
        localRise = config.rise
        localFall = config.fall
        localFuncShape = config.funcShape
        localFuncLoop = config.funcLoop
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

    // MARK: - Oscillator Section

    private var oscillatorSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("OSCILLATOR")

            // Waveform picker: sine / triangle
            HStack(spacing: 6 * cs) {
                waveformButton("sin", wf: .sine)
                waveformButton("tri", wf: .triangle)
            }

            paramSlider(label: "RATIO", value: $localModRatio, range: 0.1...16.0,
                        format: { String(format: "%.3f", $0) }) {
                commitConfig { $0.modulatorRatio = localModRatio }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "FINE", value: $localFineTune, range: -100...100,
                        format: { String(format: "%.0f¢", $0) }) {
                commitConfig { $0.modulatorFineTune = localFineTune }
            } onDrag: { pushConfigToEngine() }
        }
    }

    private func waveformButton(_ label: String, wf: WCWaveform) -> some View {
        Button(action: {
            localPrimaryWaveform = wf
            commitConfig { $0.primaryWaveform = wf }
        }) {
            Text(label)
                .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(localPrimaryWaveform == wf ? accentColor : CanopyColors.chromeText)
                .padding(.horizontal, 8 * cs)
                .padding(.vertical, 3 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .fill(localPrimaryWaveform == wf ? accentColor.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .stroke(localPrimaryWaveform == wf ? accentColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - FM Section

    private var fmSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("FM")

            paramSlider(label: "DEPTH", value: $localFMDepth, range: 0...20,
                        format: { String(format: "%.1f", $0) }) {
                commitConfig { $0.fmDepth = localFMDepth }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "ENV", value: $localEnvToFM, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.envToFM = localEnvToFM }
            } onDrag: { pushConfigToEngine() }
        }
    }

    // MARK: - Ring Mod Section

    private var ringModSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("RING MOD")

            paramSlider(label: "MIX", value: $localRingMix, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.ringModMix = localRingMix }
            } onDrag: { pushConfigToEngine() }
        }
    }

    // MARK: - Wavefolder Section

    private var waveFolderSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("WAVEFOLDER")

            paramSlider(label: "FOLD", value: $localFoldAmount, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.foldAmount = localFoldAmount }
            } onDrag: { pushConfigToEngine() }

            // Stages picker
            HStack(spacing: 3 * cs) {
                Text("STAGES")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 38 * cs, alignment: .trailing)

                ForEach(1...6, id: \.self) { n in
                    Button(action: {
                        localFoldStages = n
                        commitConfig { $0.foldStages = n }
                    }) {
                        Text("\(n)")
                            .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                            .foregroundColor(localFoldStages == n ? accentColor : CanopyColors.chromeText.opacity(0.5))
                            .frame(width: 16 * cs, height: 16 * cs)
                            .background(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .fill(localFoldStages == n ? accentColor.opacity(0.15) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .stroke(localFoldStages == n ? accentColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            paramSlider(label: "SYM", value: $localFoldSymmetry, range: 0...1,
                        format: { String(format: "%.0f%%", $0 * 100) }) {
                commitConfig { $0.foldSymmetry = localFoldSymmetry }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "M→FLD", value: $localModToFold, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.modToFold = localModToFold }
            } onDrag: { pushConfigToEngine() }
        }
    }

    // MARK: - LPG Section

    private var lpgSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("LPG")

            // Mode picker
            HStack(spacing: 4 * cs) {
                Text("MODE")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 38 * cs, alignment: .trailing)

                lpgModeButton("LPF", mode: .filter)
                lpgModeButton("VCA", mode: .vca)
                lpgModeButton("BOTH", mode: .both)
            }

            paramSlider(label: "STRIKE", value: $localStrike, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.strike = localStrike }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DAMP", value: $localDamp, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.damp = localDamp }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "COLOR", value: $localColor, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.color = localColor }
            } onDrag: { pushConfigToEngine() }
        }
    }

    private func lpgModeButton(_ label: String, mode: LPGMode) -> some View {
        Button(action: {
            localLPGMode = mode
            commitConfig { $0.lpgMode = mode }
        }) {
            Text(label)
                .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(localLPGMode == mode ? accentColor : CanopyColors.chromeText.opacity(0.5))
                .padding(.horizontal, 6 * cs)
                .padding(.vertical, 3 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(localLPGMode == mode ? accentColor.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .stroke(localLPGMode == mode ? accentColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Function Gen Section

    private var funcGenSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            HStack {
                sectionLabel("FUNC GEN")
                Spacer()
                // Loop toggle
                Button(action: {
                    localFuncLoop.toggle()
                    commitConfig { $0.funcLoop = localFuncLoop }
                }) {
                    Text(localFuncLoop ? "LOOP" : "ONE")
                        .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localFuncLoop ? accentColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localFuncLoop ? accentColor.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(localFuncLoop ? accentColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            paramSlider(label: "RISE", value: $localRise, range: 0.001...5.0, logarithmic: true,
                        format: { formatTime($0) }) {
                commitConfig { $0.rise = localRise }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "FALL", value: $localFall, range: 0.01...10.0, logarithmic: true,
                        format: { formatTime($0) }) {
                commitConfig { $0.fall = localFall }
            } onDrag: { pushConfigToEngine() }

            // Shape picker
            HStack(spacing: 4 * cs) {
                Text("SHAPE")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 38 * cs, alignment: .trailing)

                funcShapeButton("LIN", shape: .linear)
                funcShapeButton("EXP", shape: .exponential)
                funcShapeButton("LOG", shape: .logarithmic)
            }
        }
    }

    private func funcShapeButton(_ label: String, shape: FuncShape) -> some View {
        Button(action: {
            localFuncShape = shape
            commitConfig { $0.funcShape = shape }
        }) {
            Text(label)
                .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(localFuncShape == shape ? accentColor : CanopyColors.chromeText.opacity(0.5))
                .padding(.horizontal, 6 * cs)
                .padding(.vertical, 3 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(localFuncShape == shape ? accentColor.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .stroke(localFuncShape == shape ? accentColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Output Section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("OUTPUT")

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

    private func formatTime(_ seconds: Double) -> String {
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        } else {
            return String(format: "%.0fms", seconds * 1000)
        }
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

    private func commitConfig(_ transform: (inout WestCoastConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .westCoast(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .westCoast(config)
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
        let config = WestCoastConfig(
            primaryWaveform: localPrimaryWaveform,
            modulatorRatio: localModRatio,
            modulatorFineTune: localFineTune,
            fmDepth: localFMDepth,
            envToFM: localEnvToFM,
            ringModMix: localRingMix,
            foldAmount: localFoldAmount,
            foldStages: localFoldStages,
            foldSymmetry: localFoldSymmetry,
            modToFold: localModToFold,
            lpgMode: localLPGMode,
            strike: localStrike,
            damp: localDamp,
            color: localColor,
            rise: localRise,
            fall: localFall,
            funcShape: localFuncShape,
            funcLoop: localFuncLoop,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureWestCoast(config, nodeID: nodeID)
    }
}
