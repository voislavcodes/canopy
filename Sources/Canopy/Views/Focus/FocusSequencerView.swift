import SwiftUI

/// Focus-mode sequencer: dedicated two-column editing view with larger grid,
/// always-visible sidebar controls, and support for up to 64 steps.
/// Uses SequencerGridCore for shared grid rendering and SequencerActions for model mutations.
struct FocusSequencerView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    /// MIDI range for the touch strip (C1 to C7)
    private let midiLow = 24
    private let midiHigh = 96
    private let defaultRows = 8

    @State private var baseNote: Int = 55  // G3
    @State private var selectedStepCount: Int = 32
    @State private var spanDragState: SpanDragState?

    // Lane visibility toggles
    @State private var showVelocityLane = true
    @State private var showProbabilityLane = true
    @State private var microTimingEnabled = false

    // Multi-note selection (Phase E)
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectionRect: CGRect?
    @State private var clipboard: [NoteEvent] = []

    /// Binding from FocusView to communicate selection state for key handling.
    var sequencerHasSelection: Binding<Bool>?

    // MARK: - Local drag state for continuous sliders

    @State private var localProbability: Double = 1.0
    @State private var localMutationAmount: Double = 0.0
    @State private var localAccAmount: Double = 1.0
    @State private var localAccLimit: Double = 12.0
    @State private var localArpGate: Double = 0.5

    private var node: Node? {
        projectState.selectedNode
    }

    private var scaleAwareEnabled: Bool {
        projectState.project.scaleAwareEnabled
    }

    private var isArpActive: Bool {
        node?.sequence.arpConfig != nil
    }

    /// Active step count from the sequence length.
    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    /// Always show 64 columns — inactive steps are dimmed.
    private var displayColumns: Int { 64 }

    var body: some View {
        VStack(spacing: 0) {
            // Header row — full width
            headerRow
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

            GeometryReader { geo in
                mainContent(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .onAppear { syncOnAppear() }
        .onChange(of: projectState.selectedNodeID) { _ in syncOnAppear() }
        .onReceive(NotificationCenter.default.publisher(for: .focusClearSelection)) { _ in
            _ = clearSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTransposeUp)) { _ in
            transposeSelection(semitones: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusTransposeDown)) { _ in
            transposeSelection(semitones: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusMoveLeft)) { _ in
            moveSelection(steps: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusMoveRight)) { _ in
            moveSelection(steps: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDeleteSelection)) { _ in
            deleteSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusCopySelection)) { _ in
            copySelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPasteSelection)) { _ in
            pasteClipboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDuplicateSelection)) { _ in
            duplicateSelection()
        }
    }

    // MARK: - Sync

    private func syncOnAppear() {
        syncSeqFromModel()
        // Snap selectedStepCount to node's current length
        let beats = node?.sequence.lengthInBeats ?? 8.0
        let steps = Int(round(beats / NoteSequence.stepDuration))
        let validCounts = [4, 8, 16, 32, 64]
        selectedStepCount = validCounts.min(by: { abs($0 - steps) < abs($1 - steps) }) ?? 32
    }

    private func syncSeqFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
        localAccAmount = node.sequence.accumulator?.amount ?? 1.0
        localAccLimit = node.sequence.accumulator?.limit ?? 12.0
        localArpGate = node.sequence.arpConfig?.gateLength ?? 0.5
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(isArpActive ? "ARP" : "SEQUENCE")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isArpActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isArpActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
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

            // Step count selector
            stepCountSelector
        }
    }

    // MARK: - Step Count Selector

    private var stepCountSelector: some View {
        HStack(spacing: 3) {
            ForEach([4, 8, 16, 32, 64], id: \.self) { count in
                let isActive = selectedStepCount == count
                Button(action: {
                    selectedStepCount = count
                    changeLength(to: count)
                }) {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 28, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Main Content (full width, no sidebar)

    private func mainContent(width: CGFloat, height: CGFloat) -> some View {
        let pitchRows = 12 // fixed compact row count for bigger cells
        let pitches = SequencerGridCore.visiblePitches(
            baseNote: baseNote, rowCount: pitchRows,
            key: resolveKey(), scaleAware: scaleAwareEnabled
        )
        let labelWidth: CGFloat = 32
        let stripWidth: CGFloat = 14
        let gridWidth = width - labelWidth - stripWidth - 16 // padding
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let fontSize = max(6, min(24, gridWidth / (CGFloat(charCols) * 0.78)))
        let laneInsetX = stripWidth + labelWidth + 16 // match grid's left edge

        return ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Spacer(minLength: 12)

                if let node {
                    HStack(alignment: .top, spacing: 4) {
                        focusTouchStrip(pitches: pitches, fontSize: fontSize)
                        focusNoteLabels(pitches: pitches, fontSize: fontSize)
                        focusGridCanvas(sequence: node.sequence, nodeID: node.id, pitches: pitches, fontSize: fontSize)
                    }
                    .padding(.horizontal, 6)

                    // Velocity lane
                    if showVelocityLane {
                        velocityLane(sequence: node.sequence, nodeID: node.id, fontSize: fontSize)
                            .padding(.leading, laneInsetX)
                            .padding(.trailing, 6)
                    }

                    // Probability lane
                    if showProbabilityLane {
                        probabilityLane(sequence: node.sequence, nodeID: node.id, fontSize: fontSize)
                            .padding(.leading, laneInsetX)
                            .padding(.trailing, 6)
                    }

                    // Micro-timing lane (groove overview)
                    if microTimingEnabled {
                        microTimingLane(sequence: node.sequence, fontSize: fontSize)
                            .padding(.leading, laneInsetX)
                            .padding(.trailing, 6)
                    }
                }

                Spacer(minLength: 12)
            }

            // Bottom-right: compact advanced controls + lane toggles
            VStack(alignment: .trailing, spacing: 6) {
                compactAdvancedControls
                laneToggleBar
            }
            .padding(10)
        }
    }

    // MARK: - Lane Toggle Bar

    private var laneToggleBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                laneToggleButton(label: "VEL", isActive: showVelocityLane) {
                    showVelocityLane.toggle()
                }
                laneToggleButton(label: "PROB", isActive: showProbabilityLane) {
                    showProbabilityLane.toggle()
                }
                laneToggleButton(label: "μT", isActive: microTimingEnabled) {
                    microTimingEnabled.toggle()
                }
            }
        }
    }

    private func laneToggleButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isActive ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Touch Strip

    private func focusTouchStrip(pitches: [Int], fontSize: CGFloat) -> some View {
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let pitchCount = pitches.count
        let stripHeight = CGFloat(pitchCount) * rh
        let totalRange = midiHigh - midiLow - defaultRows
        let normalizedPos = totalRange > 0
            ? CGFloat(baseNote - midiLow) / CGFloat(totalRange)
            : 0.5
        let thumbRow = max(0, min(pitchCount - 1, Int(round(Double(pitchCount - 1) * (1.0 - normalizedPos)))))

        return Canvas { context, size in
            for row in 0..<pitchCount {
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
                    let totalRange = midiHigh - midiLow - defaultRows
                    baseNote = midiLow + Int(round(clamped * CGFloat(totalRange)))
                    baseNote = max(midiLow, min(midiHigh - defaultRows, baseNote))
                }
        )
    }

    // MARK: - Note Labels

    private func focusNoteLabels(pitches: [Int], fontSize: CGFloat) -> some View {
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let gridHeight = CGFloat(pitches.count) * rh
        let rootSemitone = resolveKey().root.semitone
        return VStack(spacing: 0) {
            ForEach(pitches, id: \.self) { pitch in
                let name = MIDIUtilities.noteName(forNote: pitch)
                let isRoot = ((pitch % 12) - rootSemitone + 12) % 12 == 0
                let isC = pitch % 12 == 0
                let highlight = scaleAwareEnabled ? isRoot : isC
                Text(name)
                    .font(.system(size: max(7, fontSize * 0.6), weight: highlight ? .bold : .regular, design: .monospaced))
                    .foregroundColor(highlight ? CanopyColors.glowColor.opacity(0.7) : CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 28, height: rh, alignment: .trailing)
            }
        }
        .frame(height: gridHeight)
    }

    // MARK: - Grid Canvas (shared core)

    private func focusGridCanvas(sequence: NoteSequence, nodeID: UUID, pitches: [Int], fontSize: CGFloat) -> some View {
        let cols = columns
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let lookup = SequencerGridCore.buildNoteLookup(notes: sequence.notes)
        let continuations = SequencerGridCore.buildSpanContinuationSet(notes: sequence.notes, spanDragState: spanDragState)
        let stepVelocities = SequencerGridCore.buildStepVelocities(notes: sequence.notes)
        let microOffsets = sequence.microTimingOffsets
        let isMicroTimingOn = microTimingEnabled

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

                // Selection highlight overlay
                if !selectedNoteIDs.isEmpty {
                    let sd = NoteSequence.stepDuration
                    for note in sequence.notes where selectedNoteIDs.contains(note.id) {
                        let step = Int(round(note.startBeat / sd))
                        guard step < cols else { continue }
                        guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }
                        let charCol = colMap[min(step, displayColumns - 1)]
                        let x = CGFloat(charCol) * cw
                        let y = CGFloat(rowIdx) * rh
                        let highlightRect = CGRect(x: x, y: y, width: cw, height: rh)
                        context.stroke(
                            Path(highlightRect),
                            with: .color(Color.white.opacity(0.7)),
                            lineWidth: 1.5
                        )
                    }
                }

                // Selection rectangle overlay
                if let rect = selectionRect {
                    let dashPattern: [CGFloat] = [3, 3]
                    context.stroke(
                        Path(rect),
                        with: .color(CanopyColors.glowColor.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 1, dash: dashPattern)
                    )
                    context.fill(
                        Path(rect),
                        with: .color(CanopyColors.glowColor.opacity(0.08))
                    )
                }

                // Micro-timing overlay: draw chevrons on notes with non-zero offsets
                if isMicroTimingOn, let offsets = microOffsets {
                    let sd = NoteSequence.stepDuration
                    for note in sequence.notes {
                        let step = Int(round(note.startBeat / sd))
                        guard step < offsets.count, step < cols else { continue }
                        let offset = offsets[step]
                        guard abs(offset) > 0.5 else { continue }
                        guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }

                        let charCol = colMap[min(step, displayColumns - 1)]
                        let x = CGFloat(charCol) * cw + cw / 2
                        let y = CGFloat(rowIdx) * rh + rh / 2

                        // Visual shift proportional to offset (max ±cw/3)
                        let shiftX = CGFloat(offset / 48.0) * (cw * 0.33)

                        // Chevron + offset number
                        let chevron = offset < 0 ? "\u{2039}\u{2039}" : "\u{203A}\u{203A}"
                        let label = "\(Int(abs(offset)))"
                        let microFS = max(5, fontSize * 0.5)
                        let microColor = CanopyColors.glowColor.opacity(0.85)

                        context.draw(
                            Text(chevron).font(.system(size: microFS, weight: .bold, design: .monospaced)).foregroundColor(microColor),
                            at: CGPoint(x: x + shiftX, y: y - rh * 0.22), anchor: .center
                        )
                        context.draw(
                            Text(label).font(.system(size: max(5, microFS * 0.85), design: .monospaced)).foregroundColor(microColor.opacity(0.7)),
                            at: CGPoint(x: x + shiftX, y: y + rh * 0.22), anchor: .center
                        )
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                // Double-click: reset micro-timing offset if μT is on
                if isMicroTimingOn {
                    let charCol = Int(location.x / cw)
                    let rowIdx = Int(location.y / rh)
                    guard rowIdx >= 0, rowIdx < pitches.count,
                          charCol >= 0, charCol < charCols else { return }
                    guard let step = reverseMap[charCol], step < cols else { return }
                    resetMicroTimingOffset(step: step, nodeID: nodeID)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = abs(value.translation.width)
                        let dy = abs(value.translation.height)
                        let isDrag = max(dx, dy) > 5

                        let startCharCol = Int(value.startLocation.x / cw)
                        let startRowIdx = Int(value.startLocation.y / rh)
                        guard startRowIdx >= 0, startRowIdx < pitches.count,
                              startCharCol >= 0, startCharCol < charCols else { return }
                        guard let startStep = reverseMap[startCharCol], startStep < cols else { return }
                        let pitch = pitches[startRowIdx]

                        let noteKey = pitch &* 1000 &+ startStep
                        let hasNote = lookup[noteKey] != nil

                        guard isDrag else { return }

                        if hasNote {
                            if isMicroTimingOn {
                                let pixelOffset = value.translation.width
                                let tickOffset = Double(pixelOffset / cw) * 48.0
                                let clamped = max(-48, min(48, tickOffset))
                                setMicroTimingOffset(step: startStep, offset: clamped, nodeID: nodeID)
                            } else if dx > dy {
                                // Drag on note: extend span
                                let currentCharCol = max(0, min(charCols - 1, Int(value.location.x / cw)))
                                let targetStep = SequencerGridCore.nearestStep(forCharCol: currentCharCol, reverseMap: reverseMap, maxStep: cols)
                                let newEnd = max(startStep + 1, min(cols, targetStep + 1))
                                spanDragState = SpanDragState(pitch: pitch, startStep: startStep, currentEndStep: newEnd)
                            }
                        } else {
                            // Drag on empty space: draw selection rectangle
                            let minX = min(value.startLocation.x, value.location.x)
                            let minY = min(value.startLocation.y, value.location.y)
                            let maxX = max(value.startLocation.x, value.location.x)
                            let maxY = max(value.startLocation.y, value.location.y)
                            selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                        }
                    }
                    .onEnded { value in
                        if let drag = spanDragState {
                            commitSpanDrag(pitch: drag.pitch, startStep: drag.startStep, newEndStep: drag.currentEndStep)
                            spanDragState = nil
                        } else if let rect = selectionRect {
                            // Selection rectangle completed — find notes within
                            resolveSelection(rect: rect, pitches: pitches, cw: cw, rh: rh,
                                             colMap: colMap, cols: cols, notes: sequence.notes)
                            selectionRect = nil
                        } else if !isMicroTimingOn {
                            guard abs(value.translation.width) < 5,
                                  abs(value.translation.height) < 5 else { return }
                            let loc = value.startLocation
                            let charCol = Int(loc.x / cw)
                            let rowIdx = Int(loc.y / rh)
                            guard rowIdx >= 0, rowIdx < pitches.count,
                                  charCol >= 0, charCol < charCols else { return }
                            guard let step = reverseMap[charCol], step < cols else { return }
                            let pitch = pitches[rowIdx]

                            // Check if shift is held for selection toggle
                            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                            let noteKey = pitch &* 1000 &+ step
                            if shiftHeld, let noteEvent = lookup[noteKey] {
                                // Shift+click: toggle selection
                                if selectedNoteIDs.contains(noteEvent.id) {
                                    selectedNoteIDs.remove(noteEvent.id)
                                } else {
                                    selectedNoteIDs.insert(noteEvent.id)
                                }
                                updateSelectionBinding()
                            } else if !selectedNoteIDs.isEmpty {
                                // If selection active, click deselects
                                selectedNoteIDs.removeAll()
                                updateSelectionBinding()
                            } else {
                                // Normal click: toggle note
                                toggleNote(pitch: pitch, step: step)
                            }
                        }
                    }
            )
        }
    }

    /// Set micro-timing offset for a step, lazily initializing the array.
    private func setMicroTimingOffset(step: Int, offset: Double, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            let stepCount = max(1, Int(round(node.sequence.lengthInBeats / NoteSequence.stepDuration)))
            if node.sequence.microTimingOffsets == nil {
                node.sequence.microTimingOffsets = Array(repeating: 0.0, count: stepCount)
            }
            while node.sequence.microTimingOffsets!.count < stepCount {
                node.sequence.microTimingOffsets!.append(0.0)
            }
            if step < node.sequence.microTimingOffsets!.count {
                node.sequence.microTimingOffsets![step] = max(-48, min(48, offset))
            }
        }
    }

    /// Reset micro-timing offset for a step to zero.
    private func resetMicroTimingOffset(step: Int, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            guard node.sequence.microTimingOffsets != nil,
                  step < node.sequence.microTimingOffsets!.count else { return }
            node.sequence.microTimingOffsets![step] = 0.0
        }
    }

    // MARK: - Selection Helpers

    /// Resolve which notes fall within a selection rectangle.
    private func resolveSelection(rect: CGRect, pitches: [Int], cw: CGFloat, rh: CGFloat,
                                  colMap: [Int], cols: Int, notes: [NoteEvent]) {
        let sd = NoteSequence.stepDuration
        var newSelection = Set<UUID>()

        for note in notes {
            let step = Int(round(note.startBeat / sd))
            guard step < cols else { continue }
            guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }

            let charCol = colMap[min(step, displayColumns - 1)]
            let noteX = CGFloat(charCol) * cw + cw / 2
            let noteY = CGFloat(rowIdx) * rh + rh / 2

            if rect.contains(CGPoint(x: noteX, y: noteY)) {
                newSelection.insert(note.id)
            }
        }

        selectedNoteIDs = newSelection
        updateSelectionBinding()
    }

    /// Update the parent binding to communicate selection state.
    private func updateSelectionBinding() {
        sequencerHasSelection?.wrappedValue = !selectedNoteIDs.isEmpty
    }

    /// Deselect all notes. Returns true if there was a selection to clear.
    func clearSelection() -> Bool {
        guard !selectedNoteIDs.isEmpty else { return false }
        selectedNoteIDs.removeAll()
        updateSelectionBinding()
        return true
    }

    // MARK: - Selection Transforms

    /// Transpose selected notes by a number of semitones.
    func transposeSelection(semitones: Int) {
        guard let nodeID = projectState.selectedNodeID, !selectedNoteIDs.isEmpty else { return }
        projectState.updateNode(id: nodeID) { node in
            for i in 0..<node.sequence.notes.count {
                if selectedNoteIDs.contains(node.sequence.notes[i].id) {
                    let newPitch = max(0, min(127, node.sequence.notes[i].pitch + semitones))
                    node.sequence.notes[i].pitch = newPitch
                }
            }
        }
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Move selected notes by a number of steps.
    func moveSelection(steps: Int) {
        guard let nodeID = projectState.selectedNodeID, !selectedNoteIDs.isEmpty else { return }
        let sd = NoteSequence.stepDuration
        let lengthBeats = node?.sequence.lengthInBeats ?? 4.0
        projectState.updateNode(id: nodeID) { node in
            for i in 0..<node.sequence.notes.count {
                if selectedNoteIDs.contains(node.sequence.notes[i].id) {
                    let newBeat = node.sequence.notes[i].startBeat + Double(steps) * sd
                    if newBeat >= 0 && newBeat < lengthBeats {
                        node.sequence.notes[i].startBeat = newBeat
                    }
                }
            }
        }
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Delete selected notes.
    func deleteSelection() {
        guard let nodeID = projectState.selectedNodeID, !selectedNoteIDs.isEmpty else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { selectedNoteIDs.contains($0.id) }
        }
        selectedNoteIDs.removeAll()
        updateSelectionBinding()
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Copy selected notes to clipboard.
    func copySelection() {
        guard let node else { return }
        clipboard = node.sequence.notes.filter { selectedNoteIDs.contains($0.id) }
    }

    /// Paste clipboard notes at the earliest step position.
    func pasteClipboard() {
        guard let nodeID = projectState.selectedNodeID, !clipboard.isEmpty else { return }
        let sd = NoteSequence.stepDuration
        // Find the earliest startBeat in clipboard to use as offset origin
        let minBeat = clipboard.map(\.startBeat).min() ?? 0
        // Find insertion point: after the last selected note, or at beat 0
        let insertBeat: Double
        if let node, !selectedNoteIDs.isEmpty {
            let maxSelectedBeat = node.sequence.notes
                .filter { selectedNoteIDs.contains($0.id) }
                .map { $0.startBeat + $0.duration }
                .max() ?? 0
            insertBeat = maxSelectedBeat
        } else {
            insertBeat = 0
        }

        var newIDs = Set<UUID>()
        projectState.updateNode(id: nodeID) { node in
            let lengthBeats = node.sequence.lengthInBeats
            for event in clipboard {
                let newBeat = insertBeat + (event.startBeat - minBeat)
                guard newBeat >= 0, newBeat < lengthBeats else { continue }
                var newEvent = event
                newEvent.id = UUID()
                newEvent.startBeat = newBeat
                let maxDuration = lengthBeats - newBeat
                newEvent.duration = min(newEvent.duration, maxDuration)
                node.sequence.notes.append(newEvent)
                newIDs.insert(newEvent.id)
            }
        }
        selectedNoteIDs = newIDs
        updateSelectionBinding()
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Duplicate selection (copy + paste immediately after).
    func duplicateSelection() {
        copySelection()
        pasteClipboard()
    }

    // MARK: - Velocity Lane

    private func velocityLane(sequence: NoteSequence, nodeID: UUID, fontSize: CGFloat) -> some View {
        let cols = columns
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let laneHeight: CGFloat = 44
        let canvasWidth = CGFloat(charCols) * cw

        // Build per-step velocity map (average when chords exist)
        var stepVelSum = [Int: (total: Double, count: Int)]()
        for event in sequence.notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            if let existing = stepVelSum[step] {
                stepVelSum[step] = (existing.total + event.velocity, existing.count + 1)
            } else {
                stepVelSum[step] = (event.velocity, 1)
            }
        }

        return VStack(spacing: 0) {
            // Separator line
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(height: 1)

            HStack(spacing: 0) {
                Text("VEL")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 24, alignment: .trailing)
                    .padding(.trailing, 2)

                Canvas { context, size in
                    for step in 0..<displayColumns {
                        guard step < cols else { continue }
                        guard let velData = stepVelSum[step] else { continue }
                        let avgVel = velData.total / Double(velData.count)

                        let charCol = colMap[step]
                        let x = CGFloat(charCol) * cw + cw / 2
                        let barHeight = CGFloat(avgVel) * (laneHeight - 4)
                        let barY = laneHeight - barHeight

                        let barRect = CGRect(x: x - cw * 0.35, y: barY, width: cw * 0.7, height: barHeight)
                        context.fill(
                            Path(barRect),
                            with: .color(CanopyColors.glowColor.opacity(0.3 + avgVel * 0.5))
                        )
                    }
                }
                .frame(width: canvasWidth, height: laneHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let charCol = Int(value.location.x / cw)
                            guard charCol >= 0, charCol < charCols else { return }
                            guard let step = reverseMap[charCol], step < cols else { return }
                            let velocity = max(0.05, min(1.0, 1.0 - (value.location.y / laneHeight)))
                            setVelocityForStep(step: step, velocity: velocity, nodeID: nodeID)
                        }
                )
            }
        }
    }

    /// Set velocity for all notes at a given step, adjusting proportionally for chords.
    private func setVelocityForStep(step: Int, velocity: Double, nodeID: UUID) {
        let sd = NoteSequence.stepDuration
        projectState.updateNode(id: nodeID) { node in
            for i in 0..<node.sequence.notes.count {
                let noteStep = Int(round(node.sequence.notes[i].startBeat / sd))
                if noteStep == step {
                    node.sequence.notes[i].velocity = velocity
                }
            }
        }
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    // MARK: - Probability Lane

    private func probabilityLane(sequence: NoteSequence, nodeID: UUID, fontSize: CGFloat) -> some View {
        let cols = columns
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let laneHeight: CGFloat = 44
        let canvasWidth = CGFloat(charCols) * cw
        let perStep = sequence.perStepProbability

        return VStack(spacing: 0) {
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(height: 1)

            HStack(spacing: 0) {
                Text("PROB")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.3))
                    .frame(width: 24, alignment: .trailing)
                    .padding(.trailing, 2)

                Canvas { context, size in
                    for step in 0..<displayColumns {
                        guard step < cols else { continue }

                        let prob: Double
                        if let arr = perStep, step < arr.count {
                            prob = arr[step]
                        } else {
                            prob = 1.0
                        }

                        let charCol = colMap[step]
                        let x = CGFloat(charCol) * cw + cw / 2
                        let barHeight = CGFloat(prob) * (laneHeight - 4)
                        let barY = laneHeight - barHeight

                        let barRect = CGRect(x: x - cw * 0.35, y: barY, width: cw * 0.7, height: barHeight)
                        context.fill(
                            Path(barRect),
                            with: .color(CanopyColors.glowColor.opacity(0.2 + prob * 0.35))
                        )
                    }
                }
                .frame(width: canvasWidth, height: laneHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let charCol = Int(value.location.x / cw)
                            guard charCol >= 0, charCol < charCols else { return }
                            guard let step = reverseMap[charCol], step < cols else { return }
                            let prob = max(0.0, min(1.0, 1.0 - (value.location.y / laneHeight)))
                            setPerStepProbability(step: step, probability: prob, nodeID: nodeID)
                        }
                )
            }
        }
    }

    /// Set per-step probability, lazily initializing the array on first drag.
    private func setPerStepProbability(step: Int, probability: Double, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            let stepCount = max(1, Int(round(node.sequence.lengthInBeats / NoteSequence.stepDuration)))
            if node.sequence.perStepProbability == nil {
                node.sequence.perStepProbability = Array(repeating: 1.0, count: stepCount)
            }
            // Ensure array is large enough
            while node.sequence.perStepProbability!.count < stepCount {
                node.sequence.perStepProbability!.append(1.0)
            }
            if step < node.sequence.perStepProbability!.count {
                node.sequence.perStepProbability![step] = probability
            }
        }
    }

    // MARK: - Micro-Timing Lane

    private func microTimingLane(sequence: NoteSequence, fontSize: CGFloat) -> some View {
        let cols = columns
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let laneHeight: CGFloat = 30
        let canvasWidth = CGFloat(charCols) * cw
        let offsets = sequence.microTimingOffsets
        let centerY = laneHeight / 2

        return VStack(spacing: 0) {
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(height: 1)

            HStack(spacing: 0) {
                Text("μT")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.3))
                    .frame(width: 24, alignment: .trailing)
                    .padding(.trailing, 2)

                Canvas { context, size in
                    // Center line
                    var centerPath = Path()
                    centerPath.move(to: CGPoint(x: 0, y: centerY))
                    centerPath.addLine(to: CGPoint(x: size.width, y: centerY))
                    context.stroke(centerPath, with: .color(CanopyColors.chromeText.opacity(0.1)), lineWidth: 0.5)

                    for step in 0..<displayColumns {
                        guard step < cols else { continue }
                        let offset: Double
                        if let arr = offsets, step < arr.count {
                            offset = arr[step]
                        } else {
                            offset = 0
                        }

                        let charCol = colMap[step]
                        let x = CGFloat(charCol) * cw + cw / 2
                        // Map offset (-48...48) to vertical position
                        let dotY = centerY - CGFloat(offset / 48.0) * (laneHeight / 2 - 3)
                        let dotRadius: CGFloat = abs(offset) > 0.5 ? 2.5 : 1.0
                        let dotColor = abs(offset) > 0.5
                            ? CanopyColors.glowColor.opacity(0.7)
                            : CanopyColors.chromeText.opacity(0.15)

                        let dotRect = CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                        context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                    }
                }
                .frame(width: canvasWidth, height: laneHeight)
            }
        }
    }

    // MARK: - Compact Advanced Controls (bottom-right overlay)

    private var compactAdvancedControls: some View {
        let mutation = node?.sequence.mutation
        let mutRange = mutation?.range ?? 1
        let acc = node?.sequence.accumulator
        let accEnabled = acc != nil
        let accTarget = acc?.target ?? .pitch
        let accMode = acc?.mode ?? .clamp

        return VStack(alignment: .trailing, spacing: 5) {
            // PROB row
            HStack(spacing: 4) {
                Text("PROB")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                compactSlider(value: $localProbability, range: 0...1, width: 80, onCommit: {
                    commitGlobalProbability()
                }, onDrag: {
                    guard let nodeID = projectState.selectedNodeID else { return }
                    AudioEngine.shared.setGlobalProbability(localProbability, nodeID: nodeID)
                })
                Text("\(Int(localProbability * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 28, alignment: .trailing)
            }

            // MUTATION row
            HStack(spacing: 4) {
                Text("MUT")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                compactSlider(value: $localMutationAmount, range: 0...1, width: 60, onCommit: {
                    commitMutationAmount()
                }, onDrag: {
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
                Text("\(Int(localMutationAmount * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 28, alignment: .trailing)
                compactDragValue(value: mutRange, range: 1...7) { setMutationRange($0) }
                Button(action: { freezeMutation() }) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 9))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                }
                .buttonStyle(.plain)
                Button(action: { resetMutation() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            // ACCUMULATOR row
            HStack(spacing: 4) {
                Text("ACC")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                Button(action: { toggleAccumulator() }) {
                    Image(systemName: accEnabled ? "checkmark.square" : "square")
                        .font(.system(size: 9))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)

                if accEnabled {
                    ForEach(AccumulatorTarget.allCases, id: \.self) { t in
                        let sel = accTarget == t
                        Button(action: { setAccumulatorTarget(t) }) {
                            Text(t.rawValue.prefix(3))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(sel ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(sel ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    compactDragValue(value: Int(localAccAmount), range: -12...12) { val in
                        localAccAmount = Double(val)
                        commitAccumulatorAmount()
                    }
                    compactDragValue(value: Int(localAccLimit), range: 1...48) { val in
                        localAccLimit = Double(val)
                        commitAccumulatorLimit()
                    }
                    ForEach(AccumulatorMode.allCases, id: \.self) { m in
                        let sel = accMode == m
                        Button(action: { setAccumulatorMode(m) }) {
                            Text(m.rawValue.prefix(3))
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundColor(sel ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(sel ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Arp controls when active
            if isArpActive {
                compactArpControls
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(CanopyColors.bloomPanelBackground.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var compactArpControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
        let rates: [(ArpRate, String)] = [
            (.eighth, "1/8"), (.sixteenth, "1/16"), (.thirtySecond, "1/32"),
        ]

        return HStack(spacing: 4) {
            Text("ARP")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.glowColor.opacity(0.6))
            ForEach(rates, id: \.0) { rate, label in
                let isActive = arpConfig.rate == rate
                Button(action: { setArpRate(rate) }) {
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Text("G")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            compactSlider(value: $localArpGate, range: 0.05...1.0, width: 40, onCommit: {
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
        }
    }

    // MARK: - Compact Controls

    private func compactSlider(value: Binding<Double>, range: ClosedRange<Double>, width: CGFloat, onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
        let filledWidth = max(0, min(width, width * fraction))

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                .frame(width: width, height: 6)

            RoundedRectangle(cornerRadius: 2)
                .fill(CanopyColors.glowColor.opacity(0.5))
                .frame(width: filledWidth, height: 6)
        }
        .frame(width: width, height: 6)
        .contentShape(Rectangle())
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

    private func compactDragValue(value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) -> some View {
        Text("\(value)")
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(CanopyColors.chromeText.opacity(0.7))
            .frame(width: 18, height: 14)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(CanopyColors.chromeBackground.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
            )
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let delta = -Int(round(drag.translation.height / 8))
                        let newVal = max(range.lowerBound, min(range.upperBound, value + delta))
                        onChange(newVal)
                    }
            )
            .onTapGesture {
                let next = value + 1 > range.upperBound ? range.lowerBound : value + 1
                onChange(next)
            }
    }

    /// Drag value used by header controls (S/E/R/Oct).
    private func headerDragValue(label: String, value: Int, range: ClosedRange<Int>, onChange: @escaping (Int) -> Void) -> some View {
        let dragSensitivity: CGFloat = 8
        return HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))

            Text("\(value)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.8))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CanopyColors.chromeBackground.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
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

    // MARK: - Header: Direction Picker

    private var directionPicker: some View {
        let currentDirection = node?.sequence.playbackDirection ?? .forward
        let directions: [(PlaybackDirection, String, String)] = [
            (.forward, "→", "Forward"),
            (.reverse, "←", "Reverse"),
            (.pingPong, "↔", "Ping-Pong"),
            (.random, "?", "Random"),
            (.brownian, "~", "Brownian"),
        ]

        return HStack(spacing: 3) {
            ForEach(directions, id: \.0) { dir, symbol, tooltip in
                let isActive = currentDirection == dir
                Button(action: { setDirection(dir) }) {
                    Text(symbol)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
    }

    // MARK: - Header: Arp Mode Picker

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

        return HStack(spacing: 3) {
            ForEach(modes, id: \.0) { mode, symbol, tooltip in
                let isActive = currentMode == mode
                Button(action: { setArpMode(mode) }) {
                    Text(symbol)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 24, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
    }

    // MARK: - Header Controls (S / E / R / dice)

    private var headerControls: some View {
        let euclidean = node?.sequence.euclidean
        let pulses = euclidean?.pulses ?? 4
        let rotation = euclidean?.rotation ?? 0

        return HStack(spacing: 6) {
            headerDragValue(label: "S", value: columns, range: 1...64) { changeLength(to: $0) }

            headerDragValue(
                label: "E", value: pulses, range: 0...columns
            ) { applyEuclidean(pulses: $0, rotation: rotation) }

            headerDragValue(
                label: "R", value: rotation, range: 0...(max(1, columns - 1))
            ) { applyEuclidean(pulses: pulses, rotation: $0) }

            Button(action: { randomFill() }) {
                Image(systemName: "dice")
                    .font(.system(size: 12))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help("Random scale fill")
        }
    }

    // MARK: - Header: Arp Controls

    private var arpHeaderControls: some View {
        let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
        let octave = arpConfig.octaveRange

        return HStack(spacing: 6) {
            headerDragValue(label: "Oct", value: octave, range: 1...4) { setArpOctave($0) }
            headerDragValue(label: "S", value: columns, range: 1...64) { changeLength(to: $0) }

            Button(action: { randomFill() }) {
                Image(systemName: "dice")
                    .font(.system(size: 12))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .help("Random scale fill")
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
        selectedStepCount = newStepCount
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
