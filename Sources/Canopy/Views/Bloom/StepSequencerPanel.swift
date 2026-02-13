import SwiftUI

/// Bloom panel: step sequencer grid with algorithmic features.
/// Dynamic column count based on node's sequence length.
/// Derives boolean state from NoteSequence.notes.
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

    private var node: Node? {
        projectState.selectedNode
    }

    /// Active step count from the sequence length.
    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 2.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    /// Always render 32 columns so grid size never changes.
    private var displayColumns: Int { 32 }

    private var cellSpacing: CGFloat { 1.5 * cs }

    private var cellCornerRadius: CGFloat { cellSize * 0.25 }

    /// Available width for the grid cells (panel minus padding, touch strip, labels, spacings).
    private var gridAreaWidth: CGFloat {
        // panelWidth - 2*padding(14) - touchStrip(12) - labels(22) - 2*hstackSpacing(4)
        (panelWidth - 28 - 12 - 22 - 8) * cs
    }

    /// Cell size derived from available grid width so cells fill the panel.
    private var cellSize: CGFloat {
        let spacing = cellSpacing
        let ideal = (gridAreaWidth + spacing) / CGFloat(displayColumns) - spacing
        return max(6 * cs, floor(ideal))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header: title, direction, S/E/R controls
            HStack(spacing: 6 * cs) {
                Text("SEQUENCE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                if node != nil {
                    directionPicker
                }

                Spacer()

                headerControls
            }

            if let node {
                HStack(alignment: .top, spacing: 4 * cs) {
                    // Touch strip (left of grid)
                    pitchTouchStrip

                    // Note labels
                    noteLabels

                    // Grid + velocity bars + playhead
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 2 * cs) {
                            gridView(sequence: node.sequence)
                            velocityBars(sequence: node.sequence)
                        }
                        .drawingGroup()

                        SequencerPlayhead(
                            transportState: transportState,
                            lengthInBeats: node.sequence.lengthInBeats,
                            columns: columns,
                            rows: rows,
                            cellSize: cellSize,
                            cellSpacing: cellSpacing,
                            cellCornerRadius: cellCornerRadius,
                            cs: cs
                        )
                    }
                }
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
        .padding(14 * cs)
        .frame(width: panelWidth * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
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

    // MARK: - Touch Strip

    /// Ableton Push-style vertical touch strip for scrolling the visible pitch range.
    private var pitchTouchStrip: some View {
        let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing
        let totalRange = midiHigh - midiLow - rows
        let normalizedPos = totalRange > 0
            ? CGFloat(baseNote - midiLow) / CGFloat(totalRange)
            : 0.5

        return ZStack(alignment: .bottom) {
            // Track
            RoundedRectangle(cornerRadius: 3 * cs)
                .fill(CanopyColors.chromeBackground.opacity(0.6))
            RoundedRectangle(cornerRadius: 3 * cs)
                .stroke(CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)

            // Thumb indicator
            let thumbHeight: CGFloat = max(12 * cs, gridHeight * CGFloat(rows) / CGFloat(midiHigh - midiLow))
            let travel = gridHeight - thumbHeight
            RoundedRectangle(cornerRadius: 2 * cs)
                .fill(CanopyColors.glowColor.opacity(0.4))
                .frame(width: 8 * cs, height: thumbHeight)
                .offset(y: -normalizedPos * travel)
        }
        .frame(width: 12 * cs, height: gridHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing
                    // Invert: top = high notes, bottom = low notes
                    let fraction = 1.0 - (value.location.y / gridHeight)
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
        let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing
        return VStack(spacing: cellSpacing) {
            ForEach((0..<rows).reversed(), id: \.self) { row in
                let pitch = baseNote + row
                let name = MIDIUtilities.noteName(forNote: pitch)
                let isC = pitch % 12 == 0
                Text(name)
                    .font(.system(size: 7 * cs, weight: isC ? .bold : .regular, design: .monospaced))
                    .foregroundColor(isC ? CanopyColors.glowColor.opacity(0.7) : CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 22 * cs, height: cellSize, alignment: .trailing)
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

    private func gridView(sequence: NoteSequence) -> some View {
        let lookup = noteEventLookup(for: sequence)
        return VStack(spacing: cellSpacing) {
            ForEach((0..<rows).reversed(), id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<displayColumns, id: \.self) { col in
                        let pitch = baseNote + row
                        let enabled = col < columns
                        let noteEvent = enabled ? lookup[pitch &* 1000 &+ col] : nil
                        stepCell(pitch: pitch, step: col, noteEvent: noteEvent, sequence: sequence, enabled: enabled)
                    }
                }
            }
        }
    }

    // MARK: - Velocity Bars

    private func velocityBars(sequence: NoteSequence) -> some View {
        // Pre-compute max velocity per step
        var stepVelocities = [Int: Double]()
        for event in sequence.notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            if let existing = stepVelocities[step] {
                if event.velocity > existing { stepVelocities[step] = event.velocity }
            } else {
                stepVelocities[step] = event.velocity
            }
        }

        let maxBarHeight: CGFloat = 5 * cs
        return HStack(spacing: cellSpacing) {
            ForEach(0..<displayColumns, id: \.self) { col in
                let enabled = col < columns
                let maxVel = enabled ? (stepVelocities[col] ?? 0) : 0.0
                let dimFactor: Double = enabled ? 1.0 : 0.25

                RoundedRectangle(cornerRadius: 1 * cs)
                    .fill(CanopyColors.glowColor.opacity((maxVel > 0 ? 0.5 : 0.1) * dimFactor))
                    .frame(width: cellSize, height: max(1, maxBarHeight * CGFloat(maxVel)))
            }
        }
        .frame(height: 5 * cs, alignment: .bottom)
    }

    private func stepCell(pitch: Int, step: Int, noteEvent: NoteEvent?, sequence: NoteSequence, enabled: Bool = true) -> some View {
        let isActive = noteEvent != nil
        let isEuclidean = sequence.euclidean != nil && isActive
        let probability = noteEvent?.probability ?? 1.0
        let ratchetCount = noteEvent?.ratchetCount ?? 1
        let dimFactor: Double = enabled ? 1.0 : 0.25

        let euclideanGreen = Color(red: 0.2, green: 0.7, blue: 0.4)
        let baseColor = isEuclidean ? euclideanGreen : CanopyColors.gridCellActive

        let strokeColor: Color = isActive
            ? baseColor.opacity((probability * 0.8 + 0.2) * dimFactor)
            : CanopyColors.bloomPanelBorder.opacity(0.3 * dimFactor)
        let strokeWidth: CGFloat = isActive ? 1.5 : 0.5
        let fillColor: Color = isActive
            ? baseColor.opacity(0.1 * dimFactor)
            : CanopyColors.gridCellInactive.opacity(dimFactor)

        return ZStack {
            RoundedRectangle(cornerRadius: cellCornerRadius)
                .fill(fillColor)
                .frame(width: cellSize, height: cellSize)

            RoundedRectangle(cornerRadius: cellCornerRadius)
                .stroke(strokeColor, lineWidth: strokeWidth)
                .frame(width: cellSize, height: cellSize)

            // Ratchet indicator: subdivision lines
            if isActive && ratchetCount > 1 {
                VStack(spacing: 0) {
                    ForEach(0..<ratchetCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.3 * dimFactor))
                            .frame(width: cellSize - 4 * cs, height: 1)
                    }
                }
            }
        }
        .onTapGesture {
            if enabled { toggleNote(pitch: pitch, step: step) }
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
    private func seqSlider(value: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
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
                        let newValue = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                        onChange(newValue)
                    }
            )
        }
        .frame(height: 8 * cs)
    }

    // MARK: - Probability Slider

    private var probabilitySlider: some View {
        let prob = node?.sequence.globalProbability ?? 1.0
        return HStack(spacing: 6 * cs) {
            Text("PROB")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            seqSlider(value: prob, range: 0...1) { setGlobalProbability($0) }
                .frame(width: 100 * cs)

            Text("\(Int(prob * 100))%")
                .font(.system(size: 9 * cs, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 30 * cs, alignment: .trailing)
        }
    }

    // MARK: - Mutation Controls

    private var mutationControls: some View {
        let mutation = node?.sequence.mutation
        let amount = mutation?.amount ?? 0
        let range = mutation?.range ?? 1

        return VStack(alignment: .leading, spacing: 4 * cs) {
            Text("MUTATION")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            HStack(spacing: 6 * cs) {
                Text("Amt")
                    .font(.system(size: 9 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                seqSlider(value: amount, range: 0...1) { setMutationAmount($0) }
                    .frame(width: 80 * cs)

                Text("\(Int(amount * 100))%")
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
        let amount = acc?.amount ?? 1.0
        let limit = acc?.limit ?? 12.0
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
                    seqSlider(value: amount, range: -12...12) { setAccumulatorAmount($0) }
                        .frame(width: 80 * cs)
                    Text(String(format: "%.1f", amount))
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28 * cs, alignment: .trailing)
                }

                HStack(spacing: 6 * cs) {
                    Text("Lim")
                        .font(.system(size: 9 * cs, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    seqSlider(value: limit, range: 1...48) { setAccumulatorLimit($0) }
                        .frame(width: 80 * cs)
                    Text(String(format: "%.0f", limit))
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

    // MARK: - Length Change

    private func changeLength(to newStepCount: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let sd = NoteSequence.stepDuration
        let newLengthBeats = Double(newStepCount) * sd
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { $0.startBeat >= newLengthBeats }
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

    // MARK: - Probability

    private func setGlobalProbability(_ prob: Double) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.globalProbability = prob
        }
        // Use dedicated command for responsive updates
        AudioEngine.shared.setGlobalProbability(prob, nodeID: nodeID)
    }

    // MARK: - Mutation

    private func setMutationAmount(_ amount: Double) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.mutation == nil {
                node.sequence.mutation = MutationConfig(amount: amount, range: 1)
            } else {
                node.sequence.mutation?.amount = amount
            }
        }
        let key = resolveKey()
        AudioEngine.shared.setMutation(
            amount: amount,
            range: node?.sequence.mutation?.range ?? 1,
            rootSemitone: key.root.semitone,
            intervals: key.mode.intervals,
            nodeID: nodeID
        )
    }

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

    // MARK: - Accumulator

    private func toggleAccumulator() {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.accumulator != nil {
                node.sequence.accumulator = nil
            } else {
                node.sequence.accumulator = AccumulatorConfig()
            }
        }
        reloadSequence()
    }

    private func setAccumulatorTarget(_ target: AccumulatorTarget) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.target = target
        }
        reloadSequence()
    }

    private func setAccumulatorAmount(_ amount: Double) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.amount = amount
        }
        reloadSequence()
    }

    private func setAccumulatorLimit(_ limit: Double) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.accumulator?.limit = limit
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

    // MARK: - Note Logic

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let stepBeat = Double(step) * NoteSequence.stepDuration

        projectState.updateNode(id: nodeID) { node in
            if let existingIndex = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && abs($0.startBeat - stepBeat) < 0.01
            }) {
                node.sequence.notes.remove(at: existingIndex)
            } else {
                let event = NoteEvent(
                    pitch: pitch,
                    velocity: 0.8,
                    startBeat: stepBeat,
                    duration: NoteSequence.stepDuration
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

// MARK: - Playhead (isolated ObservableObject to avoid re-rendering grid at 30Hz)

private struct SequencerPlayhead: View {
    @ObservedObject var transportState: TransportState
    let lengthInBeats: Double
    let columns: Int
    let rows: Int
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let cellCornerRadius: CGFloat
    let cs: CGFloat

    /// Poll interval matches TransportState timer (~30Hz).
    private let pollInterval: Double = 1.0 / 30.0

    var body: some View {
        if transportState.isPlaying {
            let beatFraction = transportState.currentBeat / max(lengthInBeats, 1)
            let step = beatFraction * Double(columns)
            let xOffset = CGFloat(step) * (cellSize + cellSpacing)
            let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing
            let totalHeight = gridHeight + 2 * cs + 5 * cs

            RoundedRectangle(cornerRadius: cellCornerRadius)
                .fill(CanopyColors.glowColor.opacity(0.2))
                .frame(width: cellSize, height: totalHeight)
                .offset(x: xOffset, y: 0)
                .allowsHitTesting(false)
                .animation(.linear(duration: pollInterval), value: xOffset)
        }
    }
}
