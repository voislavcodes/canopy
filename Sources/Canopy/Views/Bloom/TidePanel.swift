import SwiftUI

/// Bloom panel: TIDE spectral sequencing synthesizer controls.
/// 4 spectral parameters + pattern selector + output section.
/// Uses same local-drag-state pattern as FlowPanel.
struct TidePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Spectral parameters
    @State private var localCurrent: Double = 0.4
    @State private var localPattern: Int = 0
    @State private var localRate: Double = 0.3
    @State private var localRateSync: Bool = false
    @State private var localRateDivision: TideRateDivision = .oneBar
    @State private var localDepth: Double = 0.6

    // Function generator
    @State private var localFuncShape: TideFuncShape = .off
    @State private var localFuncAmount: Double = 0.0
    @State private var localFuncSkew: Double = 0.5
    @State private var localFuncCycles: Int = 1

    // Output
    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var tideConfig: TideConfig? {
        guard let patch else { return nil }
        if case .tide(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeTide

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("TIDE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("Drum Kit", "drum"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm")],
                    current: "tide",
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
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        }
                    }
                )
            }

            if tideConfig != nil {
                // Pattern selector
                patternSelector

                // Spectral parameters
                VStack(alignment: .leading, spacing: 8 * cs) {
                    sectionLabel("SPECTRAL")

                    paramSlider(label: "CURR", value: $localCurrent, range: 0...1,
                                format: { "\(Int($0 * 100))%" }) {
                        commitConfig { $0.current = localCurrent }
                    } onDrag: { pushConfigToEngine() }

                    rateControl

                    paramSlider(label: "DPTH", value: $localDepth, range: 0...1,
                                format: { "\(Int($0 * 100))%" }) {
                        commitConfig { $0.depth = localDepth }
                    } onDrag: { pushConfigToEngine() }
                }

                sectionDivider

                // Function generator
                funcGenSection

                sectionDivider

                // Output section
                outputSection
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

    // MARK: - Pattern Selector

    private var patternSelector: some View {
        HStack(spacing: 6 * cs) {
            Button(action: {
                localPattern = (localPattern - 1 + TidePatterns.patternCount) % TidePatterns.patternCount
                commitConfig { $0.pattern = localPattern }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10 * cs, weight: .bold))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .buttonStyle(.plain)

            Text(TidePatterns.names[localPattern])
                .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .fill(accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                )

            Button(action: {
                localPattern = (localPattern + 1) % TidePatterns.patternCount
                commitConfig { $0.pattern = localPattern }
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10 * cs, weight: .bold))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rate Control (free / synced)

    private var rateControl: some View {
        VStack(spacing: 4 * cs) {
            // Sync toggle row
            HStack(spacing: 4 * cs) {
                Text("RATE")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 38 * cs, alignment: .trailing)

                Button(action: {
                    localRateSync.toggle()
                    commitConfig {
                        $0.rateSync = localRateSync
                    }
                }) {
                    Text(localRateSync ? "SYNC" : "FREE")
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localRateSync ? accentColor : CanopyColors.chromeText.opacity(0.6))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localRateSync ? accentColor.opacity(0.15) : CanopyColors.bloomPanelBorder.opacity(0.2))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(localRateSync ? accentColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if localRateSync {
                // Beat division selector
                rateDivisionSelector
            } else {
                // Free-running rate slider
                paramSlider(label: "", value: $localRate, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.rate = localRate }
                } onDrag: { pushConfigToEngine() }
            }
        }
    }

    private var rateDivisionSelector: some View {
        HStack(spacing: 3 * cs) {
            ForEach(TideRateDivision.allCases, id: \.self) { division in
                let isSelected = localRateDivision == division
                Button(action: {
                    localRateDivision = division
                    commitConfig { $0.rateDivision = division }
                }) {
                    Text(division.displayName)
                        .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Function Generator Section

    private var funcGenSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("FUNC")

            // Shape selector: row of small buttons
            HStack(spacing: 3 * cs) {
                ForEach(TideFuncShape.allCases, id: \.self) { shape in
                    let isSelected = localFuncShape == shape
                    Button(action: {
                        localFuncShape = shape
                        commitConfig { $0.funcShape = shape }
                    }) {
                        Text(funcShapeLabel(shape))
                            .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18 * cs)
                            .background(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Show AMT, SKEW, CYCLES only when shape is active
            if localFuncShape != .off {
                paramSlider(label: "AMT", value: $localFuncAmount, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.funcAmount = localFuncAmount }
                } onDrag: { pushConfigToEngine() }

                paramSlider(label: "SKEW", value: $localFuncSkew, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.funcSkew = localFuncSkew }
                } onDrag: { pushConfigToEngine() }

                // Cycles picker
                HStack(spacing: 3 * cs) {
                    Text("CYC")
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 38 * cs, alignment: .trailing)

                    ForEach([1, 2, 4, 8, 16], id: \.self) { count in
                        let isSelected = localFuncCycles == count
                        Button(action: {
                            localFuncCycles = count
                            commitConfig { $0.funcCycles = count }
                        }) {
                            Text("\(count)x")
                                .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .frame(height: 18 * cs)
                                .background(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func funcShapeLabel(_ shape: TideFuncShape) -> String {
        switch shape {
        case .off: return "OFF"
        case .sine: return "SIN"
        case .triangle: return "TRI"
        case .rampDown: return "\u{2193}"
        case .rampUp: return "\u{2191}"
        case .square: return "SQ"
        case .sAndH: return "S&H"
        }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = tideConfig else { return }
        localCurrent = config.current
        localPattern = config.pattern
        localRate = config.rate
        localRateSync = config.rateSync
        localRateDivision = config.rateDivision
        localDepth = config.depth
        localFuncShape = config.funcShape
        localFuncAmount = config.funcAmount
        localFuncSkew = config.funcSkew
        localFuncCycles = config.funcCycles
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
                let fraction: CGFloat = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
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

    private func commitConfig(_ transform: (inout TideConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .tide(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .tide(config)
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
        let config = TideConfig(
            current: localCurrent,
            pattern: localPattern,
            rate: localRate,
            rateSync: localRateSync,
            rateDivision: localRateDivision,
            depth: localDepth,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan,
            funcShape: localFuncShape,
            funcAmount: localFuncAmount,
            funcSkew: localFuncSkew,
            funcCycles: localFuncCycles
        )
        AudioEngine.shared.configureTide(config, nodeID: nodeID)
    }
}
