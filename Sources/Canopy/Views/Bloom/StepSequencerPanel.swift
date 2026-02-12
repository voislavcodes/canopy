import SwiftUI

/// Right bloom panel: step sequencer grid (16 columns x 24 rows = 2 octaves).
/// Derives boolean grid state directly from the selected node's NoteSequence.
/// Click toggles NoteEvents. Playhead overlay tracks transport currentBeat.
struct StepSequencerPanel: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState

    private let columns = 16
    private let rows = 24       // 2 octaves (C3–B4)
    private let baseNote = 48   // C3
    private let cellSize: CGFloat = 18
    private let cellSpacing: CGFloat = 1

    private var node: Node? {
        projectState.selectedNode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SEQUENCER")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)

            if let node {
                ZStack(alignment: .topLeading) {
                    // Grid
                    gridView(sequence: node.sequence)

                    // Playhead overlay
                    if transportState.isPlaying {
                        playheadOverlay(lengthInBeats: node.sequence.lengthInBeats)
                    }
                }
            } else {
                Text("Select a node")
                    .font(.system(size: 12))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }

            Spacer()
        }
        .padding(12)
        .frame(width: CGFloat(columns) * (cellSize + cellSpacing) + 56)
        .background(CanopyColors.chromeBackground)
    }

    // MARK: - Grid

    private func gridView(sequence: NoteSequence) -> some View {
        HStack(spacing: 0) {
            // Pitch labels
            VStack(spacing: cellSpacing) {
                ForEach((0..<rows).reversed(), id: \.self) { row in
                    let note = baseNote + row
                    Text(MIDIUtilities.noteName(forNote: note))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 28, height: cellSize)
                }
            }

            // Step cells
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
    }

    private func stepCell(pitch: Int, step: Int, isActive: Bool) -> some View {
        let isBeatBoundary = step % 4 == 0
        return Rectangle()
            .fill(cellColor(isActive: isActive, isBeat: isBeatBoundary))
            .frame(width: cellSize, height: cellSize)
            .cornerRadius(2)
            .onTapGesture {
                toggleNote(pitch: pitch, step: step)
            }
    }

    private func cellColor(isActive: Bool, isBeat: Bool) -> Color {
        if isActive {
            return CanopyColors.glowColor.opacity(0.8)
        }
        return isBeat
            ? Color(red: 0.15, green: 0.15, blue: 0.2)
            : Color(red: 0.1, green: 0.1, blue: 0.14)
    }

    // MARK: - Playhead

    private func playheadOverlay(lengthInBeats: Double) -> some View {
        let beatFraction = transportState.currentBeat / lengthInBeats
        let step = beatFraction * Double(columns)
        let xOffset: CGFloat = 28 + CGFloat(step) * (cellSize + cellSpacing)
        let gridHeight = CGFloat(rows) * (cellSize + cellSpacing) - cellSpacing

        return Rectangle()
            .fill(CanopyColors.glowColor.opacity(0.3))
            .frame(width: cellSize, height: gridHeight)
            .offset(x: xOffset, y: 0)
            .allowsHitTesting(false)
    }

    // MARK: - Note Logic

    /// Check if there's a NoteEvent at the given pitch and step.
    private func hasNote(in sequence: NoteSequence, pitch: Int, step: Int) -> Bool {
        let stepBeat = Double(step)
        return sequence.notes.contains { event in
            event.pitch == pitch && abs(event.startBeat - stepBeat) < 0.01
        }
    }

    /// Toggle a note at the given pitch and step.
    private func toggleNote(pitch: Int, step: Int) {
        guard let nodeID = projectState.selectedNodeID else { return }
        let stepBeat = Double(step)

        projectState.updateNode(id: nodeID) { node in
            if let existingIndex = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && abs($0.startBeat - stepBeat) < 0.01
            }) {
                // Remove existing note
                node.sequence.notes.remove(at: existingIndex)
            } else {
                // Add new note
                let event = NoteEvent(
                    pitch: pitch,
                    velocity: 0.8,
                    startBeat: stepBeat,
                    duration: 1.0
                )
                node.sequence.notes.append(event)
            }
        }

        // Reload sequence into audio engine
        reloadSequence()
    }

    /// Convert NoteSequence to SequencerEvents and load into the audio engine.
    private func reloadSequence() {
        guard let node = projectState.selectedNode else { return }
        let events = node.sequence.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration
            )
        }
        AudioEngine.shared.loadSequence(events, lengthInBeats: node.sequence.lengthInBeats)
    }
}
