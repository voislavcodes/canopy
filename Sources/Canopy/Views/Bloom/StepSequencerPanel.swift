import SwiftUI

/// Bloom panel: step sequencer grid with algorithmic features.
/// Dynamic column count based on node's sequence length.
/// Derives boolean state from NoteSequence.notes.
struct StepSequencerPanel: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState

    private static let lengthOptions: [Int] = [3, 4, 6, 8, 16, 32]

    private let rows = 8
    private let baseNote = 55  // G3 — centered range for a single octave+
    /// Target max grid width — cells scale down to fit.
    private let maxGridWidth: CGFloat = 210

    @State private var showAdvanced = false

    private var node: Node? {
        projectState.selectedNode
    }

    private var columns: Int {
        Int(node?.sequence.lengthInBeats ?? 8)
    }

    private var cellSpacing: CGFloat {
        columns > 16 ? 1 : (columns > 8 ? 2 : 3)
    }

    /// Cell size scales down for higher column counts to keep grid compact.
    private var cellSize: CGFloat {
        let spacing = cellSpacing
        let ideal = (maxGridWidth + spacing) / CGFloat(columns) - spacing
        return max(6, min(20, floor(ideal)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with title and length selector
            HStack(spacing: 8) {
                Text("SEQUENCE")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Spacer()

                lengthPicker
            }

            // Direction picker
            if let _ = node {
                directionPicker
            }

            if let node {
                ZStack(alignment: .topLeading) {
                    gridView(sequence: node.sequence)

                    if transportState.isPlaying {
                        playheadOverlay(lengthInBeats: node.sequence.lengthInBeats)
                    }
                }
            }

            // Euclidean + Fill controls
            euclideanControls

            // Probability slider
            probabilitySlider

            // Advanced toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                    Text("Advanced")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }
            .buttonStyle(.plain)

            if showAdvanced {
                mutationControls
                accumulatorControls
            }
        }
        .padding(14)
        .fixedSize()
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Length Picker

    private var lengthPicker: some View {
        HStack(spacing: 3) {
            ForEach(Self.lengthOptions, id: \.self) { length in
                let isActive = columns == length
                Button(action: { changeLength(to: length) }) {
                    Text("\(length)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isActive ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isActive ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
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

        return HStack(spacing: 3) {
            ForEach(directions, id: \.0) { dir, symbol, tooltip in
                let isActive = currentDirection == dir
                Button(action: { setDirection(dir) }) {
                    Text(symbol)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(isActive ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 22, height: 18)
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

            Spacer()
        }
    }

    // MARK: - Grid

    private func gridView(sequence: NoteSequence) -> some View {
        VStack(spacing: cellSpacing) {
            ForEach((0..<rows).reversed(), id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        let pitch = baseNote + row
                        let noteEvent = findNote(in: sequence, pitch: pitch, step: col)
                        stepCell(pitch: pitch, step: col, noteEvent: noteEvent, sequence: sequence)
                    }
                }
            }
        }
    }

    private func stepCell(pitch: Int, step: Int, noteEvent: NoteEvent?, sequence: NoteSequence) -> some View {
        let isActive = noteEvent != nil
        let isEuclidean = sequence.euclidean != nil && isActive
        let probability = noteEvent?.probability ?? 1.0
        let ratchetCount = noteEvent?.ratchetCount ?? 1

        let baseColor = isEuclidean
            ? Color(red: 0.2, green: 0.7, blue: 0.4)  // green for euclidean
            : CanopyColors.gridCellActive

        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? baseColor.opacity(probability) : CanopyColors.gridCellInactive)
                .frame(width: cellSize, height: cellSize)

            // Probability indicator: dim outline for low probability
            if isActive && probability < 1.0 {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(baseColor.opacity(0.4), lineWidth: 0.5)
                    .frame(width: cellSize, height: cellSize)
            }

            // Ratchet indicator: subdivision lines
            if isActive && ratchetCount > 1 {
                VStack(spacing: 0) {
                    ForEach(0..<ratchetCount, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: cellSize - 4, height: 1)
                    }
                }
            }
        }
        .onTapGesture {
            toggleNote(pitch: pitch, step: step)
        }
    }

    // MARK: - Euclidean Controls

    private var euclideanControls: some View {
        let euclidean = node?.sequence.euclidean
        let pulses = euclidean?.pulses ?? 4
        let rotation = euclidean?.rotation ?? 0

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Euclidean pulses
                HStack(spacing: 4) {
                    Text("E")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(euclidean != nil ? Color(red: 0.2, green: 0.7, blue: 0.4) : CanopyColors.chromeText.opacity(0.4))

                    Text("\(pulses)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                        .frame(width: 16)

                    Stepper("", value: Binding(
                        get: { pulses },
                        set: { applyEuclidean(pulses: $0, rotation: rotation) }
                    ), in: 0...columns)
                    .labelsHidden()
                    .scaleEffect(0.7)
                    .frame(width: 40)
                }

                // Rotation
                HStack(spacing: 4) {
                    Text("R")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                    Text("\(rotation)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                        .frame(width: 16)

                    Stepper("", value: Binding(
                        get: { rotation },
                        set: { applyEuclidean(pulses: pulses, rotation: $0) }
                    ), in: 0...(columns - 1))
                    .labelsHidden()
                    .scaleEffect(0.7)
                    .frame(width: 40)
                }

                Spacer()

                // Random fill button (dice)
                Button(action: { randomFill() }) {
                    Image(systemName: "dice")
                        .font(.system(size: 12))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.plain)
                .help("Random scale fill")
            }
        }
    }

    // MARK: - Probability Slider

    private var probabilitySlider: some View {
        let prob = node?.sequence.globalProbability ?? 1.0
        return HStack(spacing: 6) {
            Text("PROB")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Slider(value: Binding(
                get: { prob },
                set: { setGlobalProbability($0) }
            ), in: 0...1)
            .frame(width: 100)

            Text("\(Int(prob * 100))%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Mutation Controls

    private var mutationControls: some View {
        let mutation = node?.sequence.mutation
        let amount = mutation?.amount ?? 0
        let range = mutation?.range ?? 1

        return VStack(alignment: .leading, spacing: 4) {
            Text("MUTATION")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            HStack(spacing: 6) {
                Text("Amt")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                Slider(value: Binding(
                    get: { amount },
                    set: { setMutationAmount($0) }
                ), in: 0...1)
                .frame(width: 80)

                Text("\(Int(amount * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("Rng")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                Stepper("\(range)", value: Binding(
                    get: { range },
                    set: { setMutationRange($0) }
                ), in: 1...7)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .scaleEffect(0.8)

                Spacer()

                // Freeze / Reset buttons
                Button(action: { freezeMutation() }) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 10))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Freeze mutations")

                Button(action: { resetMutation() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
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

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ACCUMULATOR")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                Spacer()

                Button(action: { toggleAccumulator() }) {
                    Image(systemName: enabled ? "checkmark.square" : "square")
                        .font(.system(size: 10))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            if enabled {
                // Target picker
                HStack(spacing: 4) {
                    ForEach(AccumulatorTarget.allCases, id: \.self) { t in
                        let isSelected = target == t
                        Button(action: { setAccumulatorTarget(t) }) {
                            Text(t.rawValue)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Amt")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    Slider(value: Binding(
                        get: { amount },
                        set: { setAccumulatorAmount($0) }
                    ), in: -12...12)
                    .frame(width: 80)
                    Text(String(format: "%.1f", amount))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text("Lim")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    Slider(value: Binding(
                        get: { limit },
                        set: { setAccumulatorLimit($0) }
                    ), in: 1...48)
                    .frame(width: 80)
                    Text(String(format: "%.0f", limit))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28, alignment: .trailing)
                }

                // Mode picker
                HStack(spacing: 4) {
                    ForEach(AccumulatorMode.allCases, id: \.self) { m in
                        let isSelected = mode == m
                        Button(action: { setAccumulatorMode(m) }) {
                            Text(m.rawValue)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
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

    // MARK: - Playhead

    private func playheadOverlay(lengthInBeats: Double) -> some View {
        let beatFraction = transportState.currentBeat / max(lengthInBeats, 1)
        let step = beatFraction * Double(columns)
        let xOffset = CGFloat(step) * (cellSize + cellSpacing)
        let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing

        return RoundedRectangle(cornerRadius: 3)
            .fill(CanopyColors.glowColor.opacity(0.2))
            .frame(width: cellSize, height: gridHeight)
            .offset(x: xOffset, y: 0)
            .allowsHitTesting(false)
    }

    // MARK: - Length Change

    private func changeLength(to newLength: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { $0.startBeat >= Double(newLength) }
            node.sequence.lengthInBeats = Double(newLength)
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

    private func findNote(in sequence: NoteSequence, pitch: Int, step: Int) -> NoteEvent? {
        let stepBeat = Double(step)
        return sequence.notes.first { event in
            event.pitch == pitch && abs(event.startBeat - stepBeat) < 0.01
        }
    }

    private func hasNote(in sequence: NoteSequence, pitch: Int, step: Int) -> Bool {
        findNote(in: sequence, pitch: pitch, step: step) != nil
    }

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let stepBeat = Double(step)

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
                    duration: 1.0
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
