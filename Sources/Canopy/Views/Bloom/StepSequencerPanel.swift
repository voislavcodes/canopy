import SwiftUI

/// Bloom panel: step sequencer grid with algorithmic features.
/// Dynamic column count based on node's sequence length.
/// Derives boolean state from NoteSequence.notes.
///
/// Continuous sliders (probability, mutation amount, accumulator amount/limit)
/// use local @State during drag to avoid cascading @Published updates.
/// Discrete controls (S/E/R, direction, toggles) commit immediately since
/// they trigger reloadSequence() which is necessary.
struct StepSequencerPanel: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @Environment(\.canvasScale) var cs

    private let rows = 8
    /// Fixed panel width in base units (scaled by cs).
    private let panelWidth: CGFloat = 440

    /// MIDI range for the touch strip (C1 to C7)
    private let midiLow = 24
    private let midiHigh = 96

    @State private var baseNote: Int = 55  // G3 — scrollable via touch strip
    @State private var showAdvanced = false

    // MARK: - Local drag state for continuous sliders

    @State private var localProbability: Double = 1.0
    @State private var localMutationAmount: Double = 0.0
    @State private var localAccAmount: Double = 1.0
    @State private var localAccLimit: Double = 12.0
    @State private var localArpGate: Double = 0.5
    @State private var spanDragState: (pitch: Int, startStep: Int, currentEndStep: Int)?

    private var node: Node? {
        projectState.selectedNode
    }

    private var scaleAwareEnabled: Bool {
        projectState.project.scaleAwareEnabled
    }

    private var isArpActive: Bool {
        node?.sequence.arpConfig != nil
    }

    /// The MIDI pitches to show as rows, highest first.
    /// When scale-aware: only in-scale pitches starting from baseNote, take `rows` count.
    /// When off: baseNote ..< baseNote + rows (current behavior).
    private var visiblePitches: [Int] {
        if scaleAwareEnabled {
            let key = resolveKey()
            var pitches: [Int] = []
            var p = baseNote
            while pitches.count < rows && p <= 127 {
                let pc = ((p % 12) - key.root.semitone + 12) % 12
                if key.mode.intervals.contains(pc) {
                    pitches.append(p)
                }
                p += 1
            }
            return pitches.reversed()
        } else {
            return ((0..<rows).map { baseNote + $0 }).reversed()
        }
    }

    /// Active step count from the sequence length.
    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    /// Always render 32 columns so grid size never changes.
    private var displayColumns: Int { 32 }

    // MARK: - ASCII Grid Geometry

    /// 32 content chars + 8 beat separators + 1 left edge = 41 char columns
    private var gridCharCols: Int { 41 }

    /// Font size derived from panel width so the grid fills available space.
    /// Available = panelWidth - padding(28) - labels(22) - touchStrip(~10) - spacings(8)
    private var gridFontSize: CGFloat {
        let available = (panelWidth - 68) * cs
        let size = available / (CGFloat(gridCharCols) * 0.62)
        return max(9, size)
    }
    private var gridCellW: CGFloat { gridFontSize * 0.62 }
    private var gridRowH: CGFloat { gridFontSize * 1.9 }

    /// Average pixel width per step (accounts for separator columns between steps).
    private var pixelsPerStep: CGFloat { gridCellW * CGFloat(gridCharCols) / CGFloat(displayColumns) }

    /// Derive cellSize/cellSpacing from ASCII geometry for span overlay compatibility.
    private var cellSize: CGFloat { gridCellW }
    private var cellSpacing: CGFloat { 0 }

    /// Pre-computed mapping: step index (0-31) → character column in the 41-col layout.
    /// Layout: ║····║····║····║····║····║····║····║····║
    /// Col 0 = left ║, then 4 steps, then ║, etc.
    /// Separators at cols: 0, 5, 10, 15, 20, 25, 30, 35, 40
    private var stepToCharCol: [Int] {
        var map = [Int]()
        for step in 0..<displayColumns {
            let group = step / 4  // which beat group (0-7)
            // Column = (group+1) separators seen so far + step index
            map.append(group + 1 + step)
        }
        return map
    }

    /// Reverse mapping: character column → step index (nil for separator columns).
    private var charColToStep: [Int?] {
        var map = [Int?](repeating: nil, count: gridCharCols)
        let fwd = stepToCharCol
        for (step, col) in fwd.enumerated() {
            if col < gridCharCols { map[col] = step }
        }
        return map
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header: title, direction/arp mode, S/E/R/arp controls
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

                // Arp toggle
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
                    headerControls
                }
            }

            if let node {
                HStack(alignment: .top, spacing: 4 * cs) {
                    // Touch strip (left of grid)
                    pitchTouchStrip

                    // Note labels
                    noteLabels

                    // ASCII grid + span drag handles
                    ZStack(alignment: .topLeading) {
                        asciiGridCanvas(sequence: node.sequence, nodeID: node.id)

                        spanDragHandles(sequence: node.sequence)
                    }
                }
            }

            // Arp controls (rate, octave, gate) when arp active
            if isArpActive {
                arpDetailControls
            }

            // Probability slider
            probabilitySlider

            // Advanced toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() } }) {
                HStack(spacing: 4 * cs) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8 * cs))
                    Text("Advanced")
                        .font(.system(size: 10 * cs, design: .monospaced))
                }
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }
            .buttonStyle(.plain)

            if showAdvanced {
                mutationControls
                accumulatorControls
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

    // MARK: - Sync local state from model

    private func syncSeqFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
        localAccAmount = node.sequence.accumulator?.amount ?? 1.0
        localAccLimit = node.sequence.accumulator?.limit ?? 12.0
        localArpGate = node.sequence.arpConfig?.gateLength ?? 0.5
    }

    // MARK: - Header Controls (S / E / R / dice)

    private var headerControls: some View {
        let euclidean = node?.sequence.euclidean
        let pulses = euclidean?.pulses ?? 4
        let rotation = euclidean?.rotation ?? 0

        return HStack(spacing: 6 * cs) {
            dragValue(label: "S", value: columns, range: 1...32) { changeLength(to: $0) }

            dragValue(
                label: "E", value: pulses, range: 0...columns,
                color: euclidean != nil ? Color(red: 0.2, green: 0.7, blue: 0.4) : CanopyColors.chromeText.opacity(0.4)
            ) { applyEuclidean(pulses: $0, rotation: rotation) }

            dragValue(
                label: "R", value: rotation, range: 0...(max(1, columns - 1)),
                color: CanopyColors.chromeText.opacity(0.4)
            ) { applyEuclidean(pulses: pulses, rotation: $0) }

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

    // MARK: - Touch Strip (ASCII)

    /// Ableton Push-style vertical touch strip for scrolling the visible pitch range.
    private var pitchTouchStrip: some View {
        let pitchCount = visiblePitches.count
        let stripHeight = CGFloat(pitchCount) * gridRowH
        let totalRange = midiHigh - midiLow - rows
        let normalizedPos = totalRange > 0
            ? CGFloat(baseNote - midiLow) / CGFloat(totalRange)
            : 0.5
        let stripRows = pitchCount
        let thumbRow = max(0, min(stripRows - 1, Int(round(Double(stripRows - 1) * (1.0 - normalizedPos)))))
        let fontSize = gridFontSize
        let cw = gridCellW
        let rh = gridRowH

        return Canvas { context, size in
            for row in 0..<stripRows {
                let y = CGFloat(row) * rh + rh / 2
                let x = cw / 2
                if row == thumbRow {
                    drawCharSeq(context, "█", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.glowColor.opacity(0.6))
                } else {
                    drawCharSeq(context, "│", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.chromeText.opacity(0.15))
                }
            }
        }
        .frame(width: cw + 2, height: stripHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = 1.0 - (value.location.y / stripHeight)
                    let clamped = max(0, min(1, fraction))
                    let totalRange = midiHigh - midiLow - rows
                    baseNote = midiLow + Int(round(clamped * CGFloat(totalRange)))
                    baseNote = max(midiLow, min(midiHigh - rows, baseNote))
                }
        )
    }

    // MARK: - Note Labels

    /// Shows pitch names for each visible row, to the left of the grid.
    private var noteLabels: some View {
        let pitches = visiblePitches
        let rh = gridRowH
        let gridHeight = CGFloat(pitches.count) * rh
        let rootSemitone = resolveKey().root.semitone
        return VStack(spacing: 0) {
            ForEach(pitches, id: \.self) { pitch in
                let name = MIDIUtilities.noteName(forNote: pitch)
                let isRoot = ((pitch % 12) - rootSemitone + 12) % 12 == 0
                let isC = pitch % 12 == 0
                let highlight = scaleAwareEnabled ? isRoot : isC
                Text(name)
                    .font(.system(size: 7 * cs, weight: highlight ? .bold : .regular, design: .monospaced))
                    .foregroundColor(highlight ? CanopyColors.glowColor.opacity(0.7) : CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 22 * cs, height: rh, alignment: .trailing)
            }
        }
        .frame(height: gridHeight)
    }

    // MARK: - Grid

    /// Build a lookup for O(1) note access: key = (pitch, step) → NoteEvent
    private func noteEventLookup(for sequence: NoteSequence) -> [Int: NoteEvent] {
        var dict = [Int: NoteEvent]()
        dict.reserveCapacity(sequence.notes.count)
        for event in sequence.notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            let key = event.pitch &* 1000 &+ step  // unique key for pitch/step pair
            dict[key] = event
        }
        return dict
    }

    // MARK: - ASCII Grid Canvas

    /// Build a set of (pitch, step) pairs that are span continuations (not the start cell).
    private func spanContinuationSet(for sequence: NoteSequence) -> Set<Int> {
        let sd = NoteSequence.stepDuration
        var set = Set<Int>()
        for note in sequence.notes {
            let startStep = Int(round(note.startBeat / sd))
            let endStep: Int
            if let drag = spanDragState, drag.pitch == note.pitch && drag.startStep == startStep {
                endStep = drag.currentEndStep
            } else {
                endStep = max(startStep + 1, Int(round((note.startBeat + note.duration) / sd)))
            }
            // Mark continuation cells (skip the start cell)
            for s in (startStep + 1)..<endStep {
                set.insert(note.pitch &* 1000 &+ s)
            }
        }
        return set
    }

    private func asciiGridCanvas(sequence: NoteSequence, nodeID: UUID) -> some View {
        let lookup = noteEventLookup(for: sequence)
        let continuations = spanContinuationSet(for: sequence)
        let pitches = visiblePitches
        let cols = columns
        let isArp = isArpActive
        let hasEuclidean = sequence.euclidean != nil
        let arpPitches: Set<Int> = isArp ? Set(sequence.notes.map { $0.pitch }) : []
        let fontSize = gridFontSize
        let cw = gridCellW
        let rh = gridRowH
        let charCols = gridCharCols
        let colMap = stepToCharCol
        let reverseMap = charColToStep

        // Pre-compute step velocities for velocity row
        var stepVelocities = [Int: Double]()
        for event in sequence.notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            if let existing = stepVelocities[step] {
                if event.velocity > existing { stepVelocities[step] = event.velocity }
            } else {
                stepVelocities[step] = event.velocity
            }
        }

        // Total rows: pitchRows + 1 bottom border + 1 velocity row
        let pitchRowCount = pitches.count
        let totalRows = pitchRowCount + 2
        let canvasWidth = CGFloat(charCols) * cw
        let canvasHeight = CGFloat(totalRows) * rh

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let engine = AudioEngine.shared
            let isPlaying = engine.isPlaying(for: nodeID)
            let currentBeat = engine.currentBeat(for: nodeID)
            let beatFraction = currentBeat / max(sequence.lengthInBeats, 1)
            let playheadStep = isPlaying ? Int(beatFraction * Double(cols)) % cols : -1
            let pulse: CGFloat = 0.7 + 0.3 * CGFloat(sin(time * 6))

            Canvas { context, size in
                let euclideanGreen = Color(red: 0.2, green: 0.7, blue: 0.4)
                let arpCyan = Color(red: 0.2, green: 0.7, blue: 0.8)
                let borderColor = CanopyColors.chromeText.opacity(0.15)

                // === Pitch rows ===
                for (rowIdx, pitch) in pitches.enumerated() {
                    let y = CGFloat(rowIdx) * rh + rh / 2

                    for charCol in 0..<charCols {
                        let x = CGFloat(charCol) * cw + cw / 2

                        // Determine if this is a separator column
                        let stepIdx = charCol < charCols ? reverseMap[charCol] : nil

                        if stepIdx == nil {
                            // Separator column: ║
                            let isPlayheadAdj = isPlaying && playheadStep >= 0 && {
                                let phCol = colMap[playheadStep]
                                return charCol == phCol - 1 || charCol == phCol + 1
                            }()
                            let sepColor = isPlayheadAdj
                                ? CanopyColors.glowColor.opacity(0.3 * Double(pulse))
                                : borderColor
                            drawCharSeq(context, "║", at: CGPoint(x: x, y: y), size: fontSize, color: sepColor)
                        } else if let step = stepIdx {
                            let enabled = step < cols
                            let isPlayhead = step == playheadStep
                            let noteEvent = enabled ? lookup[pitch &* 1000 &+ step] : nil
                            let isActive = noteEvent != nil
                            let isContinuation = continuations.contains(pitch &* 1000 &+ step)
                            let velocity = noteEvent?.velocity ?? 0.8
                            let probability = noteEvent?.probability ?? 1.0
                            let ratchetCount = noteEvent?.ratchetCount ?? 1
                            let dimFactor: Double = enabled ? 1.0 : 0.25

                            // Determine character and color
                            let char: String
                            let color: Color

                            if isContinuation {
                                char = "─"
                                let baseCol: Color = isArp ? arpCyan : (hasEuclidean ? euclideanGreen : CanopyColors.gridCellActive)
                                color = isPlayhead
                                    ? CanopyColors.glowColor.opacity(Double(pulse))
                                    : baseCol.opacity(0.4 * dimFactor)
                            } else if isActive {
                                // Velocity-mapped fill character
                                if ratchetCount > 1 {
                                    char = "╪"
                                } else if velocity < 0.3 {
                                    char = "░"
                                } else if velocity < 0.6 {
                                    char = "▒"
                                } else if velocity < 0.85 {
                                    char = "▓"
                                } else {
                                    char = "█"
                                }
                                let baseCol: Color = isArp ? arpCyan : (hasEuclidean ? euclideanGreen : CanopyColors.gridCellActive)
                                color = isPlayhead
                                    ? CanopyColors.glowColor.opacity(Double(pulse))
                                    : baseCol.opacity((probability * 0.8 + 0.2) * dimFactor)
                            } else {
                                char = "·"
                                let arpDim = arpPitches.contains(pitch) ? 0.08 : 0.0
                                color = isPlayhead
                                    ? CanopyColors.glowColor.opacity(0.4 * Double(pulse))
                                    : CanopyColors.chromeText.opacity((enabled ? 0.15 : 0.06) + arpDim)
                            }

                            drawCharSeq(context, char, at: CGPoint(x: x, y: y), size: fontSize, color: color)
                        }
                    }
                }

                // === Bottom border row ===
                let borderY = CGFloat(pitchRowCount) * rh + rh / 2
                for charCol in 0..<charCols {
                    let x = CGFloat(charCol) * cw + cw / 2
                    let stepIdx = charCol < charCols ? reverseMap[charCol] : nil
                    let ch: String
                    if charCol == 0 {
                        ch = "╚"
                    } else if charCol == charCols - 1 {
                        ch = "╝"
                    } else if stepIdx == nil {
                        // Separator position
                        ch = "╩"
                    } else {
                        ch = "═"
                    }
                    drawCharSeq(context, ch, at: CGPoint(x: x, y: borderY), size: fontSize, color: borderColor)
                }

                // === Velocity row ===
                let velY = CGFloat(pitchRowCount + 1) * rh + rh / 2
                for step in 0..<displayColumns {
                    let charCol = colMap[step]
                    let x = CGFloat(charCol) * cw + cw / 2
                    let enabled = step < cols
                    let vel = enabled ? (stepVelocities[step] ?? 0) : 0.0
                    let dimFactor: Double = enabled ? 1.0 : 0.25

                    let ch: String
                    if vel <= 0 { ch = " " }
                    else if vel < 0.15 { ch = "▁" }
                    else if vel < 0.30 { ch = "▂" }
                    else if vel < 0.45 { ch = "▃" }
                    else if vel < 0.60 { ch = "▄" }
                    else if vel < 0.75 { ch = "▅" }
                    else if vel < 0.90 { ch = "▆" }
                    else { ch = "▇" }

                    let velColor = CanopyColors.glowColor.opacity((vel > 0 ? 0.5 : 0.1) * dimFactor)
                    drawCharSeq(context, ch, at: CGPoint(x: x, y: velY), size: fontSize, color: velColor)
                }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard abs(value.translation.width) < 5,
                              abs(value.translation.height) < 5 else { return }
                        let loc = value.startLocation
                        let charCol = Int(loc.x / cw)
                        let rowIdx = Int(loc.y / rh)
                        guard rowIdx >= 0, rowIdx < pitches.count,
                              charCol >= 0, charCol < charCols else { return }
                        // Convert char column to step via reverse mapping
                        guard let step = reverseMap[charCol], step < cols else { return }
                        let pitch = pitches[rowIdx]
                        toggleNote(pitch: pitch, step: step)
                    }
            )
        }
    }

    // MARK: - ASCII Drawing Primitives

    private func drawCharSeq(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    private func drawCharSeqBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    // MARK: - Custom Controls

    /// Drag-to-adjust integer field: vertical drag changes value, tap for +/-1.
    private func dragValue(label: String, value: Int, range: ClosedRange<Int>, color: Color = CanopyColors.chromeText.opacity(0.7), onChange: @escaping (Int) -> Void) -> some View {
        let dragSensitivity: CGFloat = 8  // points per increment
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
                    // Tap cycles +1, wrapping
                    let next = value + 1 > range.upperBound ? range.lowerBound : value + 1
                    onChange(next)
                }
        }
    }

    /// Bloom-style horizontal slider matching SynthControlsPanel design.
    /// Accepts a Binding for local @State drag + onCommit/onDrag callbacks.
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

    // MARK: - Probability Slider

    private var probabilitySlider: some View {
        return HStack(spacing: 6 * cs) {
            Text("PROB")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            seqSlider(value: $localProbability, range: 0...1, onCommit: {
                commitGlobalProbability()
            }, onDrag: {
                // Push directly to audio engine during drag
                guard let nodeID = projectState.selectedNodeID else { return }
                AudioEngine.shared.setGlobalProbability(localProbability, nodeID: nodeID)
            })
                .frame(width: 100 * cs)

            Text("\(Int(localProbability * 100))%")
                .font(.system(size: 9 * cs, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 30 * cs, alignment: .trailing)
        }
    }

    // MARK: - Mutation Controls

    private var mutationControls: some View {
        let mutation = node?.sequence.mutation
        let range = mutation?.range ?? 1

        return VStack(alignment: .leading, spacing: 4 * cs) {
            Text("MUTATION")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            HStack(spacing: 6 * cs) {
                Text("Amt")
                    .font(.system(size: 9 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                seqSlider(value: $localMutationAmount, range: 0...1, onCommit: {
                    commitMutationAmount()
                }, onDrag: {
                    // Push directly to audio engine during drag
                    guard let nodeID = projectState.selectedNodeID else { return }
                    let key = resolveKey()
                    AudioEngine.shared.setMutation(
                        amount: localMutationAmount,
                        range: node?.sequence.mutation?.range ?? 1,
                        rootSemitone: key.root.semitone,
                        intervals: key.mode.intervals,
                        nodeID: nodeID
                    )
                })
                    .frame(width: 80 * cs)

                Text("\(Int(localMutationAmount * 100))%")
                    .font(.system(size: 9 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(width: 28 * cs, alignment: .trailing)
            }

            HStack(spacing: 6 * cs) {
                dragValue(label: "Rng", value: range, range: 1...7, color: CanopyColors.chromeText.opacity(0.4)) { setMutationRange($0) }

                Spacer()

                // Freeze / Reset buttons
                Button(action: { freezeMutation() }) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10 * cs))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Freeze mutations")

                Button(action: { resetMutation() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10 * cs))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Reset mutations")
            }
        }
    }

    // MARK: - Accumulator Controls

    private var accumulatorControls: some View {
        let acc = node?.sequence.accumulator
        let enabled = acc != nil
        let target = acc?.target ?? .pitch
        let mode = acc?.mode ?? .clamp

        return VStack(alignment: .leading, spacing: 4 * cs) {
            HStack(spacing: 6 * cs) {
                Text("ACCUMULATOR")
                    .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                Spacer()

                Button(action: { toggleAccumulator() }) {
                    Image(systemName: enabled ? "checkmark.square" : "square")
                        .font(.system(size: 10 * cs))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if enabled {
                // Target picker
                HStack(spacing: 4 * cs) {
                    ForEach(AccumulatorTarget.allCases, id: \.self) { t in
                        let isSelected = target == t
                        Button(action: { setAccumulatorTarget(t) }) {
                            Text(t.rawValue)
                                .font(.system(size: 9 * cs, design: .monospaced))
                                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                                .padding(.horizontal, 5 * cs)
                                .padding(.vertical, 2 * cs)
                                .background(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                HStack(spacing: 6 * cs) {
                    Text("Amt")
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    seqSlider(value: $localAccAmount, range: -12...12, onCommit: {
                        commitAccumulatorAmount()
                    }, onDrag: {
                        // Accumulator amount updates need reloadSequence on commit, not during drag
                    })
                        .frame(width: 80 * cs)
                    Text(String(format: "%.1f", localAccAmount))
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28 * cs, alignment: .trailing)
                }

                HStack(spacing: 6 * cs) {
                    Text("Lim")
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    seqSlider(value: $localAccLimit, range: 1...48, onCommit: {
                        commitAccumulatorLimit()
                    }, onDrag: {
                        // Accumulator limit updates need reloadSequence on commit, not during drag
                    })
                        .frame(width: 80 * cs)
                    Text(String(format: "%.0f", localAccLimit))
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28 * cs, alignment: .trailing)
                }

                // Mode picker
                HStack(spacing: 4 * cs) {
                    ForEach(AccumulatorMode.allCases, id: \.self) { m in
                        let isSelected = mode == m
                        Button(action: { setAccumulatorMode(m) }) {
                            Text(m.rawValue)
                                .font(.system(size: 9 * cs, design: .monospaced))
                                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                                .padding(.horizontal, 5 * cs)
                                .padding(.vertical, 2 * cs)
                                .background(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
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

    // MARK: - Arp Header Controls (replaces S/E/R when arp active)

    private var arpHeaderControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
        let octave = arpConfig.octaveRange

        return HStack(spacing: 6 * cs) {
            // Octave range
            dragValue(label: "Oct", value: octave, range: 1...4,
                      color: CanopyColors.glowColor.opacity(0.7)) { setArpOctave($0) }

            // Steps (still useful for sequence length)
            dragValue(label: "S", value: columns, range: 1...32) { changeLength(to: $0) }

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

    // MARK: - Arp Detail Controls (rate, gate)

    private var arpDetailControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
        let rates: [(ArpRate, String)] = [
            (.whole, "1"), (.half, "1/2"), (.quarter, "1/4"),
            (.eighth, "1/8"), (.sixteenth, "1/16"), (.thirtySecond, "1/32"),
        ]

        return VStack(alignment: .leading, spacing: 4 * cs) {
            // Rate picker
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

            // Gate slider
            HStack(spacing: 6 * cs) {
                Text("GATE")
                    .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                seqSlider(value: $localArpGate, range: 0.05...1.0, onCommit: {
                    commitArpGate()
                }, onDrag: {
                    guard let nodeID = projectState.selectedNodeID else { return }
                    // Push gate change to audio engine during drag
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

            // Pool preview
            if let sequence = node?.sequence, let config = sequence.arpConfig {
                Text(ArpNotePool.previewString(from: sequence, config: config))
                    .font(.system(size: 8 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Arp Toggle (in Advanced section)

    private var arpToggleControl: some View {
        let enabled = isArpActive

        return HStack(spacing: 6 * cs) {
            Text("ARPEGGIATOR")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Spacer()

            Button(action: { toggleArp() }) {
                Image(systemName: enabled ? "checkmark.square" : "square")
                    .font(.system(size: 10 * cs))
                    .foregroundColor(enabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Arp Actions

    private func setArpMode(_ mode: ArpMode) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.mode = mode
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    private func setArpRate(_ rate: ArpRate) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.rate = rate
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    private func setArpOctave(_ octave: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.octaveRange = octave
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    private func commitArpGate() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.gateLength = localArpGate
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    private func toggleArp() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.arpConfig != nil {
                node.sequence.arpConfig = nil
            } else {
                node.sequence.arpConfig = ArpConfig()
                // Auto-extend existing short-duration notes to span to end of sequence
                let len = node.sequence.lengthInBeats
                for i in 0..<node.sequence.notes.count {
                    let note = node.sequence.notes[i]
                    let remaining = len - note.startBeat
                    if note.duration < remaining {
                        node.sequence.notes[i].duration = remaining
                    }
                }
            }
        }
        if let node = projectState.findNode(id: nodeID) {
            if node.sequence.arpConfig != nil {
                projectState.rebuildArpPool(for: nodeID)
            } else {
                projectState.disableArp(for: nodeID)
            }
        }
        syncSeqFromModel()
        reloadSequence()
    }

    // MARK: - Commit Helpers (write to ProjectState once on drag end)

    private func commitGlobalProbability() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.globalProbability = localProbability
        }
        AudioEngine.shared.setGlobalProbability(localProbability, nodeID: nodeID)
    }

    private func commitMutationAmount() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.mutation == nil {
                node.sequence.mutation = MutationConfig(amount: localMutationAmount, range: 1)
            } else {
                node.sequence.mutation?.amount = localMutationAmount
            }
        }
        let key = resolveKey()
        AudioEngine.shared.setMutation(
            amount: localMutationAmount,
            range: node?.sequence.mutation?.range ?? 1,
            rootSemitone: key.root.semitone,
            intervals: key.mode.intervals,
            nodeID: nodeID
        )
    }

    private func commitAccumulatorAmount() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.amount = localAccAmount
        }
        reloadSequence()
    }

    private func commitAccumulatorLimit() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.limit = localAccLimit
        }
        reloadSequence()
    }

    // MARK: - Length Change

    private func changeLength(to newStepCount: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let sd = NoteSequence.stepDuration
        let newLengthBeats = Double(newStepCount) * sd
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { $0.startBeat >= newLengthBeats }
            // Clamp durations that extend past the new length
            for i in 0..<node.sequence.notes.count {
                let note = node.sequence.notes[i]
                let endBeat = note.startBeat + note.duration
                if endBeat > newLengthBeats {
                    node.sequence.notes[i].duration = newLengthBeats - note.startBeat
                }
            }
            node.sequence.lengthInBeats = newLengthBeats
        }
        reloadSequence()
    }

    // MARK: - Direction

    private func setDirection(_ dir: PlaybackDirection) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.playbackDirection = dir == .forward ? nil : dir
        }
        reloadSequence()
    }

    // MARK: - Euclidean

    private func applyEuclidean(pulses: Int, rotation: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let key = resolveKey()
        let config = EuclideanConfig(pulses: pulses, rotation: rotation)
        projectState.updateNode(id: nodeID) { node in
            SequenceFillService.applyEuclidean(
                sequence: &node.sequence,
                config: config,
                key: key,
                pitchRange: node.sequence.pitchRange
            )
        }
        reloadSequence()
    }

    // MARK: - Random Fill

    private func randomFill() {
        guard let nodeID = projectState.selectedNodeID else { return }
        let key = resolveKey()
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.euclidean != nil {
                // Re-randomize pitches on existing euclidean pattern
                SequenceFillService.randomScaleFill(
                    sequence: &node.sequence,
                    key: key,
                    pitchRange: node.sequence.pitchRange
                )
            } else {
                // Fill empty steps
                SequenceFillService.randomFill(
                    sequence: &node.sequence,
                    key: key,
                    pitchRange: node.sequence.pitchRange,
                    density: 0.5
                )
            }
        }
        reloadSequence()
    }

    // MARK: - Mutation (discrete controls — commit immediately)

    private func setMutationRange(_ range: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.mutation == nil {
                node.sequence.mutation = MutationConfig(amount: 0.1, range: range)
            } else {
                node.sequence.mutation?.range = range
            }
        }
        reloadSequence()
    }

    private func freezeMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        AudioEngine.shared.freezeMutation(nodeID: nodeID)
    }

    private func resetMutation() {
        guard let nodeID = projectState.selectedNodeID else { return }
        AudioEngine.shared.resetMutation(nodeID: nodeID)
    }

    // MARK: - Accumulator (discrete controls — commit immediately)

    private func toggleAccumulator() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.accumulator != nil {
                node.sequence.accumulator = nil
            } else {
                node.sequence.accumulator = AccumulatorConfig()
            }
        }
        syncSeqFromModel()
        reloadSequence()
    }

    private func setAccumulatorTarget(_ target: AccumulatorTarget) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.target = target
        }
        reloadSequence()
    }

    private func setAccumulatorMode(_ mode: AccumulatorMode) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.mode = mode
        }
        reloadSequence()
    }

    // MARK: - Span Drag Handles (overlay)

    /// Drag handles on the right edge of every note for extending duration.
    /// The span body itself (─ characters) is drawn in the ASCII Canvas.
    private func spanDragHandles(sequence: NoteSequence) -> some View {
        let sd = NoteSequence.stepDuration
        let pitches = visiblePitches
        let cw = gridCellW
        let rh = gridRowH
        let colMap = stepToCharCol
        let pps = pixelsPerStep

        var spansByPitch: [Int: [(startStep: Int, endStep: Int, noteIndex: Int)]] = [:]
        for (idx, note) in sequence.notes.enumerated() {
            let startStep = Int(round(note.startBeat / sd))
            let endStep: Int
            if let drag = spanDragState, drag.pitch == note.pitch && drag.startStep == startStep {
                endStep = drag.currentEndStep
            } else {
                endStep = max(startStep + 1, Int(round((note.startBeat + note.duration) / sd)))
            }
            spansByPitch[note.pitch, default: []].append((startStep: startStep, endStep: endStep, noteIndex: idx))
        }

        let spanColor = isArpActive
            ? Color(red: 0.2, green: 0.7, blue: 0.8)
            : CanopyColors.gridCellActive

        return ZStack(alignment: .topLeading) {
            ForEach(pitches, id: \.self) { pitch in
                let rowIndex = pitches.firstIndex(of: pitch) ?? 0
                let y = CGFloat(rowIndex) * rh

                if let spans = spansByPitch[pitch] {
                    ForEach(spans, id: \.startStep) { span in
                        let visibleEnd = min(span.endStep, columns)
                        if visibleEnd > span.startStep && span.startStep < columns {
                            // Position handle at the right edge of the last step in the span
                            let lastStepCharCol = colMap[min(visibleEnd - 1, displayColumns - 1)]
                            let handleX = CGFloat(lastStepCharCol) * cw + cw * 0.5

                            Rectangle()
                                .fill(spanColor.opacity(0.5))
                                .frame(width: max(4 * cs, cw * 0.6), height: rh * 0.7)
                                .clipShape(RoundedRectangle(cornerRadius: 1 * cs))
                                .offset(x: handleX - max(4 * cs, cw * 0.6) / 2, y: y + rh * 0.15)
                                .gesture(
                                    DragGesture(minimumDistance: 2)
                                        .onChanged { drag in
                                            // Use pixelsPerStep (accounts for separator columns) for 1:1 mouse tracking
                                            let dragSteps = Int(round(drag.translation.width / pps))
                                            let newEnd = max(span.startStep + 1, min(columns, span.endStep + dragSteps))
                                            spanDragState = (pitch: pitch, startStep: span.startStep, currentEndStep: newEnd)
                                        }
                                        .onEnded { _ in
                                            if let drag = spanDragState {
                                                commitSpanDrag(pitch: drag.pitch, startStep: drag.startStep, newEndStep: drag.currentEndStep)
                                            }
                                            spanDragState = nil
                                        }
                                )
                        }
                    }
                }
            }
        }
    }

    /// Commit a span drag: update the NoteEvent duration to match the new end step.
    private func commitSpanDrag(pitch: Int, startStep: Int, newEndStep: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let sd = NoteSequence.stepDuration

        projectState.updateNode(id: nodeID) { node in
            if let idx = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && Int(round($0.startBeat / sd)) == startStep
            }) {
                let newDuration = Double(newEndStep - startStep) * sd
                node.sequence.notes[idx].duration = max(sd, newDuration)
            }
        }
        reloadSequence()
    }

    // MARK: - Note Logic

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let sd = NoteSequence.stepDuration
        let stepBeat = Double(step) * sd

        projectState.updateNode(id: nodeID) { node in
            if let existingIndex = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && Int(round($0.startBeat / sd)) == step
            }) {
                node.sequence.notes.remove(at: existingIndex)
            } else {
                // In arp mode, extend duration to end of sequence
                let dur = node.sequence.arpConfig != nil
                    ? node.sequence.lengthInBeats - stepBeat
                    : NoteSequence.stepDuration
                let event = NoteEvent(
                    pitch: pitch,
                    velocity: 0.8,
                    startBeat: stepBeat,
                    duration: dur
                )
                node.sequence.notes.append(event)
            }
            // Clear euclidean config when manually editing
            node.sequence.euclidean = nil
        }

        reloadSequence()
    }

    private func reloadSequence() {
        guard let node = projectState.selectedNode,
              let nodeID = projectState.selectedNodeID else { return }
        let seq = node.sequence
        let events = seq.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration,
                probability: event.probability,
                ratchetCount: event.ratchetCount
            )
        }
        let key = resolveKey()
        let mutation = seq.mutation
        AudioEngine.shared.loadSequence(
            events, lengthInBeats: seq.lengthInBeats, nodeID: nodeID,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )

        // Rebuild arp pool if arp is active
        if seq.arpConfig != nil {
            projectState.rebuildArpPool(for: nodeID)
        }
    }

    // MARK: - Helpers

    private func resolveKey() -> MusicalKey {
        guard let node = projectState.selectedNode else {
            return projectState.project.globalKey
        }
        if let override = node.scaleOverride { return override }
        if let tree = projectState.project.trees.first, let treeScale = tree.scale {
            return treeScale
        }
        return projectState.project.globalKey
    }
}
