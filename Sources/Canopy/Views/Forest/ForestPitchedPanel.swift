import SwiftUI

/// Forest-mode pitched sequencer: 18 generative controls across three pages.
/// Three pages: GENERATE (birth the pattern), TRANSFORM (shape it), PLAY (perform it).
/// Each page is a 3×2 grid of ASCII art knobs rendered via Canvas + TimelineView.
/// In `.focus` layout mode, all 18 cells are shown in a flat 3×6 grid with no header/chrome.
struct ForestPitchedPanel: View {
    enum LayoutMode { case forest, focus }

    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    var layoutMode: LayoutMode = .forest
    @Environment(\.canvasScale) var cs

    private let panelWidth: CGFloat = 380

    // MARK: - Page State

    @State private var currentPage: Int = 0  // 0=GENERATE, 1=TRANSFORM, 2=PLAY

    // MARK: - Local drag state (for responsive real-time feedback)

    @State private var localProbability: Double = 1.0
    @State private var localMutationAmount: Double = 0.0
    @State private var localArpGate: Double = 0.5
    @State private var localBloomAmount: Double = 0.0
    @State private var localDensity: Double = 1.0
    @State private var localDriftRate: Double = 0.0
    @State private var localHumanize: Double = 0.0
    @State private var localSwing: Double = 0.0
    @State private var localGateLength: Double = 0.75
    @State private var localWobble: Double = 0

    // Grid drag tracking
    @State private var activeCell: Int? = nil
    @State private var dragStartValue: Double = 0
    @State private var dragInitiated: Bool = false
    @State private var cellDragMode: CircleDragMode? = nil
    @State private var gridCellWidth: CGFloat = 0

    private enum CircleDragMode { case pulses, rotation, wobble, rngRange, rngOctave }

    // MARK: - Constants

    private let euclideanGreen = Color(red: 0.2, green: 0.7, blue: 0.4)
    private static let fifthLabels = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F"]
    private static let fifthSemitones = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]
    private static let pageNames = ["GENERATE", "TRANSFORM", "PLAY"]

    // MARK: - Computed Properties

    private var node: Node? { projectState.selectedNode }
    private var isArpActive: Bool { node?.sequence.arpConfig != nil }

    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    private var currentPulses: Int { node?.sequence.euclidean?.pulses ?? 4 }
    private var currentRotation: Int { node?.sequence.euclidean?.rotation ?? 0 }

    private func currentPattern() -> [Bool] {
        guard let seq = node?.sequence else { return [] }
        let cols = columns
        if let euc = seq.euclidean {
            return EuclideanRhythm.generate(steps: cols, pulses: euc.pulses, rotation: euc.rotation, wobble: localWobble)
        }
        let sd = NoteSequence.stepDuration
        var occupancy = [Bool](repeating: false, count: cols)
        for note in seq.notes {
            let step = Int(round(note.startBeat / sd))
            if step >= 0 && step < cols { occupancy[step] = true }
        }
        return occupancy
    }

    // MARK: - Body

    var body: some View {
        switch layoutMode {
        case .forest: forestBody
        case .focus: focusBody
        }
    }

    private var forestBody: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            headerRow
            paramGrid
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: panelWidth * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear { syncSeqFromModel() }
        .onChange(of: projectState.selectedNodeID) { _ in syncSeqFromModel() }
    }

    private var focusBody: some View {
        paramGridFlat
            .padding(.bottom, 8)
            .onAppear { syncSeqFromModel() }
            .onChange(of: projectState.selectedNodeID) { _ in syncSeqFromModel() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6 * cs) {
            ModuleSwapButton(
                options: [("Pitched", SequencerType.pitched), ("Drum", SequencerType.drum), ("Orbit", SequencerType.orbit), ("Spore", SequencerType.sporeSeq)],
                current: node?.sequencerType ?? .pitched,
                onChange: { type in
                    guard let nodeID = projectState.selectedNodeID else { return }
                    projectState.swapSequencer(nodeID: nodeID, to: type)
                }
            )

            Text("SEQUENCE")
                .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Spacer()

            // Page tabs
            HStack(spacing: 12 * cs) {
                ForEach(0..<3, id: \.self) { page in
                    let isActive = currentPage == page
                    Text(Self.pageNames[page])
                        .font(.system(size: 11 * cs, weight: isActive ? .bold : .regular, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.chromeTextBright : CanopyColors.chromeText.opacity(0.5))
                        .onTapGesture { currentPage = page }
                }
            }
            .padding(.vertical, 4 * cs)
            .padding(.horizontal, 10 * cs)
            .background(CanopyColors.bloomPanelBackground.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6 * cs))
            .overlay(
                RoundedRectangle(cornerRadius: 6 * cs)
                    .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
            )

            Button(action: { randomFill() }) {
                Image(systemName: "dice")
                    .font(.system(size: 12 * cs))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 22 * cs, height: 18 * cs)
            }
            .buttonStyle(.plain)
            .help("Random scale fill")
        }
    }

    // MARK: - Param Grid (page-aware)

    private var paramGrid: some View {
        let gridHeight: CGFloat = 240 * cs

        return GeometryReader { geo in
            let cellW = geo.size.width / 3
            let cellH = geo.size.height / 2

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let cW = size.width / 3
                    let cH = size.height / 2

                    for row in 0..<2 {
                        for col in 0..<3 {
                            let idx = row * 3 + col
                            let rect = CGRect(x: CGFloat(col) * cW, y: CGFloat(row) * cH, width: cW, height: cH)
                            let isActive = activeCell == idx

                            switch currentPage {
                            case 0: drawGenerateCell(idx, context: context, rect: rect, time: time, active: isActive)
                            case 1: drawTransformCell(idx, context: context, rect: rect, time: time, active: isActive)
                            case 2: drawPlayCell(idx, context: context, rect: rect, time: time, active: isActive)
                            default: break
                            }
                        }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if activeCell == nil {
                            let col = min(2, max(0, Int(drag.startLocation.x / cellW)))
                            let row = min(1, max(0, Int(drag.startLocation.y / cellH)))
                            activeCell = row * 3 + col
                            gridCellWidth = cellW
                            dragInitiated = false
                        }

                        let movement = sqrt(pow(drag.translation.width, 2) + pow(drag.translation.height, 2))
                        if !dragInitiated && movement > 4 {
                            dragInitiated = true
                            initializeDrag(cell: activeCell!, drag: drag)
                        }

                        if dragInitiated {
                            handleDrag(cell: activeCell!, drag: drag)
                        }
                    }
                    .onEnded { drag in
                        if !dragInitiated {
                            handleTap(cell: activeCell ?? 0)
                        } else {
                            commitDrag(cell: activeCell ?? 0)
                        }
                        activeCell = nil
                        cellDragMode = nil
                        dragInitiated = false
                    }
            )
        }
        .frame(height: gridHeight)
        .overlay(gridOverlays)
    }

    // Overlays for icon buttons (freeze/reset on GENERATE)
    @ViewBuilder
    private var gridOverlays: some View {
        if currentPage == 0 {
            GeometryReader { geo in
                let cW = geo.size.width / 3
                let cH = geo.size.height / 2
                VStack(spacing: 4 * cs) {
                    Button(action: { freezeMutation() }) {
                        Text("\u{2744}")
                            .font(.system(size: 10 * cs, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Freeze mutations")

                    Button(action: { resetMutation() }) {
                        Text("\u{21BA}")
                            .font(.system(size: 11 * cs, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Reset mutations")
                }
                .position(x: cW - 8 * cs, y: cH + cH * 0.35)
            }
        }
    }

    // MARK: - Flat 3×6 Grid (Focus Mode)

    private var paramGridFlat: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / 3
            let cellH = geo.size.height / 6

            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        let cW = size.width / 3
                        let cH = size.height / 6

                        for row in 0..<6 {
                            for col in 0..<3 {
                                let globalIdx = row * 3 + col
                                let rect = CGRect(x: CGFloat(col) * cW, y: CGFloat(row) * cH, width: cW, height: cH)
                                let isActive = activeCell == globalIdx
                                drawCellByGlobalIndex(globalIdx, context: context, rect: rect, time: time, active: isActive)
                            }
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if activeCell == nil {
                                let col = min(2, max(0, Int(drag.startLocation.x / cellW)))
                                let row = min(5, max(0, Int(drag.startLocation.y / cellH)))
                                activeCell = row * 3 + col
                                gridCellWidth = cellW
                                dragInitiated = false
                            }

                            let movement = sqrt(pow(drag.translation.width, 2) + pow(drag.translation.height, 2))
                            if !dragInitiated && movement > 4 {
                                dragInitiated = true
                                let globalIdx = activeCell!
                                let page = globalIdx / 6
                                let cell = globalIdx % 6
                                initializeDragFlat(page: page, cell: cell, drag: drag)
                            }

                            if dragInitiated {
                                let globalIdx = activeCell!
                                let page = globalIdx / 6
                                let cell = globalIdx % 6
                                handleDragFlat(page: page, cell: cell, drag: drag)
                            }
                        }
                        .onEnded { drag in
                            let globalIdx = activeCell ?? 0
                            let page = globalIdx / 6
                            let cell = globalIdx % 6
                            if !dragInitiated {
                                handleTapFlat(page: page, cell: cell)
                            } else {
                                commitDragFlat(page: page, cell: cell)
                            }
                            activeCell = nil
                            cellDragMode = nil
                            dragInitiated = false
                        }
                )

                // Freeze/reset overlay — MUT cell is at row 1, col 0 (globalIdx 3)
                GeometryReader { overlayGeo in
                    let cW = overlayGeo.size.width / 3
                    let cH = overlayGeo.size.height / 6
                    VStack(spacing: 4 * cs) {
                        Button(action: { freezeMutation() }) {
                            Text("\u{2744}")
                                .font(.system(size: 10 * cs, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Freeze mutations")

                        Button(action: { resetMutation() }) {
                            Text("\u{21BA}")
                                .font(.system(size: 11 * cs, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Reset mutations")
                    }
                    .position(x: cW - 8 * cs, y: cH + cH * 0.35)
                }
            }
        }
    }

    /// Draw a cell by global index (0-17) mapping across all three pages.
    private func drawCellByGlobalIndex(_ globalIdx: Int, context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let page = globalIdx / 6
        let cell = globalIdx % 6
        switch page {
        case 0: drawGenerateCell(cell, context: context, rect: rect, time: time, active: active)
        case 1: drawTransformCell(cell, context: context, rect: rect, time: time, active: active)
        case 2: drawPlayCell(cell, context: context, rect: rect, time: time, active: active)
        default: break
        }
    }

    // Flat-mode drag/tap routing (page is derived from globalIdx)

    private func initializeDragFlat(page: Int, cell: Int, drag: DragGesture.Value) {
        switch page {
        case 0: initializeGenerateDrag(cell: cell, drag: drag)
        case 1: initializeTransformDrag(cell: cell)
        case 2: initializePlayDrag(cell: cell)
        default: break
        }
    }

    private func handleDragFlat(page: Int, cell: Int, drag: DragGesture.Value) {
        switch page {
        case 0: handleGenerateDrag(cell: cell, drag: drag)
        case 1: handleTransformDrag(cell: cell, drag: drag)
        case 2: handlePlayDrag(cell: cell, drag: drag)
        default: break
        }
    }

    private func commitDragFlat(page: Int, cell: Int) {
        switch page {
        case 0: commitGenerateDrag(cell: cell)
        case 1: commitTransformDrag(cell: cell)
        case 2: commitPlayDrag(cell: cell)
        default: break
        }
    }

    private func handleTapFlat(page: Int, cell: Int) {
        switch page {
        case 1: handleTransformTap(cell: cell)
        case 2: handlePlayTap(cell: cell)
        default: break
        }
    }

    // MARK: - Page Draw Dispatchers

    private func drawGenerateCell(_ idx: Int, context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        switch idx {
        case 0: drawEuclideanKnob(context: context, rect: rect, time: time, active: active)
        case 1: drawProbKnob(context: context, rect: rect, value: localProbability, time: time, active: active)
        case 2: drawStepsKnob(context: context, rect: rect, value: columns, time: time, active: active)
        case 3: drawMutKnob(context: context, rect: rect, value: localMutationAmount, time: time, active: active)
        case 4: drawRngKnob(context: context, rect: rect, value: node?.sequence.mutation?.range ?? 1, time: time, active: active)
        case 5: drawFifthKnob(context: context, rect: rect, time: time, active: active)
        default: break
        }
    }

    private func drawTransformCell(_ idx: Int, context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        switch idx {
        case 0: drawBloomKnob(context: context, rect: rect, value: localBloomAmount, time: time, active: active)
        case 1: drawInvertKnob(context: context, rect: rect, time: time, active: active)
        case 2: drawDensityKnob(context: context, rect: rect, value: localDensity, time: time, active: active)
        case 3: drawMirrorKnob(context: context, rect: rect, time: time, active: active)
        case 4: drawDriftKnob(context: context, rect: rect, value: localDriftRate, time: time, active: active)
        case 5: drawHumanKnob(context: context, rect: rect, value: localHumanize, time: time, active: active)
        default: break
        }
    }

    private func drawPlayCell(_ idx: Int, context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        switch idx {
        case 0: drawDirKnob(context: context, rect: rect, time: time, active: active)
        case 1: drawSwingKnob(context: context, rect: rect, value: localSwing, time: time, active: active)
        case 2: drawGateKnob(context: context, rect: rect, value: localGateLength, time: time, active: active)
        case 3: drawArpKnob(context: context, rect: rect, time: time, active: active)
        case 4: drawRateKnob(context: context, rect: rect, time: time, active: active)
        case 5: drawOctKnob(context: context, rect: rect, time: time, active: active)
        default: break
        }
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                     GENERATE PAGE DRAWS                         ║
    // ╚══════════════════════════════════════════════════════════════════╝

    // MARK: - EUC Knob (Euclidean circle with polygon)

    private func drawEuclideanKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let cols = columns
        let pattern = currentPattern()
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.38)
        let radius = min(rect.width * 0.85, rect.height * 0.55) * 0.36
        let dotFontSize: CGFloat = cols > 24 ? max(6, 7 * cs) : max(7, 9 * cs)

        let nodeID = node?.id ?? UUID()
        let engine = AudioEngine.shared
        let isPlaying = engine.isPlaying(for: nodeID)
        let currentBeat = engine.currentBeat(for: nodeID)
        let seqLen = node?.sequence.lengthInBeats ?? 1
        let beatFrac = currentBeat / max(seqLen, 1)
        let playheadStep = isPlaying ? Int(beatFrac * Double(cols)) % cols : -1
        let pulse = 0.7 + 0.3 * sin(time * 6)

        var hitIndices: [Int] = []
        for i in 0..<min(cols, pattern.count) {
            if pattern[i] { hitIndices.append(i) }
        }

        // Connect hits with polygon
        if hitIndices.count > 1 {
            for i in 0..<hitIndices.count {
                let next = (i + 1) % hitIndices.count
                let p1 = circlePoint(center: center, radius: radius, step: hitIndices[i], total: cols)
                let p2 = circlePoint(center: center, radius: radius, step: hitIndices[next], total: cols)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(euclideanGreen.opacity(0.15)), lineWidth: 1)
            }
        }

        for i in 0..<cols {
            let point = circlePoint(center: center, radius: radius, step: i, total: cols)
            let isHit = i < pattern.count && pattern[i]
            let isPlayhead = i == playheadStep
            let color: Color
            if isPlayhead { color = CanopyColors.glowColor.opacity(pulse) }
            else if isHit { color = euclideanGreen }
            else { color = CanopyColors.chromeText.opacity(0.2) }
            let char = isHit ? "\u{25CF}" : "\u{25CB}"
            let scale: CGFloat = isPlayhead ? 1.3 : 1.0
            drawChar(context, char, at: point, size: dotFontSize * scale, color: color)
        }

        // Wobble wave indicator on right edge (always visible, dimmed when inactive)
        do {
            let waveX = rect.maxX - rect.width * 0.1
            let waveH = rect.height * 0.4
            let waveTop = rect.minY + rect.height * 0.18
            let segments = 8
            let isWobbleDrag = active && cellDragMode == .wobble
            let wobbleColor = localWobble > 0.01
                ? euclideanGreen.opacity(isWobbleDrag ? 0.9 : 0.5 + localWobble * 0.4)
                : CanopyColors.chromeText.opacity(isWobbleDrag ? 0.5 : 0.2)

            for i in 0..<segments {
                let t = Double(i) / Double(segments - 1)
                let y = waveTop + CGFloat(t) * waveH
                let wobbleAmp = localWobble * 6.0
                let xOff = CGFloat(sin(t * .pi * 2.5 + time * 2) * wobbleAmp)
                let ch = localWobble > 0.5 ? "\u{223F}" : "\u{2022}"
                drawChar(context, ch, at: CGPoint(x: waveX + xOff, y: y),
                         size: max(7, 8 * cs), color: wobbleColor)
            }
        }

        let eucValue = localWobble > 0.01
            ? "\(currentPulses)/\(cols) ~\(Int(localWobble * 100))"
            : "\(currentPulses)/\(cols)"
        drawCellLabel(context, rect: rect, label: "EUC", value: eucValue, active: active)
    }

    // MARK: - PROB Knob (dot matrix)

    private func drawProbKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)
        let shimmerTick = Int(fmod(time * 8, 1000))

        for row in 0..<4 {
            for col in 0..<5 {
                let x = centerX - CGFloat(5) * cellW / 2 + CGFloat(col) * cellW + cellW / 2
                let y = artCenterY - CGFloat(4) * rowH / 2 + CGFloat(row) * rowH + rowH / 2
                let dist = max(abs(col - 2), abs(row - 1))
                let threshold = Double(dist) * 0.25 + 0.08
                if value < threshold { continue }
                let intensity = min(1.0, (value - threshold) / 0.3)
                let ch: String = intensity < 0.3 ? "\u{00B7}" : (intensity < 0.6 ? "\u{2022}" : "\u{25CF}")
                let cellHash = (row * 7 + col + shimmerTick) % 11
                let finalCh: String
                if cellHash == 0 && value > 0.25 {
                    finalCh = intensity < 0.5 ? (intensity < 0.3 ? "\u{2022}" : "\u{00B7}") : (intensity < 0.8 ? "\u{2022}" : "\u{25CF}")
                } else { finalCh = ch }
                drawChar(context, finalCh, at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(0.55 + intensity * 0.45))
            }
        }
        drawCellLabel(context, rect: rect, label: "PROB", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - STEPS Knob (step ticker)

    private func drawStepsKnob(context: GraphicsContext, rect: CGRect, value: Int, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.5
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let activeColor = CanopyColors.glowColor.opacity(op)

        let rowCount = value > 16 ? 2 : 1
        for rowIdx in 0..<rowCount {
            let rowOffset = rowIdx * 16
            let rowSteps = min(16, value - rowOffset)
            let groups = (rowSteps + 3) / 4
            let totalChars = groups * 5 + 1
            let totalWidth = CGFloat(totalChars) * cellW
            let startX = centerX - totalWidth / 2 + cellW / 2
            let y = artCenterY + CGFloat(rowIdx) * rowH - CGFloat(rowCount - 1) * rowH * 0.5
            var charPos = 0
            for g in 0..<groups {
                let sx = startX + CGFloat(charPos) * cellW
                drawChar(context, "\u{2503}", at: CGPoint(x: sx, y: y), size: fontSize, color: CanopyColors.chromeText.opacity(0.3))
                charPos += 1
                let stepsInGroup = min(4, rowSteps - g * 4)
                for s in 0..<4 {
                    let x = startX + CGFloat(charPos) * cellW
                    if s < stepsInGroup { drawChar(context, "\u{00B7}", at: CGPoint(x: x, y: y), size: fontSize, color: activeColor) }
                    charPos += 1
                }
            }
            let fx = startX + CGFloat(charPos) * cellW
            drawChar(context, "\u{2503}", at: CGPoint(x: fx, y: y), size: fontSize, color: CanopyColors.chromeText.opacity(0.3))
        }
        drawCellLabel(context, rect: rect, label: "STEPS", value: "\(value)", active: active)
    }

    // MARK: - MUT Knob (drift lines)

    private func drawMutKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color: Color
        if value < 0.3 { color = CanopyColors.glowColor.opacity(op) }
        else if value < 0.6 { color = Color(red: 0.6, green: 0.7, blue: 0.3).opacity(op) }
        else { color = Color(red: 0.8, green: 0.5, blue: 0.2).opacity(op) }
        let chaosChars = ["\u{2500}", "~", "\u{223F}", "\u{2248}"]

        for row in 0..<3 {
            for col in 0..<5 {
                let x = centerX - CGFloat(5) * cellW / 2 + CGFloat(col) * cellW + cellW / 2
                let y = artCenterY - CGFloat(3) * rowH / 2 + CGFloat(row) * rowH + rowH / 2
                let phase = fmod(time * (1.0 + value * 3.0) + Double(row) * 0.7 + Double(col) * 0.3, 4.0)
                let maxIndex = min(3, Int(value * 4.0))
                let charIndex = maxIndex == 0 ? 0 : min(maxIndex, Int(phase) % (maxIndex + 1))
                drawChar(context, chaosChars[charIndex], at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(0.55 + value * 0.45))
            }
        }
        drawCellLabel(context, rect: rect, label: "MUT", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - RNG Knob (range spread + octave offset secondary)

    private func drawRngKnob(context: GraphicsContext, rect: CGRect, value: Int, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        // RNG art: vertical arrow spread
        let segSpacing: CGFloat = fontSize * 1.2
        let totalH = CGFloat(value) * segSpacing
        let topY = artCenterY - totalH * 0.5

        drawChar(context, "\u{2191}", at: CGPoint(x: centerX, y: topY - segSpacing * 0.3), size: fontSize, color: color)
        for i in 0..<value {
            let y = topY + CGFloat(i) * segSpacing
            let ch = i == value / 2 ? "\u{00B7}" : "\u{2502}"
            drawChar(context, ch, at: CGPoint(x: centerX, y: y), size: fontSize, color: color)
        }
        drawChar(context, "\u{2193}", at: CGPoint(x: centerX, y: topY + totalH - segSpacing + segSpacing * 0.3), size: fontSize, color: color)

        // OCT indicator on right edge (like wobble on EUC)
        let octOffset = node?.sequence.octaveOffset ?? 0
        let isOctDrag = active && cellDragMode == .rngOctave
        do {
            let indicatorX = rect.maxX - rect.width * 0.1
            let indicatorH = rect.height * 0.4
            let indicatorTop = rect.minY + rect.height * 0.18
            let segments = 7  // -3 to +3
            let midSeg = segments / 2

            for i in 0..<segments {
                let t = Double(i) / Double(segments - 1)
                let y = indicatorTop + CGFloat(t) * indicatorH
                let segIdx = midSeg - i  // top = +3, mid = 0, bottom = -3

                let isLit = (octOffset > 0 && segIdx > 0 && segIdx <= octOffset) ||
                            (octOffset < 0 && segIdx < 0 && segIdx >= octOffset)
                let isMid = segIdx == 0

                let segColor: Color
                if isLit {
                    segColor = CanopyColors.glowColor.opacity(isOctDrag ? 0.9 : 0.7)
                } else if isMid {
                    segColor = CanopyColors.chromeText.opacity(isOctDrag ? 0.5 : 0.35)
                } else {
                    segColor = CanopyColors.chromeText.opacity(isOctDrag ? 0.35 : 0.18)
                }

                let ch = isMid ? "\u{2500}" : (isLit ? "\u{25CF}" : "\u{25CB}")
                drawChar(context, ch, at: CGPoint(x: indicatorX, y: y),
                         size: max(7, 8 * cs), color: segColor)
            }
        }

        // Label — show octave offset in value when non-zero
        let octStr = octOffset != 0 ? (octOffset > 0 ? " +\(octOffset)" : " \(octOffset)") : ""
        drawCellLabel(context, rect: rect, label: "RNG", value: "\(value)\(octStr)", active: active)
    }

    // MARK: - FIFTH Knob (circle of fifths)

    private func drawFifthKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let rotation = node?.sequence.fifthRotation ?? 0
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.38)
        let radius = min(rect.width * 0.85, rect.height * 0.55) * 0.36
        let fontSize: CGFloat = max(7, 8 * cs)
        let key = resolveKey()

        // Find source key's position in circle of fifths
        let sourcePos = Self.fifthSemitones.firstIndex(of: key.root.semitone) ?? 0
        let targetPos = ((sourcePos + rotation) % 12 + 12) % 12

        for i in 0..<12 {
            let angle = -Double.pi / 2 + (Double(i) / 12.0) * 2 * Double.pi
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            let isTarget = i == targetPos
            let isAdjacent = i == ((targetPos + 1) % 12) || i == ((targetPos + 11) % 12)
            let op: CGFloat
            if isTarget { op = 1.0 }
            else if isAdjacent { op = 0.5 }
            else { op = 0.25 }
            let color = isTarget ? CanopyColors.glowColor.opacity(op) : CanopyColors.chromeText.opacity(op)
            let weight: Font.Weight = isTarget ? .bold : .regular
            context.draw(
                Text(Self.fifthLabels[i]).font(.system(size: fontSize, weight: weight, design: .monospaced)).foregroundColor(color),
                at: pt, anchor: .center
            )
        }

        // Target key name for value display
        let targetName = Self.fifthLabels[targetPos]
        let modeName = key.mode == .major ? "" : "m"
        drawCellLabel(context, rect: rect, label: "FIFTH", value: "\(targetName)\(modeName)", active: active)
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                    TRANSFORM PAGE DRAWS                         ║
    // ╚══════════════════════════════════════════════════════════════════╝

    // MARK: - BLOOM Knob (growing branches)

    private func drawBloomKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.55
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = Color(red: 0.3, green: 0.7, blue: 0.5).opacity(op)

        let lineCount = 5
        for row in 0..<lineCount {
            let y = artCenterY - CGFloat(lineCount) * rowH / 2 + CGFloat(row) * rowH + rowH / 2
            // Each line grows based on bloom amount + deterministic variation
            let seed = Double(row * 7 + 3)
            let baseLen: Double = 1
            let maxLen: Double = 8
            let variation = sin(seed * 1.7) * 0.3 + 0.7 // 0.4–1.0
            let length = baseLen + (maxLen - baseLen) * value * variation
            let charCount = max(1, Int(round(length)))
            let startX = centerX - CGFloat(4) * cellW  // left-aligned visual
            for c in 0..<charCount {
                let x = startX + CGFloat(c) * cellW
                let ch = c == charCount - 1 ? "\u{00B7}" : "\u{2500}"
                let fade = 1.0 - Double(c) / Double(max(1, charCount)) * 0.3
                drawChar(context, ch, at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(fade))
            }
        }
        drawCellLabel(context, rect: rect, label: "BLOOM", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - INVERT Knob (mirror axis)

    private func drawInvertKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let isOn = node?.sequence.invertEnabled ?? false
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.55
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = isOn ? CanopyColors.glowColor.opacity(op) : CanopyColors.chromeText.opacity(0.3)

        // Horizontal pivot line
        let lineW: CGFloat = 7
        let startX = centerX - CGFloat(lineW) * cellW / 2 + cellW / 2
        for c in 0..<Int(lineW) {
            let x = startX + CGFloat(c) * cellW
            drawChar(context, "\u{2500}", at: CGPoint(x: x, y: artCenterY), size: fontSize, color: color.opacity(0.6))
        }
        // Label "pivot"
        drawString(context, "pivot", centerX: centerX, y: artCenterY, cellW: cellW * 0.8, fontSize: fontSize * 0.6, color: color.opacity(0.3))

        // Dots above and below (mirrored when on)
        let dotOffsets: [(Int, Int)] = [(0, -2), (1, -1), (2, -2), (-1, -1)]
        for (dx, dy) in dotOffsets {
            let x = centerX + CGFloat(dx) * cellW * 1.5
            let yAbove = artCenterY + CGFloat(dy) * fontSize * 1.2
            drawChar(context, "\u{00B7}", at: CGPoint(x: x, y: yAbove), size: fontSize, color: color.opacity(0.7))
            if isOn {
                let yBelow = artCenterY - CGFloat(dy) * fontSize * 1.2
                drawChar(context, "\u{00B7}", at: CGPoint(x: x, y: yBelow), size: fontSize, color: color.opacity(0.5))
            }
        }

        let pivotStr = isOn ? "on" : "off"
        drawCellLabel(context, rect: rect, label: "INVERT", value: pivotStr, active: active)
    }

    // MARK: - DENSITY Knob (dot field)

    private func drawDensityKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.15
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        for row in 0..<4 {
            for col in 0..<6 {
                let x = centerX - CGFloat(6) * cellW / 2 + CGFloat(col) * cellW + cellW / 2
                let y = artCenterY - CGFloat(4) * rowH / 2 + CGFloat(row) * rowH + rowH / 2
                // Deterministic: hash-based selection
                let hash = ((row * 7 + col * 13 + 5) % 100)
                let threshold = (1.0 - value) * 100
                let alive = Double(hash) >= threshold
                let ch = alive ? "\u{25CF}" : "\u{00B7}"
                let dotOp: CGFloat = alive ? 0.8 : 0.15
                drawChar(context, ch, at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(dotOp))
            }
        }
        drawCellLabel(context, rect: rect, label: "DENSITY", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - MIRROR Knob (direction arrows)

    private func drawMirrorKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let isOn = node?.sequence.mirrorEnabled ?? false
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = isOn ? CanopyColors.glowColor.opacity(op) : CanopyColors.chromeText.opacity(0.35)

        let arrow = isOn ? "\u{2190}" : "\u{2192}"
        let arrows = String(repeating: "\(arrow) ", count: 4)
        drawString(context, arrows, centerX: centerX, y: artCenterY - fontSize * 0.6, cellW: cellW, fontSize: fontSize, color: color)

        // Line
        let lineStr = "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"
        drawString(context, lineStr, centerX: centerX, y: artCenterY + fontSize * 0.3, cellW: cellW * 0.7, fontSize: fontSize * 0.8, color: color.opacity(0.4))

        drawCellLabel(context, rect: rect, label: "MIRROR", value: isOn ? "on" : "off", active: active)
    }

    // MARK: - DRIFT Knob (rotating ring)

    private func drawDriftKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.38)
        let radius = min(rect.width, rect.height) * 0.18
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        // Ring
        let ringChars = ["\u{256D}", "\u{2500}", "\u{256E}", "\u{2502}", "\u{256F}", "\u{2500}", "\u{2570}", "\u{2502}"]
        for i in 0..<8 {
            let angle = (Double(i) / 8.0) * 2 * Double.pi - Double.pi / 2
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            drawChar(context, ringChars[i], at: pt, size: fontSize * 0.8, color: color.opacity(0.3))
        }

        // Rotating dot
        let dotAngle = -Double.pi / 2 + time * (0.5 + value * 3.0)
        let dotPt = CGPoint(x: center.x + radius * 0.7 * CGFloat(cos(dotAngle)), y: center.y + radius * 0.7 * CGFloat(sin(dotAngle)))
        drawChar(context, "\u{25CF}", at: dotPt, size: fontSize, color: value > 0 ? color : color.opacity(0.3))

        drawCellLabel(context, rect: rect, label: "DRIFT", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - HUMAN Knob (jitter dots)

    private func drawHumanKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.6
        let rowH: CGFloat = fontSize * 1.2
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        let shimmerTick = Int(fmod(time * 4, 1000))

        for row in 0..<3 {
            for col in 0..<6 {
                let baseX = centerX - CGFloat(6) * cellW / 2 + CGFloat(col) * cellW + cellW / 2
                let baseY = artCenterY - CGFloat(3) * rowH / 2 + CGFloat(row) * rowH + rowH / 2
                // Deterministic jitter based on value
                let seed = row * 7 + col * 13 + shimmerTick
                let jitX = CGFloat(sin(Double(seed) * 0.3)) * CGFloat(value) * cellW * 0.4
                let jitY = CGFloat(cos(Double(seed) * 0.7)) * CGFloat(value) * rowH * 0.25
                let x = baseX + jitX
                let y = baseY + jitY
                drawChar(context, "\u{00B7}", at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(0.6))
            }
        }
        drawCellLabel(context, rect: rect, label: "HUMAN", value: "\(Int(value * 100))%", active: active)
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                       PLAY PAGE DRAWS                           ║
    // ╚══════════════════════════════════════════════════════════════════╝

    // MARK: - DIR Knob (direction mode)

    private func drawDirKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let dir = node?.sequence.playbackDirection ?? .forward
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        let arrows: String
        switch dir {
        case .forward:  arrows = "\u{2192} \u{2192} \u{2192} \u{2192} \u{2192}"
        case .reverse:  arrows = "\u{2190} \u{2190} \u{2190} \u{2190} \u{2190}"
        case .pingPong: arrows = "\u{2192} \u{2192} \u{2190} \u{2190} \u{2192}"
        case .random:   arrows = "\u{2192}   \u{2190} \u{2192}   \u{2192} \u{2190}"
        case .brownian: arrows = "\u{2192} \u{2192} \u{2190} \u{2192} \u{2192} \u{2190}"
        }
        drawString(context, arrows, centerX: centerX, y: artCenterY, cellW: cellW, fontSize: fontSize, color: color)

        let symbol: String
        switch dir {
        case .forward: symbol = "\u{2192}"
        case .reverse: symbol = "\u{2190}"
        case .pingPong: symbol = "\u{2194}"
        case .random: symbol = "?"
        case .brownian: symbol = "~"
        }
        drawCellLabel(context, rect: rect, label: "DIR", value: symbol, active: active)
    }

    // MARK: - SWING Knob (offset pairs)

    private func drawSwingKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.55
        let rowH: CGFloat = fontSize * 1.4
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        // Show 3 rows of dot pairs with offset increasing
        for row in 0..<3 {
            let y = artCenterY - rowH + CGFloat(row) * rowH
            let pairs = 4
            let totalW = CGFloat(pairs * 3) * cellW
            let startX = centerX - totalW / 2 + cellW / 2
            for p in 0..<pairs {
                let onBeatX = startX + CGFloat(p * 3) * cellW
                let offBeatX = onBeatX + cellW + CGFloat(value) * cellW * 1.5
                drawChar(context, "\u{25CF}", at: CGPoint(x: onBeatX, y: y), size: fontSize * 0.8, color: color.opacity(0.8))
                drawChar(context, "\u{25CF}", at: CGPoint(x: offBeatX, y: y), size: fontSize * 0.7, color: color.opacity(0.5))
            }
        }
        drawCellLabel(context, rect: rect, label: "SWING", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - GATE Knob (note length bars)

    private func drawGateKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.5
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        let maxBars = 6
        let filledCount = max(1, Int(round(value * Double(maxBars))))
        for row in 0..<3 {
            let y = artCenterY - rowH + CGFloat(row) * rowH
            let totalW = CGFloat(maxBars) * cellW
            let startX = centerX - totalW / 2 + cellW / 2
            for c in 0..<maxBars {
                let x = startX + CGFloat(c) * cellW
                let ch = c < filledCount ? "\u{2588}" : "\u{2591}"
                let op2: CGFloat = c < filledCount ? 0.7 : 0.2
                drawChar(context, ch, at: CGPoint(x: x, y: y), size: fontSize, color: color.opacity(op2))
            }
        }
        drawCellLabel(context, rect: rect, label: "GATE", value: "\(Int(value * 100))%", active: active)
    }

    // MARK: - ARP Knob (toggle)

    private func drawArpKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let isOn = isArpActive
        let fontSize: CGFloat = max(9, 11 * cs)
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = active ? 1.0 : 0.55
        let color = isOn ? CanopyColors.glowColor.opacity(op) : CanopyColors.chromeText.opacity(0.3)

        if isOn {
            // Cascading arrows
            let arrows = ["\u{25CF} \u{2192} \u{25CF} \u{2192} \u{25CF}", "  \u{2193}", "\u{25CF} \u{2192} \u{25CF} \u{2192} \u{25CF}"]
            let cellW: CGFloat = fontSize * 0.5
            for (i, line) in arrows.enumerated() {
                let y = artCenterY - fontSize * 1.2 + CGFloat(i) * fontSize * 1.2
                drawString(context, line, centerX: centerX, y: y, cellW: cellW, fontSize: fontSize * 0.8, color: color)
            }
        } else {
            // Static chord stack
            let cellW: CGFloat = fontSize * 0.5
            for i in 0..<3 {
                let y = artCenterY - fontSize * 1.0 + CGFloat(i) * fontSize * 1.0
                drawString(context, "\u{2502} \u{25CF} \u{2502}", centerX: centerX, y: y, cellW: cellW, fontSize: fontSize * 0.8, color: color)
            }
        }
        drawCellLabel(context, rect: rect, label: "ARP", value: isOn ? "on" : "off", active: active)
    }

    // MARK: - RATE Knob (arp rate — dimmed when ARP off)

    private func drawRateKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let arpOn = isArpActive
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.4
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = (active && arpOn) ? 1.0 : (arpOn ? 0.55 : 0.2)
        let color = CanopyColors.glowColor.opacity(op)

        let rate = node?.sequence.arpConfig?.rate ?? .sixteenth
        let tickCount: Int
        switch rate {
        case .whole, .half: tickCount = 4
        case .quarter: tickCount = 8
        case .eighth: tickCount = 12
        case .sixteenth: tickCount = 16
        case .thirtySecond: tickCount = 20
        case .tripletEighth: tickCount = 10
        case .tripletSixteenth: tickCount = 14
        }

        let totalW = CGFloat(tickCount) * cellW
        let startX = centerX - totalW / 2 + cellW / 2
        for i in 0..<tickCount {
            let x = startX + CGFloat(i) * cellW
            let isBeat = i % 4 == 0
            let ch = isBeat ? "\u{2502}" : "\u{00B7}"
            drawChar(context, ch, at: CGPoint(x: x, y: artCenterY), size: fontSize * 0.9, color: color)
        }

        let rateStr: String
        switch rate {
        case .whole: rateStr = "1"
        case .half: rateStr = "1/2"
        case .quarter: rateStr = "1/4"
        case .eighth: rateStr = "1/8"
        case .sixteenth: rateStr = "1/16"
        case .thirtySecond: rateStr = "1/32"
        case .tripletEighth: rateStr = "t8"
        case .tripletSixteenth: rateStr = "t16"
        }
        drawCellLabel(context, rect: rect, label: "RATE", value: rateStr, active: active && arpOn)
    }

    // MARK: - OCT Knob (arp octave range — dimmed when ARP off)

    private func drawOctKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let arpOn = isArpActive
        let fontSize: CGFloat = max(9, 11 * cs)
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38
        let op: CGFloat = (active && arpOn) ? 1.0 : (arpOn ? 0.55 : 0.2)
        let color = CanopyColors.glowColor.opacity(op)

        let octaves = node?.sequence.arpConfig?.octaveRange ?? 1
        let barH = fontSize * 1.0
        let totalH = barH * 4
        let startY = artCenterY - totalH / 2 + barH / 2

        for i in 0..<4 {
            let y = startY + CGFloat(3 - i) * barH  // bottom to top
            let isActive = i < octaves
            let boxChars = isActive ? "\u{2523}\u{2501}\u{2501}\u{252B}" : "\u{2502}  \u{2502}"
            drawString(context, boxChars, centerX: centerX, y: y, cellW: fontSize * 0.5, fontSize: fontSize * 0.8, color: isActive ? color : color.opacity(0.2))
        }
        drawCellLabel(context, rect: rect, label: "OCT", value: "\(octaves)", active: active && arpOn)
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                       DRAW HELPERS                              ║
    // ╚══════════════════════════════════════════════════════════════════╝

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
            if bold { drawCharBold(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color) }
            else { drawChar(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color) }
        }
    }

    /// Draw label + value at the bottom of a cell.
    private func drawCellLabel(_ context: GraphicsContext, rect: CGRect, label: String, value: String, active: Bool) {
        let labelFontSize = max(9, 11 * cs) * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, label, centerX: rect.midX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, value, centerX: rect.midX, y: valueY, cellW: labelCellW, fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    private func circlePoint(center: CGPoint, radius: CGFloat, step: Int, total: Int) -> CGPoint {
        let angle = -Double.pi / 2 + (Double(step) / Double(max(1, total))) * 2 * Double.pi
        return CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                    DRAG / TAP HANDLERS                          ║
    // ╚══════════════════════════════════════════════════════════════════╝

    private func initializeDrag(cell: Int, drag: DragGesture.Value) {
        switch currentPage {
        case 0: initializeGenerateDrag(cell: cell, drag: drag)
        case 1: initializeTransformDrag(cell: cell)
        case 2: initializePlayDrag(cell: cell)
        default: break
        }
    }

    private func handleDrag(cell: Int, drag: DragGesture.Value) {
        switch currentPage {
        case 0: handleGenerateDrag(cell: cell, drag: drag)
        case 1: handleTransformDrag(cell: cell, drag: drag)
        case 2: handlePlayDrag(cell: cell, drag: drag)
        default: break
        }
    }

    private func commitDrag(cell: Int) {
        switch currentPage {
        case 0: commitGenerateDrag(cell: cell)
        case 1: commitTransformDrag(cell: cell)
        case 2: commitPlayDrag(cell: cell)
        default: break
        }
    }

    private func handleTap(cell: Int) {
        switch currentPage {
        case 1: handleTransformTap(cell: cell)
        case 2: handlePlayTap(cell: cell)
        default: break
        }
    }

    // MARK: - GENERATE Drag

    private func initializeGenerateDrag(cell: Int, drag: DragGesture.Value) {
        switch cell {
        case 0:
            // Right 20% of EUC cell = wobble zone (when euclidean active)
            let col = cell % 3
            let cellLocalX = drag.startLocation.x - CGFloat(col) * gridCellWidth
            if node?.sequence.euclidean != nil && cellLocalX > gridCellWidth * 0.8 {
                cellDragMode = .wobble
                dragStartValue = localWobble
            } else {
                cellDragMode = abs(drag.translation.width) > abs(drag.translation.height) ? .rotation : .pulses
                if node?.sequence.euclidean != nil {
                    dragStartValue = cellDragMode == .rotation ? Double(currentRotation) : Double(currentPulses)
                } else {
                    let active = currentPattern().filter { $0 }.count
                    dragStartValue = cellDragMode == .rotation ? 0 : Double(active)
                }
            }
        case 1: dragStartValue = localProbability
        case 2: dragStartValue = Double(columns)
        case 3: dragStartValue = localMutationAmount
        case 4: // RNG / OCT — right 20% = octave zone
            let col = cell % 3
            let cellLocalX = drag.startLocation.x - CGFloat(col) * gridCellWidth
            if cellLocalX > gridCellWidth * 0.8 {
                cellDragMode = .rngOctave
                dragStartValue = Double(node?.sequence.octaveOffset ?? 0)
            } else {
                cellDragMode = .rngRange
                dragStartValue = Double(node?.sequence.mutation?.range ?? 1)
            }
        case 5: dragStartValue = Double(node?.sequence.fifthRotation ?? 0)
        default: break
        }
    }

    private func handleGenerateDrag(cell: Int, drag: DragGesture.Value) {
        switch cell {
        case 0: // EUC
            if cellDragMode == nil {
                cellDragMode = abs(drag.translation.width) > abs(drag.translation.height) ? .rotation : .pulses
                if node?.sequence.euclidean != nil {
                    dragStartValue = cellDragMode == .rotation ? Double(currentRotation) : Double(currentPulses)
                } else {
                    let active = currentPattern().filter { $0 }.count
                    dragStartValue = cellDragMode == .rotation ? 0 : Double(active)
                }
            }
            let cols = columns
            switch cellDragMode {
            case .rotation:
                let delta = Int(round(drag.translation.width / (20 * cs)))
                let newR = max(0, min(cols - 1, Int(dragStartValue) + delta))
                applyEuclidean(pulses: currentPulses, rotation: newR)
            case .pulses:
                let delta = -Int(round(drag.translation.height / (20 * cs)))
                let newE = max(0, min(cols, Int(dragStartValue) + delta))
                applyEuclidean(pulses: newE, rotation: currentRotation)
            case .wobble:
                let delta = -drag.translation.height / (150 * cs)
                localWobble = max(0, min(1, dragStartValue + Double(delta)))
            case .rngRange, .rngOctave, .none: break
            }
        case 1: // PROB
            let delta = -drag.translation.height / (150 * cs)
            localProbability = max(0, min(1, dragStartValue + Double(delta)))
            guard let nodeID = projectState.selectedNodeID else { return }
            AudioEngine.shared.setGlobalProbability(localProbability, nodeID: nodeID)
        case 2: // STEPS
            let stepDelta = -Int(round(drag.translation.height / (15 * cs)))
            let newSteps = max(1, min(32, Int(dragStartValue) + stepDelta))
            if newSteps != columns { changeLength(to: newSteps) }
        case 3: // MUT
            let delta = -drag.translation.height / (150 * cs)
            localMutationAmount = max(0, min(1, dragStartValue + Double(delta)))
            guard let nodeID = projectState.selectedNodeID else { return }
            let key = resolveKey()
            AudioEngine.shared.setMutation(amount: localMutationAmount, range: node?.sequence.mutation?.range ?? 1,
                                           rootSemitone: key.root.semitone, intervals: key.mode.intervals, nodeID: nodeID)
        case 4: // RNG / OCT
            if cellDragMode == .rngOctave {
                let stepDelta = -Int(round(drag.translation.height / (25 * cs)))
                let newOct = max(-3, min(3, Int(dragStartValue) + stepDelta))
                if newOct != (node?.sequence.octaveOffset ?? 0) { setOctaveOffset(newOct) }
            } else {
                let stepDelta = -Int(round(drag.translation.height / (25 * cs)))
                let newRange = max(1, min(7, Int(dragStartValue) + stepDelta))
                if newRange != (node?.sequence.mutation?.range ?? 1) { setMutationRange(newRange) }
            }
        case 5: // FIFTH
            let delta = Int(round(drag.translation.width / (25 * cs)))
            let newRot = max(-6, min(6, Int(dragStartValue) + delta))
            if newRot != (node?.sequence.fifthRotation ?? 0) { setFifthRotation(newRot) }
        default: break
        }
    }

    private func commitGenerateDrag(cell: Int) {
        switch cell {
        case 0:
            if cellDragMode == .wobble {
                guard let nodeID = projectState.selectedNodeID else { return }
                SequencerActions.setWobble(localWobble, projectState: projectState, nodeID: nodeID)
            }
        case 1: commitGlobalProbability()
        case 3: commitMutationAmount()
        default: break
        }
    }

    // MARK: - TRANSFORM Drag

    private func initializeTransformDrag(cell: Int) {
        switch cell {
        case 0: dragStartValue = localBloomAmount
        case 2: dragStartValue = localDensity
        case 4: dragStartValue = localDriftRate
        case 5: dragStartValue = localHumanize
        default: break
        }
    }

    private func handleTransformDrag(cell: Int, drag: DragGesture.Value) {
        switch cell {
        case 0: // BLOOM
            let delta = -drag.translation.height / (150 * cs)
            localBloomAmount = max(0, min(1, dragStartValue + Double(delta)))
        case 1: // INVERT — drag shifts pivot (when on)
            if node?.sequence.invertEnabled ?? false {
                let delta = -Int(round(drag.translation.height / (15 * cs)))
                let current = node?.sequence.invertPivot ?? 60
                let newPivot = max(24, min(96, current + delta))
                setInvertPivot(newPivot)
            }
        case 2: // DENSITY
            let delta = -drag.translation.height / (150 * cs)
            localDensity = max(0, min(1, dragStartValue + Double(delta)))
        case 4: // DRIFT
            let delta = -drag.translation.height / (150 * cs)
            localDriftRate = max(0, min(1, dragStartValue + Double(delta)))
        case 5: // HUMAN
            let delta = -drag.translation.height / (150 * cs)
            localHumanize = max(0, min(1, dragStartValue + Double(delta)))
        default: break
        }
    }

    private func commitTransformDrag(cell: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        switch cell {
        case 0: SequencerActions.setBloomAmount(localBloomAmount, projectState: projectState, nodeID: nodeID)
        case 2: SequencerActions.setDensity(localDensity, projectState: projectState, nodeID: nodeID)
        case 4: SequencerActions.setDriftRate(localDriftRate, projectState: projectState, nodeID: nodeID)
        case 5: SequencerActions.setHumanize(localHumanize, projectState: projectState, nodeID: nodeID)
        default: break
        }
    }

    private func handleTransformTap(cell: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        switch cell {
        case 1: SequencerActions.toggleInvert(projectState: projectState, nodeID: nodeID)
        case 3: SequencerActions.toggleMirror(projectState: projectState, nodeID: nodeID)
        default: break
        }
    }

    // MARK: - PLAY Drag

    private func initializePlayDrag(cell: Int) {
        switch cell {
        case 1: dragStartValue = localSwing
        case 2: dragStartValue = localGateLength
        case 4: dragStartValue = Double(arpRateIndex(node?.sequence.arpConfig?.rate ?? .sixteenth))
        case 5: dragStartValue = Double(node?.sequence.arpConfig?.octaveRange ?? 1)
        default: break
        }
    }

    private func handlePlayDrag(cell: Int, drag: DragGesture.Value) {
        switch cell {
        case 1: // SWING
            let delta = -drag.translation.height / (200 * cs)
            localSwing = max(0, min(0.75, dragStartValue + Double(delta)))
        case 2: // GATE
            let delta = -drag.translation.height / (150 * cs)
            localGateLength = max(0.05, min(1.0, dragStartValue + Double(delta)))
        case 4: // RATE (when arp active)
            guard isArpActive else { return }
            let delta = -Int(round(drag.translation.height / (25 * cs)))
            let rates: [ArpRate] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
            let newIdx = max(0, min(rates.count - 1, Int(dragStartValue) + delta))
            setArpRate(rates[newIdx])
        case 5: // OCT (when arp active)
            guard isArpActive else { return }
            let delta = -Int(round(drag.translation.height / (25 * cs)))
            let newOct = max(1, min(4, Int(dragStartValue) + delta))
            setArpOctave(newOct)
        default: break
        }
    }

    private func commitPlayDrag(cell: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        switch cell {
        case 1: SequencerActions.setSwing(localSwing, projectState: projectState, nodeID: nodeID)
        case 2: SequencerActions.setGateLength(localGateLength, projectState: projectState, nodeID: nodeID)
        default: break
        }
    }

    private func handlePlayTap(cell: Int) {
        guard projectState.selectedNodeID != nil else { return }
        switch cell {
        case 0: // DIR — cycle through modes
            let dirs: [PlaybackDirection] = [.forward, .reverse, .pingPong, .random, .brownian]
            let current = node?.sequence.playbackDirection ?? .forward
            let idx = dirs.firstIndex(of: current) ?? 0
            let next = dirs[(idx + 1) % dirs.count]
            setDirection(next)
        case 3: // ARP — toggle
            toggleArp()
        default: break
        }
    }

    private func arpRateIndex(_ rate: ArpRate) -> Int {
        let rates: [ArpRate] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        return rates.firstIndex(of: rate) ?? 4
    }

    // ╔══════════════════════════════════════════════════════════════════╗
    // ║                     SYNC & ACTIONS                              ║
    // ╚══════════════════════════════════════════════════════════════════╝

    private func syncSeqFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
        localArpGate = node.sequence.arpConfig?.gateLength ?? 0.5
        localBloomAmount = node.sequence.bloomAmount ?? 0
        localDensity = node.sequence.density ?? 1.0
        localDriftRate = node.sequence.driftRate ?? 0
        localHumanize = node.sequence.humanize ?? 0
        localSwing = node.sequence.swing ?? 0
        localGateLength = node.sequence.gateLength ?? 0.75
        localWobble = node.sequence.euclidean?.wobble ?? 0
    }

    // MARK: - Action Wrappers

    private func commitGlobalProbability() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitGlobalProbability(localProbability, projectState: projectState, nodeID: nodeID)
    }

    private func commitMutationAmount() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitMutationAmount(localMutationAmount, projectState: projectState, nodeID: nodeID)
    }

    private func changeLength(to newStepCount: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.changeLength(to: newStepCount, projectState: projectState, nodeID: nodeID)
    }

    private func setDirection(_ dir: PlaybackDirection) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setDirection(dir, projectState: projectState, nodeID: nodeID)
    }

    private func applyEuclidean(pulses: Int, rotation: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.applyEuclidean(pulses: pulses, rotation: rotation, wobble: localWobble, projectState: projectState, nodeID: nodeID)
    }

    private func randomFill() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.randomFill(projectState: projectState, nodeID: nodeID)
    }

    private func setMutationRange(_ range: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setMutationRange(range, projectState: projectState, nodeID: nodeID)
    }

    private func setOctaveOffset(_ offset: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setOctaveOffset(offset, projectState: projectState, nodeID: nodeID)
    }

    private func freezeMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.freezeMutation(nodeID: nodeID)
    }

    private func resetMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.resetMutation(nodeID: nodeID)
    }

    private func setFifthRotation(_ rotation: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setFifthRotation(rotation, projectState: projectState, nodeID: nodeID)
    }

    private func setInvertPivot(_ pivot: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setInvertPivot(pivot, projectState: projectState, nodeID: nodeID)
    }

    private func setArpMode(_ mode: ArpMode) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setArpMode(mode, projectState: projectState, nodeID: nodeID)
    }

    private func setArpRate(_ rate: ArpRate) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setArpRate(rate, projectState: projectState, nodeID: nodeID)
    }

    private func setArpOctave(_ octave: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setArpOctave(octave, projectState: projectState, nodeID: nodeID)
    }

    private func toggleArp() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.toggleArp(projectState: projectState, nodeID: nodeID)
        syncSeqFromModel()
    }

    private func resolveKey() -> MusicalKey {
        guard let nodeID = projectState.selectedNodeID else {
            return projectState.project.globalKey
        }
        return SequencerActions.resolveKey(projectState: projectState, nodeID: nodeID)
    }
}
