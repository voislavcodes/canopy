import SwiftUI

/// Drum step sequencer grid: rows = 8 drum voices (fixed MIDI pitches), columns = steps.
/// Reuses NoteSequence — each voice row maps to a fixed GM MIDI pitch.
struct DrumSequencerPanel: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @Environment(\.canvasScale) var cs

    private let voiceCount = FMDrumKit.voiceCount
    private let panelWidth: CGFloat = 440

    @State private var showAdvanced = false
    @State private var localProbability: Double = 1.0
    @State private var localMutationAmount: Double = 0.0
    @State private var localAccAmount: Double = 1.0
    @State private var localAccLimit: Double = 12.0

    private var node: Node? { projectState.selectedNode }

    private var columns: Int {
        let beats = node?.sequence.lengthInBeats ?? 4.0
        return max(1, Int(round(beats / NoteSequence.stepDuration)))
    }

    private var displayColumns: Int { 32 }
    private var cellSpacing: CGFloat { 1.5 * cs }
    private var cellCornerRadius: CGFloat { cellSize * 0.25 }

    private var gridAreaWidth: CGFloat {
        (panelWidth - 28 - 50 - 4) * cs // panel - padding - labels - spacing
    }

    private var cellSize: CGFloat {
        let spacing = cellSpacing
        let ideal = (gridAreaWidth + spacing) / CGFloat(displayColumns) - spacing
        return max(6 * cs, floor(ideal))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack(spacing: 6 * cs) {
                Text("DRUMS")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Pitched", SequencerType.pitched), ("Drum", SequencerType.drum), ("Orbit", SequencerType.orbit), ("Spore", SequencerType.sporeSeq)],
                    current: node?.sequencerType ?? .drum,
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        projectState.swapSequencer(nodeID: nodeID, to: type)
                    }
                )

                if node != nil {
                    directionPicker
                }

                Spacer()

                headerControls
            }

            if let node {
                HStack(alignment: .top, spacing: 4 * cs) {
                    // Voice labels (left of grid)
                    voiceLabels

                    // Grid + velocity bars + playhead
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 2 * cs) {
                            gridCanvas(sequence: node.sequence)
                            velocityBars(sequence: node.sequence)
                        }

                        SequencerPlayhead(
                            nodeID: node.id,
                            lengthInBeats: node.sequence.lengthInBeats,
                            columns: columns,
                            rows: voiceCount,
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
        .onAppear { syncFromModel() }
        .onChange(of: projectState.selectedNodeID) { _ in syncFromModel() }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let node else { return }
        localProbability = node.sequence.globalProbability
        localMutationAmount = node.sequence.mutation?.amount ?? 0
        localAccAmount = node.sequence.accumulator?.amount ?? 1.0
        localAccLimit = node.sequence.accumulator?.limit ?? 12.0
    }

    // MARK: - Voice Labels

    private var voiceLabels: some View {
        let names = FMDrumKit.voiceNames
        let gridHeight = CGFloat(voiceCount) * (cellSize + cellSpacing) - cellSpacing
        return VStack(spacing: cellSpacing) {
            ForEach(0..<voiceCount, id: \.self) { i in
                Text(names[i])
                    .font(.system(size: 7 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 46 * cs, height: cellSize, alignment: .trailing)
            }
        }
        .frame(height: gridHeight)
    }

    // MARK: - Grid

    private func noteEventLookup(for sequence: NoteSequence) -> [Int: NoteEvent] {
        var dict = [Int: NoteEvent]()
        dict.reserveCapacity(sequence.notes.count)
        for event in sequence.notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            let key = event.pitch &* 1000 &+ step
            dict[key] = event
        }
        return dict
    }

    private func gridCanvas(sequence: NoteSequence) -> some View {
        let lookup = noteEventLookup(for: sequence)
        let pitches = FMDrumKit.midiPitches
        let cellSz = cellSize
        let spacing = cellSpacing
        let stride = cellSz + spacing
        let cr = cellCornerRadius
        let cols = columns
        let dCols = displayColumns
        let vc = voiceCount
        let gridWidth = CGFloat(dCols) * stride - spacing
        let gridHeight = CGFloat(vc) * stride - spacing

        let drumColor = CanopyColors.nodeRhythmic
        let borderColor = CanopyColors.bloomPanelBorder
        let inactiveColor = CanopyColors.gridCellInactive

        return Canvas { context, size in
            for voiceIndex in 0..<vc {
                let pitch = pitches[voiceIndex]
                let y = CGFloat(voiceIndex) * stride
                for col in 0..<dCols {
                    let enabled = col < cols
                    let dimFactor: Double = enabled ? 1.0 : 0.25
                    let noteEvent = enabled ? lookup[pitch &* 1000 &+ col] : nil
                    let isActive = noteEvent != nil

                    let x = CGFloat(col) * stride
                    let rect = CGRect(x: x, y: y, width: cellSz, height: cellSz)
                    let path = RoundedRectangle(cornerRadius: cr).path(in: rect)

                    let fillColor: Color = isActive
                        ? drumColor.opacity(0.15 * dimFactor)
                        : inactiveColor.opacity(dimFactor)
                    let strokeColor: Color = isActive
                        ? drumColor.opacity(0.8 * dimFactor)
                        : borderColor.opacity(0.3 * dimFactor)
                    let strokeWidth: CGFloat = isActive ? 1.5 : 0.5

                    context.fill(path, with: .color(fillColor))
                    context.stroke(path, with: .color(strokeColor), lineWidth: strokeWidth)
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard abs(value.translation.width) < 5,
                          abs(value.translation.height) < 5 else { return }
                    let loc = value.startLocation
                    let col = Int(loc.x / stride)
                    let voiceIndex = Int(loc.y / stride)
                    guard voiceIndex >= 0, voiceIndex < vc,
                          col >= 0, col < cols else { return }
                    let pitch = pitches[voiceIndex]
                    toggleNote(pitch: pitch, step: col)
                }
        )
    }

    // MARK: - Velocity Bars

    private func velocityBars(sequence: NoteSequence) -> some View {
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
                    .fill(CanopyColors.nodeRhythmic.opacity((maxVel > 0 ? 0.5 : 0.1) * dimFactor))
                    .frame(width: cellSize, height: max(1, maxBarHeight * CGFloat(maxVel)))
            }
        }
        .frame(height: 5 * cs, alignment: .bottom)
    }

    // MARK: - Header Controls

    private var headerControls: some View {
        let euclidean = node?.sequence.euclidean
        let pulses = euclidean?.pulses ?? 4
        let rotation = euclidean?.rotation ?? 0

        return HStack(spacing: 6 * cs) {
            dragValue(label: "S", value: columns, range: 1...32) { changeLength(to: $0) }

            dragValue(
                label: "E", value: pulses, range: 0...columns,
                color: euclidean != nil ? CanopyColors.nodeRhythmic : CanopyColors.chromeText.opacity(0.4)
            ) { applyEuclidean(pulses: $0, rotation: rotation) }

            dragValue(
                label: "R", value: rotation, range: 0...(max(1, columns - 1)),
                color: CanopyColors.chromeText.opacity(0.4)
            ) { applyEuclidean(pulses: pulses, rotation: $0) }
        }
    }

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
                        .foregroundColor(isActive ? CanopyColors.nodeRhythmic : CanopyColors.chromeText.opacity(0.4))
                        .frame(width: 22 * cs, height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isActive ? CanopyColors.nodeRhythmic.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(tooltip)
            }
        }
    }

    // MARK: - Controls

    private var probabilitySlider: some View {
        HStack(spacing: 6 * cs) {
            Text("PROB")
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            seqSlider(value: $localProbability, range: 0...1, onCommit: {
                guard let nodeID = projectState.selectedNodeID else { return }
                projectState.updateNode(id: nodeID) { $0.sequence.globalProbability = localProbability }
                AudioEngine.shared.setGlobalProbability(localProbability, nodeID: nodeID)
            }, onDrag: {
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
                    guard let nodeID = projectState.selectedNodeID else { return }
                    projectState.updateNode(id: nodeID) { node in
                        if node.sequence.mutation == nil {
                            node.sequence.mutation = MutationConfig(amount: localMutationAmount, range: 1)
                        } else {
                            node.sequence.mutation?.amount = localMutationAmount
                        }
                    }
                    reloadSequence()
                }, onDrag: {})
                    .frame(width: 80 * cs)

                Text("\(Int(localMutationAmount * 100))%")
                    .font(.system(size: 9 * cs, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(width: 28 * cs, alignment: .trailing)
            }

            HStack(spacing: 6 * cs) {
                dragValue(label: "Rng", value: range, range: 1...7, color: CanopyColors.chromeText.opacity(0.4)) { newRange in
                    guard let nodeID = projectState.selectedNodeID else { return }
                    projectState.updateNode(id: nodeID) { node in
                        if node.sequence.mutation == nil {
                            node.sequence.mutation = MutationConfig(amount: 0.1, range: newRange)
                        } else {
                            node.sequence.mutation?.range = newRange
                        }
                    }
                    reloadSequence()
                }
                Spacer()
            }
        }
    }

    // MARK: - Drag Value

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
                .background(RoundedRectangle(cornerRadius: 3 * cs).fill(CanopyColors.chromeBackground.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 3 * cs).stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 0.5))
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { drag in
                            let delta = -Int(round(drag.translation.height / dragSensitivity))
                            onChange(max(range.lowerBound, min(range.upperBound, value + delta)))
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
                RoundedRectangle(cornerRadius: 3 * cs).fill(CanopyColors.bloomPanelBorder.opacity(0.3)).frame(height: 8 * cs)
                RoundedRectangle(cornerRadius: 3 * cs).fill(CanopyColors.nodeRhythmic.opacity(0.6)).frame(width: filledWidth, height: 8 * cs)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = max(0, min(1, drag.location.x / width))
                        value.wrappedValue = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                        onDrag()
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 8 * cs)
    }

    // MARK: - Actions

    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let sd = NoteSequence.stepDuration
        let stepBeat = Double(step) * sd

        projectState.updateNode(id: nodeID) { node in
            if let idx = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && Int(round($0.startBeat / sd)) == step
            }) {
                node.sequence.notes.remove(at: idx)
            } else {
                node.sequence.notes.append(NoteEvent(
                    pitch: pitch, velocity: 0.8,
                    startBeat: stepBeat, duration: NoteSequence.stepDuration
                ))
            }
            node.sequence.euclidean = nil
        }
        reloadSequence()
    }

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

    private func setDirection(_ dir: PlaybackDirection) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { $0.sequence.playbackDirection = dir == .forward ? nil : dir }
        reloadSequence()
    }

    private func applyEuclidean(pulses: Int, rotation: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let config = EuclideanConfig(pulses: pulses, rotation: rotation)
        // Use kick pitch for euclidean fill on drum grid
        projectState.updateNode(id: nodeID) { node in
            SequenceFillService.applyEuclidean(
                sequence: &node.sequence,
                config: config,
                key: MusicalKey(root: .C, mode: .chromatic),
                pitchRange: PitchRange(low: 36, high: 36)
            )
        }
        reloadSequence()
    }

    private func reloadSequence() {
        guard let node = projectState.selectedNode,
              let nodeID = projectState.selectedNodeID else { return }
        let seq = node.sequence
        let events = seq.notes.map { event in
            SequencerEvent(
                pitch: event.pitch, velocity: event.velocity,
                startBeat: event.startBeat, endBeat: event.startBeat + event.duration,
                probability: event.probability, ratchetCount: event.ratchetCount
            )
        }
        let key = node.scaleOverride ?? node.key
        AudioEngine.shared.loadSequence(
            events, lengthInBeats: seq.lengthInBeats, nodeID: nodeID,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: seq.mutation?.amount ?? 0,
            mutationRange: seq.mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )
    }
}

// MARK: - Playhead (file-private, same structure as StepSequencerPanel)

private struct SequencerPlayhead: View {
    let nodeID: UUID
    let lengthInBeats: Double
    let columns: Int
    let rows: Int
    let cellSize: CGFloat
    let cellSpacing: CGFloat
    let cellCornerRadius: CGFloat
    let cs: CGFloat

    private static let pollInterval: TimeInterval = 1.0 / 30.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.pollInterval)) { _ in
            let engine = AudioEngine.shared
            let isPlaying = engine.isPlaying(for: nodeID)
            let currentBeat = engine.currentBeat(for: nodeID)
            let beatFraction = currentBeat / max(lengthInBeats, 1)
            let step = beatFraction * Double(columns)
            let xOffset = CGFloat(step) * (cellSize + cellSpacing)
            let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing
            let totalHeight = gridHeight + 2 * cs + 5 * cs

            RoundedRectangle(cornerRadius: cellCornerRadius)
                .fill(CanopyColors.glowColor.opacity(isPlaying ? 0.2 : 0))
                .frame(width: cellSize, height: totalHeight)
                .offset(x: xOffset, y: 0)
                .allowsHitTesting(false)
                .animation(.linear(duration: Self.pollInterval), value: xOffset)
        }
    }
}
