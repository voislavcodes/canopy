import SwiftUI

/// Focus-mode sequencer: two-column editing view with piano-roll grid on the left
/// and all 18 forest control cells in a flat 3×6 grid on the right.
/// Uses SequencerGridCore for shared grid rendering and SequencerActions for model mutations.
struct FocusSequencerView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    /// MIDI range for the touch strip (C1 to C7)
    private let midiLow = 24
    private let midiHigh = 96
    private let defaultRows = 8

    @State private var baseNote: Int = 55  // G3
    @State private var currentPage: Int = 0
    @State private var spanDragState: SpanDragState?

    // Multi-note selection (Phase E)
    @State private var selectedNoteIDs: Set<UUID> = []
    @State private var selectionRect: CGRect?
    @State private var clipboard: [NoteEvent] = []

    /// Binding from FocusView to communicate selection state for key handling.
    var sequencerHasSelection: Binding<Bool>?

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

    /// Always display 32 columns — pagination handles longer sequences.
    private var displayColumns: Int { 32 }

    /// Pagination: offset into global steps for the current page.
    private var pageOffset: Int { currentPage * 32 }

    /// Number of pages needed (1 for ≤32 steps, 2 for 33-64).
    private var pageCount: Int { columns <= 32 ? 1 : 2 }

    /// How many columns on the current page are active (not dimmed).
    private var activeColumnsOnPage: Int { max(0, min(32, columns - pageOffset)) }

    var body: some View {
        GeometryReader { geo in
            mainContent(width: geo.size.width, height: geo.size.height)
        }
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .onAppear {
            // Clamp page on appear
            if columns <= 32, currentPage > 0 { currentPage = 0 }
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            if columns <= 32, currentPage > 0 { currentPage = 0 }
        }
        .onChange(of: columns) { newCols in
            if newCols <= 32, currentPage > 0 { currentPage = 0 }
        }
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

    // MARK: - Main Content (grid left, forest panel right)

    private func mainContent(width: CGFloat, height: CGFloat) -> some View {
        let pitchRows = 12
        let pitches = SequencerGridCore.visiblePitches(
            baseNote: baseNote, rowCount: pitchRows,
            key: resolveKey(), scaleAware: scaleAwareEnabled
        )
        let labelWidth: CGFloat = 32
        let stripWidth: CGFloat = 14
        let sidebarFraction: CGFloat = 0.35
        let sidebarWidth: CGFloat = max(200, width * sidebarFraction)
        let gridAreaWidth = width - sidebarWidth - 1
        let gridWidth = gridAreaWidth - labelWidth - stripWidth - 32
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let fontSize = max(6, min(24, gridWidth / (CGFloat(charCols) * 0.78)))
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let laneInsetX = stripWidth + labelWidth + 16

        return HStack(spacing: 0) {
            // Grid column — top-aligned content, fills remaining space
            VStack(spacing: 0) {
                if let node {
                    HStack(alignment: .top, spacing: 4) {
                        focusTouchStrip(pitches: pitches, fontSize: fontSize)
                            .padding(.top, rh)
                        focusNoteLabels(pitches: pitches, fontSize: fontSize)
                            .padding(.top, rh)
                        focusGridCanvas(sequence: node.sequence, nodeID: node.id, pitches: pitches, fontSize: fontSize)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 6)

                    velocityLane(sequence: node.sequence, nodeID: node.id, fontSize: fontSize)
                        .padding(.leading, laneInsetX)
                        .padding(.trailing, 6)

                    probabilityLane(sequence: node.sequence, nodeID: node.id, fontSize: fontSize)
                        .padding(.leading, laneInsetX)
                        .padding(.trailing, 6)
                }

                // Page indicator (only for sequences > 32 steps)
                if pageCount > 1 {
                    pageIndicator
                        .padding(.top, 6)
                }

                Spacer()
            }
            .padding(.top, 12)

            // Divider
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(width: 1)

            // Sidebar — ForestPitchedPanel in flat layout mode
            ForestPitchedPanel(
                projectState: projectState,
                transportState: transportState,
                layoutMode: .focus
            )
            .frame(width: sidebarWidth)
        }
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<pageCount, id: \.self) { page in
                let isActive = currentPage == page
                let rangeStart = page * 32 + 1
                let rangeEnd = min((page + 1) * 32, columns)
                Button(action: {
                    currentPage = page
                }) {
                    Text("\(rangeStart)-\(rangeEnd)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
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
                    SequencerGridCore.drawChar(context, "\u{2588}", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.glowColor.opacity(0.6))
                } else {
                    SequencerGridCore.drawChar(context, "\u{2502}", at: CGPoint(x: x, y: y), size: fontSize, color: CanopyColors.chromeText.opacity(0.15))
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

    // MARK: - Grid Canvas (shared core, paginated)

    private func focusGridCanvas(sequence: NoteSequence, nodeID: UUID, pitches: [Int], fontSize: CGFloat) -> some View {
        let globalCols = columns
        let pOffset = pageOffset
        let activeCols = activeColumnsOnPage
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let sd = NoteSequence.stepDuration

        // Build page-local lookup: filter notes to current page, key by local step
        var pageLookup = [Int: NoteEvent]()
        var pageNotes = [NoteEvent]()
        for event in sequence.notes {
            let globalStep = Int(round(event.startBeat / sd))
            let localStep = globalStep - pOffset
            guard localStep >= 0, localStep < 32 else { continue }
            let key = event.pitch &* 1000 &+ localStep
            pageLookup[key] = event
            var localEvent = event
            localEvent.startBeat = Double(localStep) * sd
            pageNotes.append(localEvent)
        }

        // Build page-local continuations
        let pageLocalSpan: SpanDragState?
        if let drag = spanDragState {
            let localStart = drag.startStep - pOffset
            let localEnd = drag.currentEndStep - pOffset
            if localStart >= 0, localStart < 32 {
                pageLocalSpan = SpanDragState(pitch: drag.pitch, startStep: localStart, currentEndStep: max(localStart + 1, min(32, localEnd)))
            } else {
                pageLocalSpan = nil
            }
        } else {
            pageLocalSpan = nil
        }
        let continuations = SequencerGridCore.buildSpanContinuationSet(notes: pageNotes, spanDragState: pageLocalSpan)

        // Also include continuations from notes that START before this page but span into it
        var extraContinuations = continuations
        for event in sequence.notes {
            let globalStart = Int(round(event.startBeat / sd))
            let spanSteps = max(1, Int(round(event.duration / sd)))
            let globalEnd = globalStart + spanSteps
            if globalStart < pOffset, globalEnd > pOffset {
                let localEnd = min(32, globalEnd - pOffset)
                for localStep in 0..<localEnd {
                    let key = event.pitch &* 1000 &+ localStep
                    extraContinuations.insert(key)
                }
            }
        }

        let stepVelocities = SequencerGridCore.buildStepVelocities(notes: pageNotes)

        let rc = GridRenderContext(
            pitches: pitches,
            activeColumns: activeCols,
            displayColumns: displayColumns,
            fontSize: fontSize,
            isArpActive: isArpActive,
            hasEuclidean: sequence.euclidean != nil,
            arpPitches: isArpActive ? Set(sequence.notes.map { $0.pitch }) : [],
            lookup: pageLookup,
            continuations: extraContinuations,
            stepVelocities: stepVelocities,
            playheadStep: -1,
            pulse: 0,
            spanDragState: pageLocalSpan,
            notes: pageNotes,
            showVelocityRow: false
        )
        let canvasSize = SequencerGridCore.canvasSize(for: rc)

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let engine = AudioEngine.shared
            let isPlaying = engine.isPlaying(for: nodeID)
            let currentBeat = engine.currentBeat(for: nodeID)
            let beatFraction = currentBeat / max(sequence.lengthInBeats, 1)
            let globalPlayheadStep = isPlaying ? Int(beatFraction * Double(globalCols)) % globalCols : -1

            // Auto-follow: switch page when playhead crosses boundary
            let playheadPage = globalPlayheadStep >= 0 ? globalPlayheadStep / 32 : currentPage
            let _: Void = isPlaying && playheadPage != currentPage && playheadPage < pageCount
                ? DispatchQueue.main.async { currentPage = playheadPage }
                : ()

            let localPlayheadStep = (globalPlayheadStep >= pOffset && globalPlayheadStep < pOffset + 32)
                ? globalPlayheadStep - pOffset : -1
            let pulse: CGFloat = 0.7 + 0.3 * CGFloat(sin(time * 6))

            Canvas { context, size in
                var frameRC = rc
                frameRC.playheadStep = localPlayheadStep
                frameRC.pulse = pulse
                SequencerGridCore.drawGrid(context, rc: frameRC)

                // Selection highlight overlay
                if !selectedNoteIDs.isEmpty {
                    for note in sequence.notes where selectedNoteIDs.contains(note.id) {
                        let globalStep = Int(round(note.startBeat / sd))
                        let localStep = globalStep - pOffset
                        guard localStep >= 0, localStep < activeCols else { continue }
                        guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }
                        let charCol = colMap[min(localStep, displayColumns - 1)]
                        let x = CGFloat(charCol) * cw
                        let y = CGFloat(rowIdx + 1) * rh // +1 for top border row
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
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = abs(value.translation.width)
                        let dy = abs(value.translation.height)
                        let isDrag = max(dx, dy) > 5

                        let startCharCol = Int(value.startLocation.x / cw)
                        let startRowIdx = Int(value.startLocation.y / rh) - 1 // offset for top border row
                        guard startRowIdx >= 0, startRowIdx < pitches.count,
                              startCharCol >= 0, startCharCol < charCols else { return }
                        guard let localStartStep = reverseMap[startCharCol], localStartStep < activeCols else { return }
                        let globalStartStep = localStartStep + pOffset
                        let pitch = pitches[startRowIdx]

                        let noteKey = pitch &* 1000 &+ localStartStep
                        let hasNote = pageLookup[noteKey] != nil

                        guard isDrag else { return }

                        if hasNote {
                            if dx > dy {
                                // Drag on note: extend span (global coordinates for model)
                                let currentCharCol = max(0, min(charCols - 1, Int(value.location.x / cw)))
                                let localTargetStep = SequencerGridCore.nearestStep(forCharCol: currentCharCol, reverseMap: reverseMap, maxStep: activeCols)
                                let globalEnd = max(globalStartStep + 1, min(globalCols, localTargetStep + pOffset + 1))
                                spanDragState = SpanDragState(pitch: pitch, startStep: globalStartStep, currentEndStep: globalEnd)
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
                            resolveSelectionPaginated(rect: rect, pitches: pitches, cw: cw, rh: rh,
                                                      colMap: colMap, pageOffset: pOffset, activeCols: activeCols,
                                                      notes: sequence.notes)
                            selectionRect = nil
                        } else {
                            guard abs(value.translation.width) < 5,
                                  abs(value.translation.height) < 5 else { return }
                            let loc = value.startLocation
                            let charCol = Int(loc.x / cw)
                            let rowIdx = Int(loc.y / rh) - 1 // offset for top border row
                            guard rowIdx >= 0, rowIdx < pitches.count,
                                  charCol >= 0, charCol < charCols else { return }
                            guard let localStep = reverseMap[charCol], localStep < activeCols else { return }
                            let globalStep = localStep + pOffset
                            let pitch = pitches[rowIdx]

                            // Check if shift is held for selection toggle
                            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
                            let noteKey = pitch &* 1000 &+ localStep
                            if shiftHeld, let noteEvent = pageLookup[noteKey] {
                                if selectedNoteIDs.contains(noteEvent.id) {
                                    selectedNoteIDs.remove(noteEvent.id)
                                } else {
                                    selectedNoteIDs.insert(noteEvent.id)
                                }
                                updateSelectionBinding()
                            } else if !selectedNoteIDs.isEmpty {
                                selectedNoteIDs.removeAll()
                                updateSelectionBinding()
                            } else {
                                toggleNote(pitch: pitch, step: globalStep)
                            }
                        }
                    }
            )
        }
    }

    // MARK: - Selection Helpers

    private func resolveSelectionPaginated(rect: CGRect, pitches: [Int], cw: CGFloat, rh: CGFloat,
                                           colMap: [Int], pageOffset: Int, activeCols: Int, notes: [NoteEvent]) {
        let sd = NoteSequence.stepDuration
        var newSelection = Set<UUID>()

        for note in notes {
            let globalStep = Int(round(note.startBeat / sd))
            let localStep = globalStep - pageOffset
            guard localStep >= 0, localStep < activeCols else { continue }
            guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }
            let charCol = colMap[min(localStep, displayColumns - 1)]
            let noteX = CGFloat(charCol) * cw + cw / 2
            let noteY = CGFloat(rowIdx + 1) * rh + rh / 2

            if rect.contains(CGPoint(x: noteX, y: noteY)) {
                newSelection.insert(note.id)
            }
        }

        selectedNoteIDs = newSelection
        updateSelectionBinding()
    }

    private func updateSelectionBinding() {
        sequencerHasSelection?.wrappedValue = !selectedNoteIDs.isEmpty
    }

    func clearSelection() -> Bool {
        guard !selectedNoteIDs.isEmpty else { return false }
        selectedNoteIDs.removeAll()
        updateSelectionBinding()
        return true
    }

    // MARK: - Selection Transforms

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

    func deleteSelection() {
        guard let nodeID = projectState.selectedNodeID, !selectedNoteIDs.isEmpty else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { selectedNoteIDs.contains($0.id) }
        }
        selectedNoteIDs.removeAll()
        updateSelectionBinding()
        SequencerActions.reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    func copySelection() {
        guard let node else { return }
        clipboard = node.sequence.notes.filter { selectedNoteIDs.contains($0.id) }
    }

    func pasteClipboard() {
        guard let nodeID = projectState.selectedNodeID, !clipboard.isEmpty else { return }
        let minBeat = clipboard.map(\.startBeat).min() ?? 0
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

    func duplicateSelection() {
        copySelection()
        pasteClipboard()
    }

    // MARK: - Velocity Lane

    private func velocityLane(sequence: NoteSequence, nodeID: UUID, fontSize: CGFloat) -> some View {
        let pOffset = pageOffset
        let activeCols = activeColumnsOnPage
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let laneHeight: CGFloat = 44
        let canvasWidth = CGFloat(charCols) * cw
        let sd = NoteSequence.stepDuration

        var stepVelSum = [Int: (total: Double, count: Int)]()
        for event in sequence.notes {
            let globalStep = Int(round(event.startBeat / sd))
            let localStep = globalStep - pOffset
            guard localStep >= 0, localStep < 32 else { continue }
            if let existing = stepVelSum[localStep] {
                stepVelSum[localStep] = (existing.total + event.velocity, existing.count + 1)
            } else {
                stepVelSum[localStep] = (event.velocity, 1)
            }
        }

        return VStack(spacing: 0) {
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
                    for localStep in 0..<displayColumns {
                        guard localStep < activeCols else { continue }
                        guard let velData = stepVelSum[localStep] else { continue }
                        let avgVel = velData.total / Double(velData.count)

                        let charCol = colMap[localStep]
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
                            guard let localStep = reverseMap[charCol], localStep < activeCols else { return }
                            let globalStep = localStep + pOffset
                            let velocity = max(0.05, min(1.0, 1.0 - (value.location.y / laneHeight)))
                            setVelocityForStep(step: globalStep, velocity: velocity, nodeID: nodeID)
                        }
                )
            }
        }
    }

    // MARK: - Probability Lane

    private func probabilityLane(sequence: NoteSequence, nodeID: UUID, fontSize: CGFloat) -> some View {
        let pOffset = pageOffset
        let activeCols = activeColumnsOnPage
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
                    for localStep in 0..<displayColumns {
                        guard localStep < activeCols else { continue }
                        let globalStep = localStep + pOffset

                        let prob: Double
                        if let arr = perStep, globalStep < arr.count {
                            prob = arr[globalStep]
                        } else {
                            prob = 1.0
                        }

                        let charCol = colMap[localStep]
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
                            guard let localStep = reverseMap[charCol], localStep < activeCols else { return }
                            let globalStep = localStep + pOffset
                            let prob = max(0.0, min(1.0, 1.0 - (value.location.y / laneHeight)))
                            setPerStepProbability(step: globalStep, probability: prob, nodeID: nodeID)
                        }
                )
            }
        }
    }

    private func setPerStepProbability(step: Int, probability: Double, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            let stepCount = max(1, Int(round(node.sequence.lengthInBeats / NoteSequence.stepDuration)))
            if node.sequence.perStepProbability == nil {
                node.sequence.perStepProbability = Array(repeating: 1.0, count: stepCount)
            }
            while node.sequence.perStepProbability!.count < stepCount {
                node.sequence.perStepProbability!.append(1.0)
            }
            if step < node.sequence.perStepProbability!.count {
                node.sequence.perStepProbability![step] = probability
            }
        }
    }

    // MARK: - Action Wrappers

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

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.toggleNote(projectState: projectState, nodeID: nodeID, pitch: pitch, step: step)
    }

    private func commitSpanDrag(pitch: Int, startStep: Int, newEndStep: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        SequencerActions.commitSpanDrag(projectState: projectState, nodeID: nodeID, pitch: pitch, startStep: startStep, newEndStep: newEndStep)
    }

    private func resolveKey() -> MusicalKey {
        guard let nodeID = projectState.selectedNodeID else {
            return projectState.project.globalKey
        }
        return SequencerActions.resolveKey(projectState: projectState, nodeID: nodeID)
    }
}
