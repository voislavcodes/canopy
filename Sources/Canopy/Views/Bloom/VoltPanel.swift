import SwiftUI

/// Bloom panel: VOLT analog circuit drum synthesis controls.
/// Topology-reactive ASCII circuit schematic + dynamic per-topology parameter sliders.
/// Two layers (A always active, B optional) with continuous mix.
/// Uses same local-drag-state pattern as FusePanel / FlowPanel.
struct VoltPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Slot selection

    @State private var selectedSlot: Int = 0

    // MARK: - Local drag state: Layer selection

    @State private var localLayerA: VoltTopology = .resonant
    @State private var localLayerB: VoltTopology? = nil
    @State private var localMix: Double = 0.5

    // MARK: - RESONANT params

    @State private var localResPitch: Double = 0.3
    @State private var localResSweep: Double = 0.25
    @State private var localResDecay: Double = 0.4
    @State private var localResDrive: Double = 0.2
    @State private var localResPunch: Double = 0.4
    @State private var localResHarmonics: Double = 0.0
    @State private var localResClick: Double = 0.0
    @State private var localResNoise: Double = 0.0
    @State private var localResBody: Double = 0.0
    @State private var localResTone: Double = 0.0

    // MARK: - NOISE params

    @State private var localNoiseColor: Double = 0.5
    @State private var localNoiseSnap: Double = 0.5
    @State private var localNoiseBody: Double = 0.3
    @State private var localNoiseClap: Double = 0.0
    @State private var localNoiseTone: Double = 0.0
    @State private var localNoiseFilter: Double = 0.0

    // MARK: - METALLIC params

    @State private var localMetSpread: Double = 0.3
    @State private var localMetTune: Double = 0.5
    @State private var localMetRing: Double = 0.3
    @State private var localMetBand: Double = 0.35
    @State private var localMetDensity: Double = 1.0

    // MARK: - TONAL params

    @State private var localTonPitch: Double = 0.4
    @State private var localTonFM: Double = 0.3
    @State private var localTonShape: Double = 0.25
    @State private var localTonBend: Double = 0.2
    @State private var localTonDecay: Double = 0.3

    // MARK: - Output

    @State private var localWarm: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var voltKit: VoltDrumKitConfig? {
        guard let patch else { return nil }
        if case .volt(let kit) = patch.soundType { return kit }
        return nil
    }

    private var voltConfig: VoltConfig? {
        guard let kit = voltKit else { return nil }
        guard selectedSlot >= 0, selectedSlot < kit.voices.count else { return nil }
        return kit.voices[selectedSlot]
    }

    private let accentColor = CanopyColors.nodeVolt

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("VOLT")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt")],
                    current: "volt",
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
                        }
                    }
                )
            }

            if voltKit != nil {
                // 8-slot voice selector (4x2 grid)
                voiceSelector

                // ASCII circuit schematic hero — topology-reactive
                circuitSchematic
                    .frame(height: 180 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * cs)
                            .fill(Color.black.opacity(0.3))
                    )

                // Two-column layout: Layer A | Layer B
                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Layer A
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("LAYER A")

                        topologySelector(selected: localLayerA, includeOff: false) { topo in
                            localLayerA = topo ?? .resonant
                            commitConfig { $0.layerA = localLayerA }
                        }

                        topologySliders(for: localLayerA, isLayerA: true)
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Layer B + Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("LAYER B")

                        topologySelector(selected: localLayerB ?? .resonant, includeOff: true, isOff: localLayerB == nil) { topo in
                            localLayerB = topo
                            commitConfig { $0.layerB = localLayerB }
                        }

                        if localLayerB != nil {
                            paramSlider(label: "MIX", value: $localMix, range: 0...1,
                                        format: { "A\(Int((1 - $0) * 100)):B\(Int($0 * 100))" }) {
                                commitConfig { $0.mix = localMix }
                            } onDrag: { pushConfigToEngine() }

                            topologySliders(for: localLayerB!, isLayerA: false)
                        }

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

    // MARK: - Voice Selector (8-slot drum kit)

    private var voiceSelector: some View {
        VStack(spacing: 2 * cs) {
            // Row 1: KICK, SNARE, C.HAT, O.HAT
            HStack(spacing: 2 * cs) {
                ForEach(0..<4, id: \.self) { i in
                    voiceSlotButton(index: i)
                }
            }
            // Row 2: TOM L, TOM H, CRASH, RIDE
            HStack(spacing: 2 * cs) {
                ForEach(4..<8, id: \.self) { i in
                    voiceSlotButton(index: i)
                }
            }
        }
    }

    private func voiceSlotButton(index: Int) -> some View {
        let isSelected = selectedSlot == index
        let name = VoltDrumKitConfig.voiceNames[index]
        return Button(action: {
            selectedSlot = index
            syncFromModel()
        }) {
            Text(name)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? accentColor : CanopyColors.chromeText.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(isSelected ? accentColor.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .stroke(isSelected ? accentColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Topology Selector

    @ViewBuilder
    private func topologySelector(selected: VoltTopology, includeOff: Bool, isOff: Bool = false, onChange: @escaping (VoltTopology?) -> Void) -> some View {
        HStack(spacing: 3 * cs) {
            if includeOff {
                topoButton("OFF", isActive: isOff) { onChange(nil) }
            }
            topoButton("RES", isActive: !isOff && selected == .resonant) { onChange(.resonant) }
            topoButton("NOI", isActive: !isOff && selected == .noise) { onChange(.noise) }
            topoButton("MET", isActive: !isOff && selected == .metallic) { onChange(.metallic) }
            topoButton("TON", isActive: !isOff && selected == .tonal) { onChange(.tonal) }
        }
    }

    private func topoButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? accentColor : CanopyColors.chromeText.opacity(0.4))
                .padding(.horizontal, 4 * cs)
                .padding(.vertical, 2 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(isActive ? accentColor.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .stroke(isActive ? accentColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dynamic Topology Sliders

    @ViewBuilder
    private func topologySliders(for topology: VoltTopology, isLayerA: Bool) -> some View {
        switch topology {
        case .resonant:
            paramSlider(label: "PTCH", value: $localResPitch, range: 0...1,
                        format: { resPitchHz($0) }) {
                commitConfig { $0.resPitch = localResPitch }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "SWEP", value: $localResSweep, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resSweep = localResSweep }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DECY", value: $localResDecay, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resDecay = localResDecay }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DRVE", value: $localResDrive, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resDrive = localResDrive }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "PNCH", value: $localResPunch, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resPunch = localResPunch }
            } onDrag: { pushConfigToEngine() }

            sectionDivider

            paramSlider(label: "HARM", value: $localResHarmonics, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resHarmonics = localResHarmonics }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "CLCK", value: $localResClick, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resClick = localResClick }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "NOIS", value: $localResNoise, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resNoise = localResNoise }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "BODY", value: $localResBody, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.resBody = localResBody }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "TONE", value: $localResTone, range: 0...1,
                        format: { resToneHz($0) }) {
                commitConfig { $0.resTone = localResTone }
            } onDrag: { pushConfigToEngine() }

        case .noise:
            paramSlider(label: "COLR", value: $localNoiseColor, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.noiseColor = localNoiseColor }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "SNAP", value: $localNoiseSnap, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.noiseSnap = localNoiseSnap }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "BODY", value: $localNoiseBody, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.noiseBody = localNoiseBody }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "CLAP", value: $localNoiseClap, range: 0...1,
                        format: { clapBurstCount($0) }) {
                commitConfig { $0.noiseClap = localNoiseClap }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "TONE", value: $localNoiseTone, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.noiseTone = localNoiseTone }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "FILT", value: $localNoiseFilter, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.noiseFilter = localNoiseFilter }
            } onDrag: { pushConfigToEngine() }

        case .metallic:
            paramSlider(label: "SPRD", value: $localMetSpread, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.metSpread = localMetSpread }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "TUNE", value: $localMetTune, range: 0...1,
                        format: { metTuneHz($0) }) {
                commitConfig { $0.metTune = localMetTune }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "RING", value: $localMetRing, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.metRing = localMetRing }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "BAND", value: $localMetBand, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.metBand = localMetBand }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DENS", value: $localMetDensity, range: 0...1,
                        format: { "\(Int(2 + $0 * 4))" }) {
                commitConfig { $0.metDensity = localMetDensity }
            } onDrag: { pushConfigToEngine() }

        case .tonal:
            paramSlider(label: "PTCH", value: $localTonPitch, range: 0...1,
                        format: { tonPitchHz($0) }) {
                commitConfig { $0.tonPitch = localTonPitch }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "FM", value: $localTonFM, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.tonFM = localTonFM }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "SHPE", value: $localTonShape, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.tonShape = localTonShape }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "BEND", value: $localTonBend, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.tonBend = localTonBend }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DECY", value: $localTonDecay, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.tonDecay = localTonDecay }
            } onDrag: { pushConfigToEngine() }
        }
    }

    // MARK: - Circuit Schematic (ASCII)

    private var circuitSchematic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                if localLayerB != nil {
                    drawDualLayerSchematic(context: context, size: size, time: time)
                } else {
                    drawSingleLayerSchematic(context: context, size: size, time: time, topology: localLayerA)
                }
            }
        }
    }

    // MARK: - Single Layer Schematics

    private func drawSingleLayerSchematic(context: GraphicsContext, size: CGSize, time: Double, topology: VoltTopology) {
        switch topology {
        case .resonant:
            drawResonantSchematic(context: context, size: size, time: time, centerX: size.width * 0.5, topY: 0, height: size.height)
        case .noise:
            drawNoiseSchematic(context: context, size: size, time: time, centerX: size.width * 0.5, topY: 0, height: size.height)
        case .metallic:
            drawMetallicSchematic(context: context, size: size, time: time, centerX: size.width * 0.5, topY: 0, height: size.height)
        case .tonal:
            drawTonalSchematic(context: context, size: size, time: time, centerX: size.width * 0.5, topY: 0, height: size.height)
        }
    }

    // MARK: - Dual Layer Schematic

    private func drawDualLayerSchematic(context: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width
        let h = size.height
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let wireColor = CanopyColors.chromeText

        // Draw Layer A on left third
        drawSingleLayerSchematic(context: context, size: CGSize(width: w * 0.45, height: h * 0.85),
                                  time: time, topology: localLayerA)

        // Draw Layer B on right third (offset)
        var bContext = context
        bContext.translateBy(x: w * 0.55, y: 0)
        if let layerB = localLayerB {
            switch layerB {
            case .resonant:
                drawResonantSchematic(context: bContext, size: CGSize(width: w * 0.45, height: h * 0.85), time: time, centerX: w * 0.45 * 0.5, topY: 0, height: h * 0.85)
            case .noise:
                drawNoiseSchematic(context: bContext, size: CGSize(width: w * 0.45, height: h * 0.85), time: time, centerX: w * 0.45 * 0.5, topY: 0, height: h * 0.85)
            case .metallic:
                drawMetallicSchematic(context: bContext, size: CGSize(width: w * 0.45, height: h * 0.85), time: time, centerX: w * 0.45 * 0.5, topY: 0, height: h * 0.85)
            case .tonal:
                drawTonalSchematic(context: bContext, size: CGSize(width: w * 0.45, height: h * 0.85), time: time, centerX: w * 0.45 * 0.5, topY: 0, height: h * 0.85)
            }
        }

        // Mix junction at bottom center
        let mixY = h * 0.88
        let mixOp = 0.4 + localMix * 0.3
        drawString(context, "\u{2500}\u{2500}\u{252c}\u{2500}\u{2500}", centerX: w * 0.5, y: mixY, cellW: cellW, fontSize: fontSize, color: wireColor.opacity(mixOp))
        let mixLabel = "MIX \(Int(localMix * 100))%"
        drawString(context, mixLabel, centerX: w * 0.5, y: mixY + fontSize * 1.2, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.5))
    }

    // MARK: - RESONANT Schematic

    private func drawResonantSchematic(context: GraphicsContext, size: CGSize, time: Double, centerX: CGFloat, topY: CGFloat, height: CGFloat) {
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let wireColor = CanopyColors.chromeText
        let wireOp: CGFloat = 0.5
        let dimOp: CGFloat = 0.3

        let sweep = CGFloat(localResSweep)
        let decay = CGFloat(localResDecay)
        let drive = CGFloat(localResDrive)
        let punch = CGFloat(localResPunch)
        let harmonics = CGFloat(localResHarmonics)
        let click = CGFloat(localResClick)
        let noise = CGFloat(localResNoise)
        let body = CGFloat(localResBody)
        let tone = CGFloat(localResTone)

        func rowY(_ row: Int) -> CGFloat { topY + height * 0.06 + CGFloat(row) * rowH }

        // Row 0: trigger + transient indicators
        let trigPulse = 0.3 + punch * 0.4 + 0.1 * CGFloat(sin(time * 4.0))
        var trigLabel = "\u{2500}\u{2500} trigger"
        if click > 0.05 { trigLabel += "+CLK" }
        if noise > 0.05 { trigLabel += "+NOI" }
        trigLabel += " \u{2500}\u{2500}"
        drawString(context, trigLabel, centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(trigPulse))

        // Row 1: wire down + split
        drawChar(context, "\u{252c}", at: CGPoint(x: centerX, y: rowY(1)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 2: two capacitors  ═╪═ C1     ═╪═ C2
        let capStr = "\u{2550}\u{256a}\u{2550}"
        let c1x = centerX - cellW * 5
        let c2x = centerX + cellW * 5

        // Cap fill: pulsing with sweep parameter
        let sweepPulse = sweep * CGFloat(0.5 + 0.5 * sin(time * 6.0))
        let capFillOp: CGFloat = 0.3 + sweepPulse * 0.4

        drawString(context, capStr, centerX: c1x, y: rowY(2), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(capFillOp + 0.2), bold: true)
        drawCharBold(context, "C1", at: CGPoint(x: c1x + cellW * 2.5, y: rowY(2)), size: fontSize * 0.8, color: wireColor.opacity(0.5))

        drawString(context, capStr, centerX: c2x, y: rowY(2), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(capFillOp + 0.2), bold: true)
        drawCharBold(context, "C2", at: CGPoint(x: c2x + cellW * 2.5, y: rowY(2)), size: fontSize * 0.8, color: wireColor.opacity(0.5))

        // Row 3: cap fill blocks — oscillating between C1 and C2
        let oscPhase = sin(time * 8.0)
        let c1Fill = max(0, CGFloat(oscPhase)) * decay
        let c2Fill = max(0, CGFloat(-oscPhase)) * decay
        if c1Fill > 0.1 {
            let fillChar = fillBlock(c1Fill)
            drawString(context, fillChar + fillChar + fillChar, centerX: c1x, y: rowY(3), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.2 + c1Fill * 0.5))
        }
        if c2Fill > 0.1 {
            let fillChar = fillBlock(c2Fill)
            drawString(context, fillChar + fillChar + fillChar, centerX: c2x, y: rowY(3), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.2 + c2Fill * 0.5))
        }

        // Row 4: wires + resistor  ├───[R1]───┤
        drawString(context, "\u{251c}\u{2500}\u{2500}\u{2500}[R1]\u{2500}\u{2500}\u{2500}\u{2524}", centerX: centerX, y: rowY(4), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 5: wires merging  └──────┬──────┘
        drawString(context, "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(5), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 6-7: BJT box
        let bjtGlow = 0.3 + drive * 0.6 + drive * 0.1 * CGFloat(sin(time * 5.0))
        drawString(context, "\u{250c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}", centerX: centerX, y: rowY(6), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bjtGlow))
        drawString(context, "\u{2502} BJT\u{2502}", centerX: centerX, y: rowY(6) + rowH * 0.5, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bjtGlow), bold: true)
        drawString(context, "\u{2514}\u{2500}\u{2500}\u{252c}\u{2500}\u{2518}", centerX: centerX, y: rowY(7), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bjtGlow))

        // Row 8: body indicator (if active)
        if body > 0.05 {
            let bodyGlow = 0.3 + body * 0.5 + body * 0.1 * CGFloat(sin(time * 2.0))
            drawString(context, "\u{2502} BODY \u{2502}", centerX: centerX, y: rowY(8), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bodyGlow))
        } else {
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(8)), size: fontSize, color: wireColor.opacity(wireOp))
        }

        // Row 9: harmonics waveshaper (if active)
        if harmonics > 0.05 {
            let harmGlow = 0.3 + harmonics * 0.5 + harmonics * 0.1 * CGFloat(sin(time * 6.0))
            drawString(context, "\u{250c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}", centerX: centerX, y: rowY(9), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(harmGlow))
            drawString(context, "\u{2502}HARM\u{2502}", centerX: centerX, y: rowY(9) + rowH * 0.5, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(harmGlow), bold: true)
            drawString(context, "\u{2514}\u{2500}\u{252c}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(10), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(harmGlow))
        } else {
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(9)), size: fontSize, color: wireColor.opacity(wireOp))
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(10)), size: fontSize, color: wireColor.opacity(wireOp))
        }

        // Row 11: tone LP filter (if active)
        if tone > 0.05 {
            let toneGlow = 0.3 + tone * 0.5 + tone * 0.1 * CGFloat(sin(time * 3.0))
            drawString(context, "\u{250c}\u{2500}\u{2500}\u{2500}\u{2510}", centerX: centerX, y: rowY(11), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(toneGlow))
            drawString(context, "\u{2502} LP\u{2502}", centerX: centerX, y: rowY(11) + rowH * 0.5, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(toneGlow), bold: true)
            drawString(context, "\u{2514}\u{252c}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(12), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(toneGlow))
        } else {
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(11)), size: fontSize, color: wireColor.opacity(wireOp))
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(12)), size: fontSize, color: wireColor.opacity(wireOp))
        }

        // Row 13: sweep indicator
        if sweep > 0.05 {
            let sweepHz = resPitchHz(localResPitch)
            let sweepLabel = "\u{2193}" + sweepHz
            drawString(context, sweepLabel, centerX: centerX, y: rowY(13), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.3 + sweep * 0.4))
        }

        // Row 14: output
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(14), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
    }

    // MARK: - NOISE Schematic

    private func drawNoiseSchematic(context: GraphicsContext, size: CGSize, time: Double, centerX: CGFloat, topY: CGFloat, height: CGFloat) {
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let wireColor = CanopyColors.chromeText
        let wireOp: CGFloat = 0.5
        let dimOp: CGFloat = 0.3

        let color = CGFloat(localNoiseColor)
        let snap = CGFloat(localNoiseSnap)
        let body = CGFloat(localNoiseBody)
        let clap = CGFloat(localNoiseClap)
        let tone = CGFloat(localNoiseTone)

        func rowY(_ row: Int) -> CGFloat { topY + height * 0.06 + CGFloat(row) * rowH }

        // Row 0: Envelope cap(s) — sequential for clap
        let numCaps = max(1, Int(1 + clap * 5))
        let capStr = "\u{2550}\u{256a}\u{2550}"
        let envPulse = 0.3 + snap * 0.3 + 0.1 * CGFloat(sin(time * 3.0))

        if numCaps == 1 {
            drawString(context, capStr + " C_env", centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(envPulse), bold: true)
        } else {
            // Multi-burst: sequential caps
            var capsStr = ""
            for i in 0..<min(numCaps, 6) {
                let phase = (time * 4.0 + Double(i) * 0.5).truncatingRemainder(dividingBy: Double(numCaps))
                let active = Int(phase) == i
                capsStr += active ? "\u{2550}\u{256a}\u{2550}" : "\u{2500}\u{253c}\u{2500}"
                if i < min(numCaps, 6) - 1 { capsStr += " " }
            }
            drawString(context, capsStr, centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(envPulse))
        }

        // Row 1: wire
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(1)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 2: noise source  Q_noise
        let noiseChars = "Q\u{2082}noise"
        drawString(context, noiseChars, centerX: centerX - cellW * 3, y: rowY(2), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(0.6))

        // Noise particles — random chars flickering
        let noiseParticles = [".", "\u{00b7}", "*", "\u{2022}", "\u{00b0}"]
        for i in 0..<4 {
            let idx = Int(time * 15.0 + Double(i) * 3.7) % noiseParticles.count
            let px = centerX + CGFloat(i - 2) * cellW * 2
            drawChar(context, noiseParticles[idx], at: CGPoint(x: px, y: rowY(2) + rowH * 0.4), size: fontSize, color: accentColor.opacity(0.2 + color * 0.3))
        }

        // Row 3: arrow to filter
        drawString(context, "\u{2500}\u{2500}\u{25b6}", centerX: centerX, y: rowY(3), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 4: RC filter box
        let filterLabel: String
        if color < 0.33 {
            filterLabel = "[LP]"
        } else if color < 0.66 {
            filterLabel = "[BP]"
        } else {
            filterLabel = "[HP]"
        }
        let filterGlow = 0.4 + CGFloat(localNoiseFilter) * 0.4
        drawString(context, "\u{250c}\u{2500}" + filterLabel + "\u{2500}\u{2510}", centerX: centerX, y: rowY(4), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(filterGlow))
        drawString(context, "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(5), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(filterGlow))

        // Row 6: arrow to VCA
        drawString(context, "\u{2500}\u{2500}\u{25b6}", centerX: centerX, y: rowY(6), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 7: VCA transistor
        let vcaGlow = 0.3 + body * 0.4
        drawString(context, "Q_vca", centerX: centerX, y: rowY(7), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(vcaGlow), bold: true)

        // Row 8: tone component (if active)
        if tone > 0.05 {
            let toneOp = 0.2 + tone * 0.5
            drawString(context, capStr + " tone", centerX: centerX, y: rowY(8), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(toneOp))
        } else {
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(8)), size: fontSize, color: wireColor.opacity(wireOp))
        }

        // Row 9: output
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(9), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
    }

    // MARK: - METALLIC Schematic

    private func drawMetallicSchematic(context: GraphicsContext, size: CGSize, time: Double, centerX: CGFloat, topY: CGFloat, height: CGFloat) {
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let wireColor = CanopyColors.chromeText
        let wireOp: CGFloat = 0.5
        let dimOp: CGFloat = 0.3

        let spread = CGFloat(localMetSpread)
        let ring = CGFloat(localMetRing)
        let band = CGFloat(localMetBand)
        let density = CGFloat(localMetDensity)
        let numOscs = max(2, Int(2 + density * 4))

        func rowY(_ row: Int) -> CGFloat { topY + height * 0.06 + CGFloat(row) * rowH }

        // Row 0: envelope cap  ═╪═ C_env
        let capStr = "\u{2550}\u{256a}\u{2550}"
        let envPulse = 0.3 + ring * 0.4 + 0.1 * CGFloat(sin(time * 3.0))
        drawString(context, capStr + " C_env", centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(envPulse), bold: true)

        // Row 1: Vcc bus wire
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(1)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 2-3: Oscillator bank — 6 Schmitt caps
        let oscSpacing = cellW * 2.2
        let bankWidth = CGFloat(5) * oscSpacing
        let bankStartX = centerX - bankWidth / 2

        // Branch wires
        var branchStr = "\u{251c}"
        for _ in 0..<5 { branchStr += "\u{2500}" }
        branchStr += "\u{2524}"
        drawString(context, branchStr, centerX: centerX, y: rowY(2), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Individual oscillator caps
        for i in 0..<6 {
            let isActive = i < numOscs
            let oscX = bankStartX + CGFloat(i) * oscSpacing
            let shimmer = isActive ? (0.3 + 0.2 * CGFloat(sin(time * (5.0 + Double(i) * 1.3 * (1.0 + spread))))) : 0.0
            let oscOp: CGFloat = isActive ? (0.4 + shimmer) : 0.12

            drawString(context, capStr, centerX: oscX, y: rowY(3), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(oscOp))
        }

        // Row 4: wires merging
        drawString(context, "\u{2514}\u{2500}\u{2500}\u{2500}\u{252c}\u{2500}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(4), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 5: wire
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(5)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 6-7: Bandpass filter
        let bpfGlow = 0.3 + band * 0.5
        drawString(context, "\u{250c}\u{2500}[BPF]\u{2500}\u{2510}", centerX: centerX, y: rowY(6), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bpfGlow))
        drawString(context, "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}", centerX: centerX, y: rowY(7), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bpfGlow))

        // Row 8: wire
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(8)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 9: output
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(9), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
    }

    // MARK: - TONAL Schematic

    private func drawTonalSchematic(context: GraphicsContext, size: CGSize, time: Double, centerX: CGFloat, topY: CGFloat, height: CGFloat) {
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let wireColor = CanopyColors.chromeText
        let wireOp: CGFloat = 0.5
        let dimOp: CGFloat = 0.3

        let fm = CGFloat(localTonFM)
        let shape = CGFloat(localTonShape)
        let bend = CGFloat(localTonBend)
        let decay = CGFloat(localTonDecay)

        func rowY(_ row: Int) -> CGFloat { topY + height * 0.06 + CGFloat(row) * rowH }

        let capStr = "\u{2550}\u{256a}\u{2550}"

        // Row 0: envelope cap  ═╪═ C_env
        let envPulse = 0.3 + decay * 0.4 + 0.1 * CGFloat(sin(time * 3.0))
        drawString(context, capStr + " C_env", centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(envPulse), bold: true)

        // Row 1: split
        drawString(context, "\u{251c}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}", centerX: centerX, y: rowY(1), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp))

        // Row 2: Modulator cap
        let modX = centerX - cellW * 4
        drawString(context, capStr + " Mod", centerX: modX, y: rowY(2), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.3 + fm * 0.4))

        // Row 3: FM coupling arrows  ╲╱  or ──[FM]──▶
        let fmPulse = fm * (0.5 + 0.3 * CGFloat(sin(time * 7.0)))
        drawString(context, "\u{2500}\u{2500}[FM]\u{2500}\u{2500}\u{25b6}", centerX: centerX, y: rowY(3), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.2 + fmPulse))

        // Row 4: Carrier cap
        let carX = centerX + cellW * 4
        let shapeGlow = 0.3 + shape * 0.4
        drawString(context, capStr + " Car", centerX: carX, y: rowY(4), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(shapeGlow))

        // Carrier fill
        if shape > 0.1 {
            let fillChar = fillBlock(shape)
            drawString(context, fillChar + fillChar + fillChar, centerX: carX, y: rowY(5), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(0.15 + shape * 0.3))
        }

        // Row 6: wire from carrier to output
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(6)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 7: Bend cap (if active)
        if bend > 0.05 {
            let bendOp = 0.2 + bend * 0.5
            let bendDrain = 0.5 + 0.3 * CGFloat(sin(time * 2.0)) // slow drain animation
            drawString(context, capStr + " bend", centerX: centerX - cellW * 3, y: rowY(7), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(bendOp * bendDrain))
            drawString(context, "(leaks)", centerX: centerX + cellW * 2, y: rowY(7), cellW: cellW, fontSize: fontSize * 0.85, color: wireColor.opacity(0.3))
        } else {
            drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(7)), size: fontSize, color: wireColor.opacity(wireOp))
        }

        // Row 8: wire
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(8)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 9: output
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(9), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
    }

    // MARK: - Schematic Drawing Helpers

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

    /// Select fill block character based on intensity (0-1).
    private func fillBlock(_ intensity: CGFloat) -> String {
        if intensity < 0.25 { return "\u{2591}" }       // ░
        else if intensity < 0.5 { return "\u{2592}" }   // ▒
        else if intensity < 0.75 { return "\u{2593}" }   // ▓
        else { return "\u{2588}" }                        // █
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = voltConfig else { return }
        localLayerA = config.layerA
        localLayerB = config.layerB
        localMix = config.mix
        localResPitch = config.resPitch
        localResSweep = config.resSweep
        localResDecay = config.resDecay
        localResDrive = config.resDrive
        localResPunch = config.resPunch
        localResHarmonics = config.resHarmonics
        localResClick = config.resClick
        localResNoise = config.resNoise
        localResBody = config.resBody
        localResTone = config.resTone
        localNoiseColor = config.noiseColor
        localNoiseSnap = config.noiseSnap
        localNoiseBody = config.noiseBody
        localNoiseClap = config.noiseClap
        localNoiseTone = config.noiseTone
        localNoiseFilter = config.noiseFilter
        localMetSpread = config.metSpread
        localMetTune = config.metTune
        localMetRing = config.metRing
        localMetBand = config.metBand
        localMetDensity = config.metDensity
        localTonPitch = config.tonPitch
        localTonFM = config.tonFM
        localTonShape = config.tonShape
        localTonBend = config.tonBend
        localTonDecay = config.tonDecay
        localWarm = config.warm
        localVolume = config.volume
        localPan = config.pan
    }

    // MARK: - Section Helpers

    private var sectionDivider: some View {
        Divider()
            .background(CanopyColors.bloomPanelBorder.opacity(0.3))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor.opacity(0.7))
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

    /// Resonant pitch: 0–1 → 15–500 Hz exponential
    private func resPitchHz(_ v: Double) -> String {
        let hz = 15.0 * pow(500.0 / 15.0, v)
        if hz < 100 { return String(format: "%.0fHz", hz) }
        return String(format: "%.0fHz", hz)
    }

    /// Resonant tone filter: 0–1 → 20kHz–200Hz LP cutoff
    private func resToneHz(_ v: Double) -> String {
        let hz = 200.0 * pow(100.0, 1.0 - v)
        if hz >= 1000 { return String(format: "%.1fk", hz / 1000) }
        return String(format: "%.0fHz", hz)
    }

    /// Metallic tune: 0–1 → 200–16000 Hz
    private func metTuneHz(_ v: Double) -> String {
        let hz = 200.0 * pow(16000.0 / 200.0, v)
        if hz >= 1000 { return String(format: "%.1fk", hz / 1000) }
        return String(format: "%.0fHz", hz)
    }

    /// Tonal pitch: 0–1 → 20–2000 Hz
    private func tonPitchHz(_ v: Double) -> String {
        let hz = 20.0 * pow(2000.0 / 20.0, v)
        if hz >= 1000 { return String(format: "%.1fk", hz / 1000) }
        return String(format: "%.0fHz", hz)
    }

    /// Clap burst count display
    private func clapBurstCount(_ v: Double) -> String {
        let count = max(1, Int(1 + v * 5))
        return "\(count)x"
    }

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout VoltConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let slot = selectedSlot
        projectState.updateNode(id: nodeID) { node in
            if case .volt(var kit) = node.patch.soundType {
                guard slot >= 0, slot < kit.voices.count else { return }
                transform(&kit.voices[slot])
                node.patch.soundType = .volt(kit)
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
        let config = VoltConfig(
            layerA: localLayerA,
            layerB: localLayerB,
            mix: localMix,
            resPitch: localResPitch, resSweep: localResSweep, resDecay: localResDecay,
            resDrive: localResDrive, resPunch: localResPunch,
            resHarmonics: localResHarmonics, resClick: localResClick, resNoise: localResNoise,
            resBody: localResBody, resTone: localResTone,
            noiseColor: localNoiseColor, noiseSnap: localNoiseSnap, noiseBody: localNoiseBody,
            noiseClap: localNoiseClap, noiseTone: localNoiseTone, noiseFilter: localNoiseFilter,
            metSpread: localMetSpread, metTune: localMetTune, metRing: localMetRing,
            metBand: localMetBand, metDensity: localMetDensity,
            tonPitch: localTonPitch, tonFM: localTonFM, tonShape: localTonShape,
            tonBend: localTonBend, tonDecay: localTonDecay,
            warm: localWarm, volume: localVolume, pan: localPan
        )
        AudioEngine.shared.configureVoltSlot(index: selectedSlot, config, nodeID: nodeID)
    }
}
