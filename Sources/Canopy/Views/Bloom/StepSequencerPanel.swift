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
    @State private var spanDragState: SpanDragState?

    private var node: Node? {
        projectState.selectedNode
    }

    private var scaleAwareEnabled: Bool {
        projectState.project.scaleAwareEnabled
    }

    private var isArpActive: Bool {
        node?.sequence.arpConfig != nil
    }

    private var visiblePitches: [Int] {
        SequencerGridCore.visiblePitches(
            baseNote: baseNote, rowCount: rows,
            key: resolveKey(), scaleAware: scaleAwareEnabled
        )
    }

    /// Active step count from the sequence length.
    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    /// Always render 32 columns so grid size never changes.
    private var displayColumns: Int { 32 }

    // MARK: - ASCII Grid Geometry

    private var gridCharCols: Int { SequencerGridCore.gridCharCols(for: displayColumns) }

    /// Font size derived from panel width so the grid fills available space.
    private var gridFontSize: CGFloat {
        let available = (panelWidth - 68) * cs
        let size = available / (CGFloat(gridCharCols) * 0.78)
        return max(9, size)
    }
    private var gridCellW: CGFloat { SequencerGridCore.cellWidth(fontSize: gridFontSize) }
    private var gridRowH: CGFloat { SequencerGridCore.cellHeight(fontSize: gridFontSize) }

    /// Derive cellSize/cellSpacing from ASCII geometry for span overlay compatibility.
    private var cellSize: CGFloat { gridCellW }
    private var cellSpacing: CGFloat { 0 }

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

                    // ASCII grid (tap to toggle, drag to extend)
                    asciiGridCanvas(sequence: node.sequence, nodeID: node.id)
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
                    SequencerGridCore.drawChar(context, "█", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.glowColor.opacity(0.6))
                } else {
                    SequencerGridCore.drawChar(context, "│", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.chromeText.opacity(0.15))
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

    // MARK: - ASCII Grid Canvas

    private func asciiGridCanvas(sequence: NoteSequence, nodeID: UUID) -> some View {
        let pitches = visiblePitches
        let cols = columns
        let fontSize = gridFontSize
        let cw = gridCellW
        let rh = gridRowH
        let charCols = gridCharCols
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let lookup = SequencerGridCore.buildNoteLookup(notes: sequence.notes)
        let continuations = SequencerGridCore.buildSpanContinuationSet(notes: sequence.notes, spanDragState: spanDragState)
        let stepVelocities = SequencerGridCore.buildStepVelocities(notes: sequence.notes)

        let rc = GridRenderContext(
            pitches: pitches,
            activeColumns: cols,
            displayColumns: displayColumns,
            fontSize: fontSize,
            isArpActive: isArpActive,
            hasEuclidean: sequence.euclidean != nil,
            arpPitches: isArpActive ? Set(sequence.notes.map { $0.pitch }) : [],
            lookup: lookup,
            continuations: continuations,
            stepVelocities: stepVelocities,
            playheadStep: -1,
            pulse: 0,
            spanDragState: spanDragState,
            notes: sequence.notes,
            showVelocityRow: true
        )
        let canvasSize = SequencerGridCore.canvasSize(for: rc)

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let engine = AudioEngine.shared
            let isPlaying = engine.isPlaying(for: nodeID)
            let currentBeat = engine.currentBeat(for: nodeID)
            let beatFraction = currentBeat / max(sequence.lengthInBeats, 1)
            let playheadStep = isPlaying ? Int(beatFraction * Double(cols)) % cols : -1
            let pulse: CGFloat = 0.7 + 0.3 * CGFloat(sin(time * 6))

            Canvas { context, size in
                var frameRC = rc
                frameRC.playheadStep = playheadStep
                frameRC.pulse = pulse
                SequencerGridCore.drawGrid(context, rc: frameRC)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = abs(value.translation.width)
                        let dy = abs(value.translation.height)
                        // Only enter span drag if horizontal drag exceeds threshold
                        guard dx > 5 && dx > dy else { return }

                        // Determine which note the drag started on
                        let startCharCol = Int(value.startLocation.x / cw)
                        let startRowIdx = Int(value.startLocation.y / rh)
                        guard startRowIdx >= 0, startRowIdx < pitches.count,
                              startCharCol >= 0, startCharCol < charCols else { return }
                        guard let startStep = reverseMap[startCharCol], startStep < cols else { return }
                        let pitch = pitches[startRowIdx]

                        // Only drag-to-extend if there's a note at the start position
                        let noteKey = pitch &* 1000 &+ startStep
                        guard lookup[noteKey] != nil else { return }

                        // Compute target end step from absolute mouse X position
                        let currentCharCol = max(0, min(charCols - 1, Int(value.location.x / cw)))
                        let targetStep = SequencerGridCore.nearestStep(forCharCol: currentCharCol, reverseMap: reverseMap, maxStep: cols)
                        let newEnd = max(startStep + 1, min(cols, targetStep + 1))
                        spanDragState = SpanDragState(pitch: pitch, startStep: startStep, currentEndStep: newEnd)
                    }
                    .onEnded { value in
                        if let drag = spanDragState {
                            commitSpanDrag(pitch: drag.pitch, startStep: drag.startStep, newEndStep: drag.currentEndStep)
                            spanDragState = nil
                        } else {
                            // Tap: toggle note (only if movement was minimal)
                            guard abs(value.translation.width) < 5,
                                  abs(value.translation.height) < 5 else { return }
                            let loc = value.startLocation
                            let charCol = Int(loc.x / cw)
                            let rowIdx = Int(loc.y / rh)
                            guard rowIdx >= 0, rowIdx < pitches.count,
                                  charCol >= 0, charCol < charCols else { return }
                            guard let step = reverseMap[charCol], step < cols else { return }
                            let pitch = pitches[rowIdx]
                            toggleNote(pitch: pitch, step: step)
                        }
                    }
            )
        }
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

    // MARK: - Action Wrappers (delegate to SequencerActions)

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.toggleNote(projectState: projectState, nodeID: nodeID, pitch: pitch, step: step)
    }

    private func commitSpanDrag(pitch: Int, startStep: Int, newEndStep: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitSpanDrag(projectState: projectState, nodeID: nodeID, pitch: pitch, startStep: startStep, newEndStep: newEndStep)
    }

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

    // MARK: - Helpers

    private func resolveKey() -> MusicalKey {
        guard let nodeID = projectState.selectedNodeID else {
            return projectState.project.globalKey
        }
        return SequencerActions.resolveKey(projectState: projectState, nodeID: nodeID)
    }
}
