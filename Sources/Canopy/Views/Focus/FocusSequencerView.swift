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
    @State private var currentPage: Int = 0
    @State private var spanDragState: SpanDragState?

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

    /// Always display 32 columns — pagination handles longer sequences.
    private var displayColumns: Int { 32 }

    /// Pagination: offset into global steps for the current page.
    private var pageOffset: Int { currentPage * 32 }

    /// Number of pages needed (1 for ≤32 steps, 2 for 33-64).
    private var pageCount: Int { columns <= 32 ? 1 : 2 }

    /// How many columns on the current page are active (not dimmed).
    private var activeColumnsOnPage: Int { max(0, min(32, columns - pageOffset)) }

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
        .onChange(of: columns) { newCols in
            // Clamp page when columns shrink below current page range
            if newCols <= 32, currentPage > 0 {
                currentPage = 0
            }
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

    // MARK: - Sync

    private func syncOnAppear() {
        syncSeqFromModel()
    }

    private func syncSeqFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
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

            // Page indicator (only for sequences > 32 steps)
            if pageCount > 1 {
                pageIndicator
            }
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

    // MARK: - Main Content (adaptive two-column layout)

    private func mainContent(width: CGFloat, height: CGFloat) -> some View {
        let pitchRows = 12
        let pitches = SequencerGridCore.visiblePitches(
            baseNote: baseNote, rowCount: pitchRows,
            key: resolveKey(), scaleAware: scaleAwareEnabled
        )
        let labelWidth: CGFloat = 32
        let stripWidth: CGFloat = 14
        let sidebarWidth: CGFloat = max(180, width * 0.28)
        let gridAreaWidth = width - sidebarWidth - 1
        let gridWidth = gridAreaWidth - labelWidth - stripWidth - 32
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let fontSize = max(6, min(24, gridWidth / (CGFloat(charCols) * 0.78)))
        let rh = SequencerGridCore.cellHeight(fontSize: fontSize)
        let laneInsetX = stripWidth + labelWidth + 16

        return HStack(spacing: 0) {
            // Grid column
            VStack(spacing: 0) {
                Spacer(minLength: 12)

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

                    if microTimingEnabled {
                        microTimingLane(sequence: node.sequence, fontSize: fontSize)
                            .padding(.leading, laneInsetX)
                            .padding(.trailing, 6)
                    }
                }

                Spacer(minLength: 12)
            }

            // Sidebar — always visible
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(width: 1)

            sidebarView
                .frame(width: sidebarWidth)
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        let mutRange = node?.sequence.mutation?.range ?? 1

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {

                // MUTATION section
                sidebarSection("MUTATION") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Amt")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                            compactSlider(value: $localMutationAmount, range: 0...1, width: 80, onCommit: {
                                commitMutationAmount()
                            }, onDrag: {})
                            Text("\(Int(localMutationAmount * 100))%")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        }
                        HStack(spacing: 6) {
                            Text("Rng")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                            compactDragValue(value: mutRange, range: 1...7) { setMutationRange($0) }
                        }
                        HStack(spacing: 6) {
                            Button(action: { freezeMutation() }) {
                                sidebarPill("Freeze", icon: "snowflake")
                            }
                            .buttonStyle(.plain)
                            Button(action: { resetMutation() }) {
                                sidebarPill("Reset", icon: "arrow.counterclockwise")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ARP section (conditional)
                if isArpActive {
                    sidebarSection("ARP") {
                        VStack(alignment: .leading, spacing: 6) {
                            let arpConfig = node?.sequence.arpConfig ?? ArpConfig()
                            let rates: [(ArpRate, String)] = [
                                (.eighth, "1/8"), (.sixteenth, "1/16"), (.thirtySecond, "1/32"),
                            ]
                            HStack(spacing: 3) {
                                Text("Rate")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                                ForEach(rates, id: \.0) { rate, label in
                                    let isActive = arpConfig.rate == rate
                                    Button(action: { setArpRate(rate) }) {
                                        Text(label)
                                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                                            .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(isActive ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            HStack(spacing: 6) {
                                Text("Gate")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                                compactSlider(value: $localArpGate, range: 0.05...1.0, width: 80, onCommit: {
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
                    }
                }

                // DISPLAY section
                sidebarSection("DISPLAY") {
                    HStack(spacing: 6) {
                        Button(action: { microTimingEnabled.toggle() }) {
                            sidebarPill("\u{03BC}T", icon: nil, isActive: microTimingEnabled)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Sidebar Helpers

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.glowColor.opacity(0.7))

            content()

            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.2))
                .frame(height: 1)
        }
    }

    private func sidebarPill(_ label: String, icon: String?, isActive: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : CanopyColors.chromeBackground.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isActive ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
        )
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
        let isMicroTimingOn = microTimingEnabled
        let microOffsets = sequence.microTimingOffsets
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
                // This note spans into our page
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
            showVelocityRow: true
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

                // Micro-timing overlay: draw chevrons on notes with non-zero offsets
                if isMicroTimingOn, let offsets = microOffsets {
                    for note in sequence.notes {
                        let globalStep = Int(round(note.startBeat / sd))
                        let localStep = globalStep - pOffset
                        guard localStep >= 0, localStep < activeCols else { continue }
                        guard globalStep < offsets.count else { continue }
                        let offset = offsets[globalStep]
                        guard abs(offset) > 0.5 else { continue }
                        guard let rowIdx = pitches.firstIndex(of: note.pitch) else { continue }

                        let charCol = colMap[min(localStep, displayColumns - 1)]
                        let x = CGFloat(charCol) * cw + cw / 2
                        let y = CGFloat(rowIdx + 1) * rh + rh / 2 // +1 for top border row

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
                    let rowIdx = Int(location.y / rh) - 1 // offset for top border row
                    guard rowIdx >= 0, rowIdx < pitches.count,
                          charCol >= 0, charCol < charCols else { return }
                    guard let localStep = reverseMap[charCol], localStep < activeCols else { return }
                    let globalStep = localStep + pOffset
                    resetMicroTimingOffset(step: globalStep, nodeID: nodeID)
                }
            }
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
                            if isMicroTimingOn {
                                let pixelOffset = value.translation.width
                                let tickOffset = Double(pixelOffset / cw) * 48.0
                                let clamped = max(-48, min(48, tickOffset))
                                setMicroTimingOffset(step: globalStartStep, offset: clamped, nodeID: nodeID)
                            } else if dx > dy {
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
                            // Selection rectangle completed — find notes within (page-local)
                            resolveSelectionPaginated(rect: rect, pitches: pitches, cw: cw, rh: rh,
                                                      colMap: colMap, pageOffset: pOffset, activeCols: activeCols,
                                                      notes: sequence.notes)
                            selectionRect = nil
                        } else if !isMicroTimingOn {
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
                                // Normal click: toggle note (global step)
                                toggleNote(pitch: pitch, step: globalStep)
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

    /// Resolve which notes fall within a selection rectangle (page-local coordinates).
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
            let noteY = CGFloat(rowIdx + 1) * rh + rh / 2 // +1 for top border row

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
        let pOffset = pageOffset
        let activeCols = activeColumnsOnPage
        let cw = SequencerGridCore.cellWidth(fontSize: fontSize)
        let charCols = SequencerGridCore.gridCharCols(for: displayColumns)
        let colMap = SequencerGridCore.stepToCharCol(for: displayColumns)
        let reverseMap = SequencerGridCore.charColToStep(displayColumns: displayColumns)
        let laneHeight: CGFloat = 44
        let canvasWidth = CGFloat(charCols) * cw
        let sd = NoteSequence.stepDuration

        // Build per-step velocity map using page-local step indices
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
        let pOffset = pageOffset
        let activeCols = activeColumnsOnPage
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

                    for localStep in 0..<displayColumns {
                        guard localStep < activeCols else { continue }
                        let globalStep = localStep + pOffset
                        let offset: Double
                        if let arr = offsets, globalStep < arr.count {
                            offset = arr[globalStep]
                        } else {
                            offset = 0
                        }

                        let charCol = colMap[localStep]
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
        let mutRange = node?.sequence.mutation?.range ?? 1

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

            headerDragValue(label: "P", value: Int(localProbability * 100), range: 0...100) { newVal in
                localProbability = Double(newVal) / 100.0
                commitGlobalProbability()
            }

            headerDragValue(label: "M", value: Int(localMutationAmount * 100), range: 0...100) { newVal in
                localMutationAmount = Double(newVal) / 100.0
                commitMutationAmount()
            }

            headerDragValue(label: "±", value: mutRange, range: 1...7) { setMutationRange($0) }

            Button(action: { freezeMutation() }) {
                Image(systemName: "snowflake")
                    .font(.system(size: 10))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Freeze mutations")

            Button(action: { resetMutation() }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Reset mutations")
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

            headerDragValue(label: "P", value: Int(localProbability * 100), range: 0...100) { newVal in
                localProbability = Double(newVal) / 100.0
                commitGlobalProbability()
            }
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
