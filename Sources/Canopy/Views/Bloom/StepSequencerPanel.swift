import SwiftUI

/// Bloom panel: step sequencer grid.
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
        // Solve: columns * (cell + spacing) - spacing = maxGridWidth
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

            if let node {
                ZStack(alignment: .topLeading) {
                    gridView(sequence: node.sequence)

                    if transportState.isPlaying {
                        playheadOverlay(lengthInBeats: node.sequence.lengthInBeats)
                    }
                }
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

    // MARK: - Grid

    private func gridView(sequence: NoteSequence) -> some View {
        VStack(spacing: cellSpacing) {
            ForEach((0..<rows).reversed(), id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        let pitch = baseNote + row
                        let isActive = hasNote(in: sequence, pitch: pitch, step: col)
                        stepCell(pitch: pitch, step: col, isActive: isActive)
                    }
                }
            }
        }
    }

    private func stepCell(pitch: Int, step: Int, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(isActive ? CanopyColors.gridCellActive : CanopyColors.gridCellInactive)
            .frame(width: cellSize, height: cellSize)
            .onTapGesture {
                toggleNote(pitch: pitch, step: step)
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
            // Remove notes that fall outside the new length
            node.sequence.notes.removeAll { $0.startBeat >= Double(newLength) }
            node.sequence.lengthInBeats = Double(newLength)
        }
        reloadSequence()
    }

    // MARK: - Note Logic

    private func hasNote(in sequence: NoteSequence, pitch: Int, step: Int) -> Bool {
        let stepBeat = Double(step)
        return sequence.notes.contains { event in
            event.pitch == pitch && abs(event.startBeat - stepBeat) < 0.01
        }
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
        }

        reloadSequence()
    }

    private func reloadSequence() {
        guard let node = projectState.selectedNode,
              let nodeID = projectState.selectedNodeID else { return }
        let events = node.sequence.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration
            )
        }
        AudioEngine.shared.loadSequence(events, lengthInBeats: node.sequence.lengthInBeats, nodeID: nodeID)
    }
}
