import SwiftUI

/// Bloom panel: FUSE virtual analog circuit synthesis controls.
/// Reactive circuit schematic hero + standard two-column slider layout.
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
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt")],
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
                        } else if type == "volt" {
                            projectState.swapEngine(nodeID: nodeID, to: .volt(VoltDrumKitConfig.defaultKit()))
                        }
                    }
                )
            }

            if fuseConfig != nil {
                // ASCII circuit schematic hero
                circuitSchematic
                    .frame(height: 180 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * cs)
                            .fill(Color.black.opacity(0.3))
                    )

                // Standard two-column layout
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

    // MARK: - Circuit Schematic (ASCII)

    /// Reactive ASCII circuit diagram: box-drawing characters rendered via Canvas.
    /// Two Schmitt oscillators (A, B) → coupling → body resonator → output.
    private var circuitSchematic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                drawASCIISchematic(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// Draw a single monospaced character at a grid position with color.
    private func drawChar(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    /// Draw a bold monospaced character.
    private func drawCharBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    /// Draw a string of monospaced characters, each cell = cellW wide, centered on startX.
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

        let soul = CGFloat(localSoul)
        let tune = CGFloat(localTune)
        let couple = CGFloat(localCouple)
        let body = CGFloat(localBody)
        let color = CGFloat(localColor)

        // Font / grid sizing
        let fontSize: CGFloat = max(10, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let centerX = w * 0.5

        // Row positions (13 rows)
        // 0: Vcc rail top       ┌──── Vcc ────┐
        // 1: supply wires       │              │
        // 2: capacitors         ═╪═ A    ~~~  ═╪═ B
        // 3: soul fill          ░░░      ~~~   ░░░
        // 4: color shape        △/▢            △/▢
        // 5: couple top         ╲              ╱
        // 6: couple mid           ╲          ╱
        // 7: couple label       (couple) ─────
        // 8: junction wire      │
        // 9: body top           ┌──┤Body├──┐  or  ╔══╡Body╞══╗
        // 10: body bottom       └──────────┘  or  ╚══════════╝
        // 11: out wire          │
        // 12: out arrow         ▼ out

        let baseY = h * 0.06
        func rowY(_ row: Int) -> CGFloat { baseY + CGFloat(row) * rowH }

        let capAx = w * 0.28
        let capBx = w * 0.72

        // Vcc pulse
        let vccPulse = 0.4 + 0.2 * soul + 0.1 * CGFloat(sin(time * 3.0))
        let vccColor = accentColor.opacity(vccPulse)

        // Row 0: Vcc rail   ┌────── Vcc ──────┐
        let vccRailChars = 13
        let vccHalfChars = (vccRailChars - 3) / 2 // chars of ─ on each side of "Vcc"
        var vccStr = "\u{250c}" // ┌
        for _ in 0..<vccHalfChars { vccStr += "\u{2500}" } // ─
        vccStr += " Vcc "
        for _ in 0..<vccHalfChars { vccStr += "\u{2500}" }
        vccStr += "\u{2510}" // ┐
        drawString(context, vccStr, centerX: centerX, y: rowY(0), cellW: cellW, fontSize: fontSize, color: vccColor)

        // Row 1: supply wires  │              │
        let supplySpacing = vccRailChars + 4 // total chars wide
        let halfSpan = CGFloat(supplySpacing / 2) * cellW
        drawChar(context, "\u{2502}", at: CGPoint(x: capAx, y: rowY(1)), size: fontSize, color: wireColor.opacity(wireOp))
        drawChar(context, "\u{2502}", at: CGPoint(x: capBx, y: rowY(1)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 2: capacitors  ═╪═ A       ═╪═ B
        let capStr = "\u{2550}\u{256a}\u{2550}" // ═╪═
        drawString(context, capStr, centerX: capAx, y: rowY(2), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp + 0.15), bold: true)
        drawCharBold(context, "A", at: CGPoint(x: capAx + cellW * 2.5, y: rowY(2)), size: fontSize, color: wireColor.opacity(0.7))

        // Cap B offset by tune
        let capBYOffset = tune * 4 * cs
        drawString(context, capStr, centerX: capBx, y: rowY(2) + capBYOffset, cellW: cellW, fontSize: fontSize, color: wireColor.opacity(wireOp + 0.15), bold: true)
        drawCharBold(context, "B", at: CGPoint(x: capBx + cellW * 2.5, y: rowY(2) + capBYOffset), size: fontSize, color: wireColor.opacity(0.7))

        // Tune ratio between caps
        if tune > 0.06 {
            let ratioText = tuneDisplayText(localTune)
            let ratioOp = min(1.0, (tune - 0.06) * 5.0) * 0.65
            drawString(context, ratioText, centerX: centerX, y: rowY(2) + capBYOffset * 0.5, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(ratioOp))
        }

        // Row 3: soul fill inside caps — block chars  ░▒▓█
        let soulChar: String
        let soulFlicker = sin(time * 5.0)
        if soul < 0.15 {
            soulChar = " "
        } else if soul < 0.35 {
            soulChar = soulFlicker > 0.3 ? "\u{2591}" : "\u{2591}" // ░
        } else if soul < 0.6 {
            soulChar = soulFlicker > 0.0 ? "\u{2592}" : "\u{2591}" // ▒ / ░
        } else if soul < 0.85 {
            soulChar = soulFlicker > -0.3 ? "\u{2593}" : "\u{2592}" // ▓ / ▒
        } else {
            soulChar = soulFlicker > 0.0 ? "\u{2588}" : "\u{2593}" // █ / ▓
        }
        let soulGlowOp: CGFloat = 0.15 + soul * 0.65
        if soul >= 0.15 {
            let soulFill = soulChar + soulChar + soulChar
            drawString(context, soulFill, centerX: capAx, y: rowY(3), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(soulGlowOp))
            drawString(context, soulFill, centerX: capBx, y: rowY(3) + capBYOffset, cellW: cellW, fontSize: fontSize, color: accentColor.opacity(soulGlowOp))
        }

        // Row 4: color waveshape indicator
        let colorChar: String
        if color < 0.25 {
            colorChar = "\u{25b3}" // △
        } else if color < 0.5 {
            colorChar = "\u{25c7}" // ◇
        } else if color < 0.75 {
            colorChar = "\u{25cb}" // ○
        } else {
            colorChar = "\u{25a1}" // □
        }
        let colorOp: CGFloat = 0.25 + color * 0.4
        drawChar(context, colorChar, at: CGPoint(x: capAx, y: rowY(4)), size: fontSize, color: accentColor.opacity(colorOp))
        drawChar(context, colorChar, at: CGPoint(x: capBx, y: rowY(4) + capBYOffset), size: fontSize, color: accentColor.opacity(colorOp))

        // Rows 5-6: coupling diagonals
        let coupleOp: CGFloat = 0.15 + couple * 0.75
        let coupleShimmer: CGFloat = couple > 0.3 ? CGFloat(sin(time * 6.0)) * 0.1 * couple : 0.0
        let cplColor = accentColor.opacity(coupleOp + coupleShimmer)

        // Left diagonal  ╲  going from capA down-right toward center
        let diagATopX = capAx + cellW
        let diagABotX = centerX - cellW
        let diagATopY = rowY(5)
        let diagABotY = rowY(6)
        // Draw 2-3 ╲ characters interpolated
        for i in 0..<3 {
            let t = CGFloat(i) / 2.0
            let dx = diagATopX + (diagABotX - diagATopX) * t
            let dy = diagATopY + (diagABotY - diagATopY) * t
            drawChar(context, "\u{2572}", at: CGPoint(x: dx, y: dy), size: fontSize, color: cplColor)
        }

        // Right diagonal  ╱  going from capB down-left toward center
        let diagBTopX = capBx - cellW
        let diagBBotX = centerX + cellW
        let diagBTopY = rowY(5) + capBYOffset * 0.3
        let diagBBotY = rowY(6)
        for i in 0..<3 {
            let t = CGFloat(i) / 2.0
            let dx = diagBTopX + (diagBBotX - diagBTopX) * t
            let dy = diagBTopY + (diagBBotY - diagBTopY) * t
            drawChar(context, "\u{2571}", at: CGPoint(x: dx, y: dy), size: fontSize, color: cplColor)
        }

        // Row 7: couple label + horizontal merge line
        if couple > 0.02 {
            let cplLabelOp = coupleOp * 0.8
            drawString(context, "(couple)", centerX: centerX, y: rowY(7), cellW: cellW, fontSize: fontSize, color: accentColor.opacity(cplLabelOp))
        }

        // Junction ┬ character
        drawChar(context, "\u{252c}", at: CGPoint(x: centerX, y: rowY(7) + rowH * 0.5), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 8: vertical wire │
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(8)), size: fontSize, color: wireColor.opacity(wireOp))

        // Rows 9-10: body resonator box
        let bodyOp: CGFloat = 0.3 + body * 0.6
        let bodyBold = body > 0.5

        // Choose single or double line based on body amount
        let tl: String, tr: String, bl: String, br: String, hz: String
        if body < 0.5 {
            tl = "\u{250c}"; tr = "\u{2510}"; bl = "\u{2514}"; br = "\u{2518}"; hz = "\u{2500}"
        } else {
            tl = "\u{2554}"; tr = "\u{2557}"; bl = "\u{255a}"; br = "\u{255d}"; hz = "\u{2550}"
        }

        // Body top:  ┌──┤Body├──┐  or  ╔══╡Body╞══╗
        let bodyLabel = "Body"
        let bodyPadChars = 3
        var bodyTopStr = tl
        for _ in 0..<bodyPadChars { bodyTopStr += hz }
        bodyTopStr += bodyLabel
        for _ in 0..<bodyPadChars { bodyTopStr += hz }
        bodyTopStr += tr
        let bodyColor = accentColor.opacity(bodyOp)

        // Wobble offset for body when high
        var bodyXOffset: CGFloat = 0
        if body > 0.4 {
            let wobbleAmt = (body - 0.4) / 0.6
            bodyXOffset = CGFloat(sin(time * 8.0)) * 1.5 * wobbleAmt
        }

        drawString(context, bodyTopStr, centerX: centerX + bodyXOffset, y: rowY(9), cellW: cellW, fontSize: fontSize, color: bodyColor, bold: bodyBold)

        // Body bottom:  └──────────┘  or  ╚══════════╝
        var bodyBotStr = bl
        for _ in 0..<(bodyPadChars * 2 + bodyLabel.count) { bodyBotStr += hz }
        bodyBotStr += br
        drawString(context, bodyBotStr, centerX: centerX + bodyXOffset, y: rowY(10), cellW: cellW, fontSize: fontSize, color: bodyColor, bold: bodyBold)

        // Body internal glow fill
        if body > 0.3 {
            let internalOp = (body - 0.3) * 0.3
            let fillChars = bodyPadChars * 2 + bodyLabel.count
            var fillStr = ""
            for _ in 0..<fillChars { fillStr += "\u{2591}" }
            drawString(context, fillStr, centerX: centerX + bodyXOffset, y: (rowY(9) + rowY(10)) / 2, cellW: cellW, fontSize: fontSize * 0.85, color: accentColor.opacity(internalOp))
        }

        // Row 11: wire from body to output  │
        drawChar(context, "\u{2502}", at: CGPoint(x: centerX, y: rowY(11)), size: fontSize, color: wireColor.opacity(wireOp))

        // Row 12: output arrow  ▼ out
        drawString(context, "\u{25bc} out", centerX: centerX, y: rowY(12), cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp + 0.15))
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
            return String(format: "%.2f\u{00d7}", ratio)
        } else if v < 0.50 {
            let t = (v - 0.25) / 0.25
            let ratio = 1.5 + t * 1.5
            return String(format: "%.1f\u{00d7}", ratio)
        } else if v < 0.75 {
            let t = (v - 0.50) / 0.25
            let ratio = 3.0 + t * 4.0
            return String(format: "%.1f\u{00d7}", ratio)
        } else {
            let t = (v - 0.75) / 0.25
            let ratio = 7.0 + t * 10.0
            return String(format: "%.0f\u{00d7}", ratio)
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
