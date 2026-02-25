import SwiftUI

/// Bloom panel: SCHMYNTH circuit-modeled subtractive synthesis controls.
/// Reactive ASCII circuit schematic hero + two-column slider layout.
/// Oscillator waveform selector, SCF filter (cutoff/resonance/mode), RC ADSR envelope,
/// WARM + Volume/Pan output section.
struct SchmynthPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    @State private var localWaveform: Int = 0
    @State private var localCutoff: Double = 8000
    @State private var localResonance: Double = 0
    @State private var localFilterMode: Int = 0
    @State private var localAttack: Double = 0.01
    @State private var localDecay: Double = 0.1
    @State private var localSustain: Double = 0.7
    @State private var localRelease: Double = 0.3
    @State private var localWarm: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var schmynthConfig: SchmynthConfig? {
        guard let patch else { return nil }
        if case .schmynth(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeSchmynth

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("SCHMYNTH")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt"), ("Schmynth", "schmynth")],
                    current: "schmynth",
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
                        } else if type == "fuse" {
                            projectState.swapEngine(nodeID: nodeID, to: .fuse(FuseConfig()))
                        } else if type == "volt" {
                            projectState.swapEngine(nodeID: nodeID, to: .volt(VoltDrumKitConfig.defaultKit()))
                        }
                    }
                )
            }

            if schmynthConfig != nil {
                // ASCII circuit schematic hero
                circuitSchematic
                    .frame(height: 180 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * cs)
                            .fill(Color.black.opacity(0.3))
                    )

                // Waveform selector
                waveformSelector

                // Standard two-column layout
                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Filter + Envelope
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("FILTER")

                        paramSlider(label: "FILT", value: $localCutoff, range: 20...20000,
                                    format: { formatFreq($0) }) {
                            commitConfig { $0.cutoff = localCutoff }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "RES", value: $localResonance, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.resonance = localResonance }
                        } onDrag: { pushConfigToEngine() }

                        filterModeSelector

                        sectionDivider

                        sectionLabel("ENVELOPE")

                        paramSlider(label: "A", value: $localAttack, range: 0.001...10,
                                    format: { formatTime($0) }) {
                            commitConfig { $0.attack = localAttack }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "D", value: $localDecay, range: 0.001...10,
                                    format: { formatTime($0) }) {
                            commitConfig { $0.decay = localDecay }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "S", value: $localSustain, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.sustain = localSustain }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "R", value: $localRelease, range: 0.001...10,
                                    format: { formatTime($0) }) {
                            commitConfig { $0.release = localRelease }
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

    // MARK: - Waveform Selector

    private var waveformSelector: some View {
        HStack(spacing: 6 * cs) {
            Text("WAVE")
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            ForEach(Array(["SAW", "SQR", "TRI"].enumerated()), id: \.offset) { idx, label in
                Button(action: {
                    localWaveform = idx
                    commitConfig { $0.waveform = idx }
                }) {
                    Text(label)
                        .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localWaveform == idx ? accentColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 3 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localWaveform == idx ? accentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Filter Mode Selector

    private var filterModeSelector: some View {
        HStack(spacing: 4 * cs) {
            Text("MODE")
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 38 * cs, alignment: .trailing)

            ForEach(Array(["LP", "BP", "HP"].enumerated()), id: \.offset) { idx, label in
                Button(action: {
                    localFilterMode = idx
                    commitConfig { $0.filterMode = idx }
                }) {
                    Text(label)
                        .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localFilterMode == idx ? accentColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 3 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localFilterMode == idx ? accentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }

    // MARK: - Circuit Schematic (ASCII)

    private var circuitSchematic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                drawASCIISchematic(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func drawChar(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    private func drawCharBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    private func drawString(_ context: GraphicsContext, _ str: String, centerX: CGFloat, y: CGFloat, cellW: CGFloat, fontSize: CGFloat, color: Color, bold: Bool = false) {
        let chars = Array(str)
        let totalW = CGFloat(chars.count) * cellW
        let startX = centerX - totalW / 2 + cellW / 2
        for (i, ch) in chars.enumerated() {
            let x = startX + CGFloat(i) * cellW
            if bold {
                drawCharBold(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color)
            } else {
                drawChar(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color)
            }
        }
    }

    private func drawASCIISchematic(context: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width
        let h = size.height
        let wireColor = CanopyColors.chromeText
        let wireOp: CGFloat = 0.5
        let dimOp: CGFloat = 0.3

        let cutoffNorm = CGFloat((localCutoff - 20) / (20000 - 20))
        let resonance = CGFloat(localResonance)
        let warm = CGFloat(localWarm)

        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let centerX = w * 0.5

        // Row positions (10 rows)
        // 0: Oscillator label
        // 1: Current source → cap → comparator
        // 2: Waveform tap indicators
        // 3: Spacer / connection wire
        // 4: SCF label
        // 5: 4 filter stages in series
        // 6: Resonance feedback arc
        // 7: Spacer / connection wire
        // 8: Envelope indicator
        // 9: Output arrow

        let baseY = h * 0.08
        func rowY(_ row: Int) -> CGFloat { baseY + CGFloat(row) * rowH }

        // Oscillator charge animation
        let oscPulse = 0.4 + 0.3 * CGFloat(sin(time * 4.0))

        // Row 0: Oscillator label
        drawString(context, "OSCILLATOR", centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.6))

        // Row 1: [I]\u{2500}\u{2500}\u{2550}\u{256a}\u{2550} C_osc \u{2500}\u{2500}\u{2192} [CMP] \u{2500}\u{2500}\u{2192} [INT] \u{2500}\u{2500}\u{2192}
        let oscLeft = w * 0.12
        let oscRight = w * 0.88
        let oscMidLeft = w * 0.32
        let oscMidRight = w * 0.62

        // Current source [I]
        drawString(context, "[I]", centerX: oscLeft, y: rowY(1), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(oscPulse))

        // Wire to cap
        drawString(context, "\u{2500}\u{2500}", centerX: (oscLeft + oscMidLeft) * 0.5, y: rowY(1), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Cap ═╪═
        let capChargeLevel = 0.3 + warm * 0.2 + 0.2 * CGFloat(sin(time * 5.0))
        let capStr = "\u{2550}\u{256a}\u{2550}"
        drawString(context, capStr, centerX: oscMidLeft, y: rowY(1), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(capChargeLevel), bold: true)

        // Wire to comparator
        drawString(context, "\u{2500}\u{2192}", centerX: (oscMidLeft + oscMidRight) * 0.5, y: rowY(1), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Comparator [CMP]
        let cmpFlash = 0.35 + 0.2 * CGFloat(sin(time * 6.0))
        drawString(context, "[CMP]", centerX: oscMidRight, y: rowY(1), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(cmpFlash))

        // Wire to output
        drawString(context, "\u{2500}\u{2192}", centerX: (oscMidRight + oscRight) * 0.48, y: rowY(1), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Reset loop arrow (below CMP)
        drawString(context, "\u{2190}rst\u{2518}", centerX: (oscMidLeft + oscMidRight) * 0.5, y: rowY(1) + rowH * 0.6, cellW: cellW, fontSize: fontSize * 0.85, color: wireColor.opacity(dimOp))

        // Row 2: Waveform tap indicators — active one glows
        let waveLabels = ["SAW", "SQR", "TRI"]
        let tapSpacing = (oscRight - oscLeft) / CGFloat(waveLabels.count + 1)
        for (i, label) in waveLabels.enumerated() {
            let tapX = oscLeft + tapSpacing * CGFloat(i + 1)
            let isActive = localWaveform == i
            let tapOp: CGFloat = isActive ? 0.9 : dimOp
            let tapColor = isActive ? accentColor : wireColor
            drawString(context, label, centerX: tapX, y: rowY(2), cellW: cellW, fontSize: fontSize * 0.85, color: tapColor.opacity(tapOp), bold: isActive)
            if isActive {
                // Glow dot above
                drawChar(context, "\u{25cf}", at: CGPoint(x: tapX, y: rowY(2) - rowH * 0.35), size: fontSize * 0.6, color: accentColor.opacity(0.6 + 0.2 * CGFloat(sin(time * 3.0))))
            }
        }

        // Row 3: Connection wire to filter
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(3)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 4: SCF label
        drawString(context, "SCHMITT CASCADE FILTER", centerX: centerX, y: rowY(4), cellW: cellW, fontSize: fontSize * 0.85, color: accentColor.opacity(0.5))

        // Row 5: 4 SCF stages   ═╪═ → ═╪═ → ═╪═ → ═╪═
        let stageCount = 4
        let stageSpacing = (oscRight - oscLeft) / CGFloat(stageCount + 1)
        for i in 0..<stageCount {
            let stageX = oscLeft + stageSpacing * CGFloat(i + 1)
            let stageGlow = 0.4 + cutoffNorm * 0.3 + 0.1 * CGFloat(sin(time * 4.0 + Double(i) * 0.5))
            drawString(context, capStr, centerX: stageX, y: rowY(5), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(stageGlow), bold: true)

            // Arrow between stages
            if i < stageCount - 1 {
                let nextX = oscLeft + stageSpacing * CGFloat(i + 2)
                drawString(context, "\u{2192}", centerX: (stageX + nextX) * 0.5, y: rowY(5), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))
            }
        }

        // Row 6: Resonance feedback arc
        let fbOp = resonance * 0.8 + 0.1
        let fbPulse = resonance > 0.8 ? 0.15 * CGFloat(sin(time * 8.0)) : 0.0
        let stage1X = oscLeft + stageSpacing
        let stage4X = oscLeft + stageSpacing * 4
        let fbLabel = resonance > 0.6 ? "\u{2190}\u{2500}\u{2500} resonance \u{2500}\u{2500}\u{2192}" : "\u{2190}\u{2500} res \u{2500}\u{2192}"
        drawString(context, fbLabel, centerX: centerX, y: rowY(6), cellW: cellW, fontSize: fontSize * 0.85, color: accentColor.opacity(fbOp + fbPulse))

        // Feedback endpoints
        drawChar(context, "\u{2514}", at: CGPoint(x: stage1X, y: rowY(6)), size: fontSize, color: accentColor.opacity(fbOp))
        drawChar(context, "\u{2518}", at: CGPoint(x: stage4X, y: rowY(6)), size: fontSize, color: accentColor.opacity(fbOp))

        // Row 7: Connection wire to envelope
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(7)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 8: Envelope indicator — ADSR bar chars
        let envAttackBar = localAttack < 0.05 ? "\u{258c}" : (localAttack < 0.5 ? "\u{2588}" : "\u{2588}\u{2588}")
        let envDecayBar = localDecay < 0.2 ? "\u{258c}" : "\u{2588}"
        let sustainLevel = Int(localSustain * 4)
        let sustainBar = String(repeating: "\u{2588}", count: max(1, sustainLevel))
        let envReleaseBar = localRelease < 0.2 ? "\u{258c}" : "\u{2588}"
        let envStr = "A\(envAttackBar) D\(envDecayBar) S\(sustainBar) R\(envReleaseBar)"
        drawString(context, envStr, centerX: centerX, y: rowY(8), cellW: cellW, fontSize: fontSize * 0.85, color: accentColor.opacity(0.5))

        // Row 9: Output arrow
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(9), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = schmynthConfig else { return }
        localWaveform = config.waveform
        localCutoff = config.cutoff
        localResonance = config.resonance
        localFilterMode = config.filterMode
        localAttack = config.attack
        localDecay = config.decay
        localSustain = config.sustain
        localRelease = config.release
        localWarm = config.warm
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

    private func formatFreq(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1fk", hz / 1000)
        } else {
            return String(format: "%.0f", hz)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        if seconds < 0.1 {
            return String(format: "%.1fms", seconds * 1000)
        } else if seconds < 1.0 {
            return String(format: "%.0fms", seconds * 1000)
        } else {
            return String(format: "%.1fs", seconds)
        }
    }

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout SchmynthConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .schmynth(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .schmynth(config)
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
        let config = SchmynthConfig(
            waveform: localWaveform,
            cutoff: localCutoff,
            resonance: localResonance,
            filterMode: localFilterMode,
            attack: localAttack,
            decay: localDecay,
            sustain: localSustain,
            release: localRelease,
            warm: localWarm,
            volume: localVolume,
            pan: localPan
        )
        AudioEngine.shared.configureSchmynth(config, nodeID: nodeID)
    }
}
