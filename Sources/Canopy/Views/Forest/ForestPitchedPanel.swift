import SwiftUI

/// Forest-mode pitched sequencer: generative controls with all-interactive ASCII art knobs.
/// Replaces the piano roll grid with a Euclidean circle hero and parameter knob strips.
/// Matches FlowPanel's ASCII knob pattern (Canvas + TimelineView + DragGesture).
struct ForestPitchedPanel: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @Environment(\.canvasScale) var cs

    private let panelWidth: CGFloat = 380

    // MARK: - Local drag state

    @State private var localProbability: Double = 1.0
    @State private var localMutationAmount: Double = 0.0
    @State private var localAccAmount: Double = 1.0
    @State private var localAccLimit: Double = 12.0
    @State private var localArpGate: Double = 0.5

    // Unified grid drag tracking (cells 0-5: EUC, PROB, STEPS, MUT, RNG, ACC)
    @State private var activeCell: Int? = nil
    @State private var dragStartValue: Double = 0
    @State private var cellDragMode: CircleDragMode? = nil  // only for cell 0 (EUC)

    private enum CircleDragMode { case pulses, rotation }

    // MARK: - Constants

    private let euclideanGreen = Color(red: 0.2, green: 0.7, blue: 0.4)

    // MARK: - Computed Properties

    private var node: Node? { projectState.selectedNode }
    private var isArpActive: Bool { node?.sequence.arpConfig != nil }

    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    private var currentPulses: Int { node?.sequence.euclidean?.pulses ?? 4 }
    private var currentRotation: Int { node?.sequence.euclidean?.rotation ?? 0 }

    /// Boolean step pattern: from euclidean config or note occupancy fallback.
    private func currentPattern() -> [Bool] {
        guard let seq = node?.sequence else { return [] }
        let cols = columns
        if let euc = seq.euclidean {
            return EuclideanRhythm.generate(steps: cols, pulses: euc.pulses, rotation: euc.rotation)
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
        VStack(alignment: .leading, spacing: 8 * cs) {
            headerRow

            paramGrid

            if node?.sequence.accumulator != nil {
                accumulatorDetails
            }

            if isArpActive {
                arpDetailControls
            }
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

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6 * cs) {
            Text(isArpActive ? "ARP" : "SEQUENCE")
                .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(isArpActive ? CanopyColors.glowColor : CanopyColors.chromeText)

            ModuleSwapButton(
                options: [("Pitched", SequencerType.pitched), ("Drum", SequencerType.drum), ("Orbit", SequencerType.orbit), ("Spore", SequencerType.sporeSeq)],
                current: node?.sequencerType ?? .pitched,
                onChange: { type in
                    guard let nodeID = projectState.selectedNodeID else { return }
                    projectState.swapSequencer(nodeID: nodeID, to: type)
                }
            )

            Button(action: { toggleArp() }) {
                Text("ARP")
                    .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(isArpActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                    .padding(.horizontal, 6 * cs)
                    .padding(.vertical, 3 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 3 * cs)
                            .fill(isArpActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3 * cs)
                            .stroke(isArpActive ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)

            if node != nil {
                if isArpActive {
                    arpModePicker
                } else {
                    directionPicker
                }
            }

            Spacer()

            if isArpActive {
                arpHeaderControls
            } else {
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
    }

    // MARK: - Direction Picker

    private var directionPicker: some View {
        let currentDirection = node?.sequence.playbackDirection ?? .forward
        let directions: [(PlaybackDirection, String, String)] = [
            (.forward, "→", "Forward"),
            (.reverse, "←", "Reverse"),
            (.pingPong, "↔", "Ping-Pong"),
            (.random, "?", "Random"),
            (.brownian, "~", "Brownian"),
        ]

        return HStack(spacing: 3 * cs) {
            ForEach(directions, id: \.0) { dir, symbol, tooltip in
                let isActive = currentDirection == dir
                Button(action: { setDirection(dir) }) {
                    Text(symbol)
                        .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 22 * cs, height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
    }

    // MARK: - Arp Mode Picker

    private var arpModePicker: some View {
        let currentMode = node?.sequence.arpConfig?.mode ?? .up
        let modes: [(ArpMode, String, String)] = [
            (.up, "\u{2191}", "Up"),
            (.down, "\u{2193}", "Down"),
            (.upDown, "\u{2195}", "Up-Down"),
            (.downUp, "\u{21F5}", "Down-Up"),
            (.random, "?", "Random"),
            (.asPlayed, "\u{2192}", "As Played"),
        ]

        return HStack(spacing: 3 * cs) {
            ForEach(modes, id: \.0) { mode, symbol, tooltip in
                let isActive = currentMode == mode
                Button(action: { setArpMode(mode) }) {
                    Text(symbol)
                        .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 22 * cs, height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
    }

    // MARK: - Arp Header Controls

    private var arpHeaderControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()

        return HStack(spacing: 6 * cs) {
            dragValue(label: "Oct", value: arpConfig.octaveRange, range: 1...4,
                      color: CanopyColors.glowColor.opacity(0.7)) { setArpOctave($0) }

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

    // MARK: - Arp Detail Controls

    private var arpDetailControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
        let rates: [(ArpRate, String)] = [
            (.whole, "1"), (.half, "1/2"), (.quarter, "1/4"),
            (.eighth, "1/8"), (.sixteenth, "1/16"), (.thirtySecond, "1/32"),
        ]

        return VStack(alignment: .leading, spacing: 4 * cs) {
            HStack(spacing: 4 * cs) {
                Text("RATE")
                    .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                ForEach(rates, id: \.0) { rate, label in
                    let isActive = arpConfig.rate == rate
                    Button(action: { setArpRate(rate) }) {
                        Text(label)
                            .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                            .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                            .padding(.horizontal, 4 * cs)
                            .padding(.vertical, 2 * cs)
                            .background(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6 * cs) {
                Text("GATE")
                    .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                seqSlider(value: $localArpGate, range: 0.05...1.0, onCommit: {
                    commitArpGate()
                }, onDrag: {
                    guard let nodeID = projectState.selectedNodeID else { return }
                    let arp = node?.sequence.arpConfig ?? ArpConfig()
                    let sampleRate = AudioEngine.shared.sampleRate
                    let bpm = projectState.project.bpm
                    let beatsPerSecond = bpm / 60.0
                    let secondsPerStep = arp.rate.beatsPerStep / beatsPerSecond
                    let samplesPerStep = max(1, Int(secondsPerStep * sampleRate))
                    AudioEngine.shared.setArpConfig(
                        active: true, samplesPerStep: samplesPerStep,
                        gateLength: localArpGate, mode: arp.mode, nodeID: nodeID
                    )
                })
                    .frame(width: 100 * cs)

                Text("\(Int(localArpGate * 100))%")
                    .font(.system(size: 9 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(width: 30 * cs, alignment: .trailing)
            }

            if let sequence = node?.sequence, let config = sequence.arpConfig {
                Text(ArpNotePool.previewString(from: sequence, config: config))
                    .font(.system(size: 8 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Unified 3×2 Param Grid (EUC / PROB / STEPS / MUT / RNG / ACC)

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

                            switch idx {
                            case 0: drawEuclideanKnob(context: context, rect: rect, time: time, active: isActive)
                            case 1: drawProbKnob(context: context, rect: rect, value: localProbability, time: time, active: isActive)
                            case 2: drawStepsKnob(context: context, rect: rect, value: columns, time: time, active: isActive)
                            case 3: drawMutKnob(context: context, rect: rect, value: localMutationAmount, time: time, active: isActive)
                            case 4: drawRngKnob(context: context, rect: rect, value: node?.sequence.mutation?.range ?? 1, time: time, active: isActive)
                            case 5: drawAccKnob(context: context, rect: rect, time: time, active: isActive)
                            default: break
                            }
                        }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { drag in
                        if activeCell == nil {
                            let col = min(2, max(0, Int(drag.startLocation.x / cellW)))
                            let row = min(1, max(0, Int(drag.startLocation.y / cellH)))
                            let idx = row * 3 + col
                            activeCell = idx

                            switch idx {
                            case 0: // EUC: determine axis
                                cellDragMode = abs(drag.translation.width) > abs(drag.translation.height)
                                    ? .rotation : .pulses
                                if node?.sequence.euclidean != nil {
                                    dragStartValue = cellDragMode == .rotation
                                        ? Double(currentRotation) : Double(currentPulses)
                                } else {
                                    let active = currentPattern().filter { $0 }.count
                                    dragStartValue = cellDragMode == .rotation
                                        ? 0 : Double(active)
                                }
                            case 1: dragStartValue = localProbability
                            case 2: dragStartValue = Double(columns)
                            case 3: dragStartValue = localMutationAmount
                            case 4: dragStartValue = Double(node?.sequence.mutation?.range ?? 1)
                            case 5:
                                if node?.sequence.accumulator == nil {
                                    toggleAccumulator()
                                }
                                dragStartValue = localAccAmount
                            default: break
                            }
                        }

                        switch activeCell {
                        case 0: // EUC
                            // Re-determine axis if not yet set
                            if cellDragMode == nil {
                                cellDragMode = abs(drag.translation.width) > abs(drag.translation.height)
                                    ? .rotation : .pulses
                                if node?.sequence.euclidean != nil {
                                    dragStartValue = cellDragMode == .rotation
                                        ? Double(currentRotation) : Double(currentPulses)
                                } else {
                                    let active = currentPattern().filter { $0 }.count
                                    dragStartValue = cellDragMode == .rotation
                                        ? 0 : Double(active)
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
                            case .none: break
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
                            AudioEngine.shared.setMutation(
                                amount: localMutationAmount,
                                range: node?.sequence.mutation?.range ?? 1,
                                rootSemitone: key.root.semitone,
                                intervals: key.mode.intervals,
                                nodeID: nodeID
                            )
                        case 4: // RNG
                            let stepDelta = -Int(round(drag.translation.height / (25 * cs)))
                            let newRange = max(1, min(7, Int(dragStartValue) + stepDelta))
                            if newRange != (node?.sequence.mutation?.range ?? 1) {
                                setMutationRange(newRange)
                            }
                        case 5: // ACC
                            let stepDelta = -Int(round(drag.translation.height / (15 * cs)))
                            let newAmt = max(-12, min(12, Int(dragStartValue) + stepDelta))
                            localAccAmount = Double(newAmt)
                        default: break
                        }
                    }
                    .onEnded { _ in
                        switch activeCell {
                        case 0: break // already committed via applyEuclidean
                        case 1: commitGlobalProbability()
                        case 2: break // already committed via changeLength
                        case 3: commitMutationAmount()
                        case 4: break // already committed via setMutationRange
                        case 5: commitAccumulatorAmount()
                        default: break
                        }
                        activeCell = nil
                        cellDragMode = nil
                    }
            )
        }
        .frame(height: gridHeight)
        .overlay(
            // Freeze / Reset icons overlaid on MUT cell (row 1, col 0) upper-right
            GeometryReader { geo in
                let cW = geo.size.width / 3
                let cH = geo.size.height / 2
                VStack(spacing: 4 * cs) {
                    Button(action: { freezeMutation() }) {
                        Text("❄")
                            .font(.system(size: 10 * cs, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Freeze mutations")

                    Button(action: { resetMutation() }) {
                        Text("↺")
                            .font(.system(size: 11 * cs, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help("Reset mutations")
                }
                .position(x: cW - 8 * cs, y: cH + cH * 0.35)
            }
        )
    }

    // MARK: - Euclidean Knob (cell-sized circle)

    private func drawEuclideanKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let cols = columns
        let pattern = currentPattern()
        let center = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.38)
        let radius = min(rect.width * 0.85, rect.height * 0.55) * 0.36
        let dotFontSize: CGFloat = cols > 24 ? max(6, 7 * cs) : max(7, 9 * cs)

        // Playhead
        let nodeID = node?.id ?? UUID()
        let engine = AudioEngine.shared
        let isPlaying = engine.isPlaying(for: nodeID)
        let currentBeat = engine.currentBeat(for: nodeID)
        let seqLen = node?.sequence.lengthInBeats ?? 1
        let beatFrac = currentBeat / max(seqLen, 1)
        let playheadStep = isPlaying ? Int(beatFrac * Double(cols)) % cols : -1
        let pulse = 0.7 + 0.3 * sin(time * 6)

        // Gather hit indices for connecting lines
        var hitIndices: [Int] = []
        for i in 0..<min(cols, pattern.count) {
            if pattern[i] { hitIndices.append(i) }
        }

        // Draw connecting lines between adjacent hits
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

        // Draw dots
        for i in 0..<cols {
            let point = circlePoint(center: center, radius: radius, step: i, total: cols)
            let isHit = i < pattern.count && pattern[i]
            let isPlayhead = i == playheadStep

            let color: Color
            if isPlayhead {
                color = CanopyColors.glowColor.opacity(pulse)
            } else if isHit {
                color = euclideanGreen
            } else {
                color = CanopyColors.chromeText.opacity(0.2)
            }

            let char = isHit ? "●" : "○"
            let scale: CGFloat = isPlayhead ? 1.3 : 1.0
            drawChar(context, char, at: point, size: dotFontSize * scale, color: color)
        }

        // Label + value (matching other knobs)
        let labelFontSize = max(9, 11 * cs) * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "EUC", centerX: rect.midX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        let valueStr = "\(currentPulses)/\(cols)"
        drawString(context, valueStr, centerX: rect.midX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - Accumulator Details

    private var accumulatorDetails: some View {
        let acc = node?.sequence.accumulator
        let accTarget = acc?.target ?? .pitch
        let accMode = acc?.mode ?? .clamp

        return HStack(spacing: 4 * cs) {
            Button(action: { toggleAccumulator() }) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 9 * cs))
                    .foregroundColor(CanopyColors.glowColor.opacity(0.6))
            }
            .buttonStyle(.plain)

            ForEach(AccumulatorTarget.allCases, id: \.self) { t in
                let sel = accTarget == t
                Button(action: { setAccumulatorTarget(t) }) {
                    Text(t.rawValue)
                        .font(.system(size: 8 * cs, design: .monospaced))
                        .foregroundColor(sel ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                        .padding(.horizontal, 4 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 2 * cs)
                                .fill(sel ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            ForEach(AccumulatorMode.allCases, id: \.self) { m in
                let sel = accMode == m
                Button(action: { setAccumulatorMode(m) }) {
                    Text(m.rawValue)
                        .font(.system(size: 8 * cs, design: .monospaced))
                        .foregroundColor(sel ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                        .padding(.horizontal, 4 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 2 * cs)
                                .fill(sel ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }

            dragValue(label: "Lim", value: Int(localAccLimit), range: 1...48,
                      color: CanopyColors.chromeText.opacity(0.4)) { val in
                localAccLimit = Double(val)
                commitAccumulatorLimit()
            }
        }
    }


    // MARK: - Draw Helpers

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

    // MARK: - Circle Geometry

    private func circlePoint(center: CGPoint, radius: CGFloat, step: Int, total: Int) -> CGPoint {
        let angle = -Double.pi / 2 + (Double(step) / Double(max(1, total))) * 2 * Double.pi
        return CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    // MARK: - PROB Knob (probability rain)

    private func drawProbKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        let gridCols = 5
        let gridRows = 4
        let gridStartX = centerX - CGFloat(gridCols) * cellW / 2 + cellW / 2
        let gridStartY = artCenterY - CGFloat(gridRows) * rowH / 2 + rowH / 2

        let shimmerTick = Int(fmod(time * 8, 1000))

        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x = gridStartX + CGFloat(col) * cellW
                let y = gridStartY + CGFloat(row) * rowH

                let dx = abs(col - gridCols / 2)
                let dy = abs(row - gridRows / 2)
                let dist = max(dx, dy)

                let threshold = Double(dist) * 0.25 + 0.08
                if value < threshold { continue }

                let intensity = min(1.0, (value - threshold) / 0.3)
                let ch: String
                if intensity < 0.3 { ch = "·" }
                else if intensity < 0.6 { ch = "•" }
                else { ch = "●" }

                let cellHash = (row * 7 + col + shimmerTick) % 11
                let shimmer = cellHash == 0 && value > 0.25
                let finalCh: String
                if shimmer {
                    if intensity < 0.5 { finalCh = intensity < 0.3 ? "•" : "·" }
                    else { finalCh = intensity < 0.8 ? "•" : "●" }
                } else {
                    finalCh = ch
                }

                drawChar(context, finalCh, at: CGPoint(x: x, y: y), size: fontSize,
                         color: color.opacity(0.55 + intensity * 0.45))
            }
        }

        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "PROB", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(Int(value * 100))%", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - STEPS Knob (step ruler)

    private func drawStepsKnob(context: GraphicsContext, rect: CGRect, value: Int, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.5
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55
        let activeColor = CanopyColors.glowColor.opacity(op)

        // Split into rows: row 0 = steps 1-16, row 1 = steps 17-32
        let rowCount = value > 16 ? 2 : 1

        for rowIdx in 0..<rowCount {
            let rowOffset = rowIdx * 16
            let rowSteps = min(16, value - rowOffset)
            let groups = (rowSteps + 3) / 4
            let totalChars = groups * 5 + 1 // ┃····┃····┃ = 5 per group + final ┃
            let totalWidth = CGFloat(totalChars) * cellW
            let startX = centerX - totalWidth / 2 + cellW / 2
            let y = artCenterY + CGFloat(rowIdx) * rowH - CGFloat(rowCount - 1) * rowH * 0.5

            var charPos = 0
            for g in 0..<groups {
                // Separator
                let sx = startX + CGFloat(charPos) * cellW
                drawChar(context, "┃", at: CGPoint(x: sx, y: y), size: fontSize,
                         color: CanopyColors.chromeText.opacity(0.3))
                charPos += 1

                let stepsInGroup = min(4, rowSteps - g * 4)
                for s in 0..<4 {
                    let x = startX + CGFloat(charPos) * cellW
                    if s < stepsInGroup {
                        drawChar(context, "·", at: CGPoint(x: x, y: y), size: fontSize, color: activeColor)
                    }
                    charPos += 1
                }
            }
            // Final separator
            let fx = startX + CGFloat(charPos) * cellW
            drawChar(context, "┃", at: CGPoint(x: fx, y: y), size: fontSize,
                     color: CanopyColors.chromeText.opacity(0.3))
        }

        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "STEPS", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(value)", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - MUT Knob (mutation chaos)

    private func drawMutKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55

        // Color shifts from calm to warm at high values
        let color: Color
        if value < 0.3 {
            color = CanopyColors.glowColor.opacity(op)
        } else if value < 0.6 {
            color = Color(red: 0.6, green: 0.7, blue: 0.3).opacity(op)
        } else {
            color = Color(red: 0.8, green: 0.5, blue: 0.2).opacity(op)
        }

        let gridCols = 5
        let gridRows = 3
        let gridStartX = centerX - CGFloat(gridCols) * cellW / 2 + cellW / 2
        let gridStartY = artCenterY - CGFloat(gridRows) * rowH / 2 + rowH / 2

        let chaosChars = ["─", "~", "∿", "≈"]

        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x = gridStartX + CGFloat(col) * cellW
                let y = gridStartY + CGFloat(row) * rowH

                let phase = fmod(time * (1.0 + value * 3.0) + Double(row) * 0.7 + Double(col) * 0.3, 4.0)
                let maxIndex = min(3, Int(value * 4.0))
                let charIndex: Int
                if maxIndex == 0 {
                    charIndex = 0
                } else {
                    charIndex = min(maxIndex, Int(phase) % (maxIndex + 1))
                }

                drawChar(context, chaosChars[charIndex], at: CGPoint(x: x, y: y), size: fontSize,
                         color: color.opacity(0.55 + value * 0.45))
            }
        }

        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "MUT", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(Int(value * 100))%", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - RNG Knob (mutation range spread)

    private func drawRngKnob(context: GraphicsContext, rect: CGRect, value: Int, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55
        let color = CanopyColors.glowColor.opacity(op)

        // Build spread string: ←──·──→
        let halfWidth = value
        let arrowStr: String
        if halfWidth <= 1 {
            arrowStr = "←·→"
        } else {
            let dashes = String(repeating: "─", count: halfWidth - 1)
            arrowStr = "←\(dashes)·\(dashes)→"
        }

        drawString(context, arrowStr, centerX: centerX, y: artCenterY, cellW: cellW, fontSize: fontSize,
                   color: color)

        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "RNG", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(value)", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - ACC Knob (accumulator arrows)

    private func drawAccKnob(context: GraphicsContext, rect: CGRect, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.35

        let op: CGFloat = active ? 1.0 : 0.55
        let acc = node?.sequence.accumulator
        let enabled = acc != nil

        if !enabled {
            drawChar(context, "○", at: CGPoint(x: centerX, y: artCenterY), size: fontSize,
                     color: CanopyColors.chromeText.opacity(0.2))
        } else {
            let amount = acc?.amount ?? 1.0
            let mode = acc?.mode ?? .clamp
            let target = acc?.target ?? .pitch
            let color = CanopyColors.glowColor.opacity(op)

            let arrowCount = min(3, max(1, Int(abs(amount))))
            let arrowChar = amount >= 0 ? "↑" : "↓"

            for i in 0..<arrowCount {
                let y = artCenterY - CGFloat(i) * rowH * 0.7
                drawChar(context, arrowChar, at: CGPoint(x: centerX, y: y), size: fontSize, color: color)
            }

            // Mode icon
            let modeY = artCenterY + rowH * 0.8
            let modeChar: String
            switch mode {
            case .clamp: modeChar = "│"
            case .wrap: modeChar = "↻"
            case .pingPong: modeChar = "↔"
            }
            drawChar(context, modeChar, at: CGPoint(x: centerX, y: modeY), size: fontSize,
                     color: CanopyColors.chromeText.opacity(0.4))

            // Target label
            let targetStr: String
            switch target {
            case .pitch: targetStr = "pit"
            case .velocity: targetStr = "vel"
            case .probability: targetStr = "prb"
            }
            let targetY = modeY + rowH * 0.6
            let targetCellW = fontSize * 0.5
            drawString(context, targetStr, centerX: centerX, y: targetY, cellW: targetCellW,
                       fontSize: fontSize * 0.75, color: CanopyColors.chromeText.opacity(0.35))
        }

        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "ACC", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueStr = enabled ? String(format: "%+.0f", acc?.amount ?? 0) : "off"
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, valueStr, centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    // MARK: - Sync

    private func syncSeqFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
        localAccAmount = node.sequence.accumulator?.amount ?? 1.0
        localAccLimit = node.sequence.accumulator?.limit ?? 12.0
        localArpGate = node.sequence.arpConfig?.gateLength ?? 0.5
    }

    // MARK: - Custom Controls

    private func dragValue(label: String, value: Int, range: ClosedRange<Int>, color: Color = CanopyColors.chromeText.opacity(0.7), onChange: @escaping (Int) -> Void) -> some View {
        let dragSensitivity: CGFloat = 8
        return HStack(spacing: 3 * cs) {
            Text(label)
                .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(color)

            Text("\(value)")
                .font(.system(size: 10 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.8))
                .frame(width: 22 * cs, height: 18 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(CanopyColors.chromeBackground.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 0.5)
                )
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            let delta = -Int(round(drag.translation.height / dragSensitivity))
                            let newVal = max(range.lowerBound, min(range.upperBound, value + delta))
                            onChange(newVal)
                        }
                )
                .onTapGesture {
                    let next = value + 1 > range.upperBound ? range.lowerBound : value + 1
                    onChange(next)
                }
        }
    }

    private func seqSlider(value: Binding<Double>, range: ClosedRange<Double>, onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let filledWidth = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8 * cs)

                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.glowColor.opacity(0.6))
                    .frame(width: filledWidth, height: 8 * cs)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = max(0, min(1, drag.location.x / width))
                        value.wrappedValue = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                        onDrag()
                    }
                    .onEnded { _ in
                        onCommit()
                    }
            )
        }
        .frame(height: 8 * cs)
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

    private func commitAccumulatorAmount() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitAccumulatorAmount(localAccAmount, projectState: projectState, nodeID: nodeID)
    }

    private func commitAccumulatorLimit() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitAccumulatorLimit(localAccLimit, projectState: projectState, nodeID: nodeID)
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
        SequencerActions.applyEuclidean(pulses: pulses, rotation: rotation, projectState: projectState, nodeID: nodeID)
    }

    private func randomFill() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.randomFill(projectState: projectState, nodeID: nodeID)
    }

    private func setMutationRange(_ range: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setMutationRange(range, projectState: projectState, nodeID: nodeID)
    }

    private func freezeMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.freezeMutation(nodeID: nodeID)
    }

    private func resetMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.resetMutation(nodeID: nodeID)
    }

    private func toggleAccumulator() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.toggleAccumulator(projectState: projectState, nodeID: nodeID)
        syncSeqFromModel()
    }

    private func setAccumulatorTarget(_ target: AccumulatorTarget) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setAccumulatorTarget(target, projectState: projectState, nodeID: nodeID)
    }

    private func setAccumulatorMode(_ mode: AccumulatorMode) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.setAccumulatorMode(mode, projectState: projectState, nodeID: nodeID)
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

    private func commitArpGate() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitArpGate(localArpGate, projectState: projectState, nodeID: nodeID)
    }

    private func toggleArp() {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.toggleArp(projectState: projectState, nodeID: nodeID)
        syncSeqFromModel()
    }

    // MARK: - Key Resolution

    private func resolveKey() -> MusicalKey {
        guard let nodeID = projectState.selectedNodeID else {
            return projectState.project.globalKey
        }
        return SequencerActions.resolveKey(projectState: projectState, nodeID: nodeID)
    }
}
