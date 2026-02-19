import SwiftUI

/// 2×4 drum pad grid for real-time drum input.
/// Bottom row: KICK/SNARE/CHH/OHH, top row: TML/TMH/CRS/RDE.
struct DrumPadGridView: View {
    @Environment(\.canvasScale) var cs
    var selectedNodeID: UUID?
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    @State private var pressedPads: Set<Int> = []

    private let padNames = FMDrumKit.voiceNames
    private let midiPitches = FMDrumKit.midiPitches

    /// Grid layout: 2 rows × 4 columns.
    /// Top row: indices 4,5,6,7 (TOM L, TOM H, CRASH, RIDE)
    /// Bottom row: indices 0,1,2,3 (KICK, SNARE, C.HAT, O.HAT)
    private let rows: [[Int]] = [
        [4, 5, 6, 7],
        [0, 1, 2, 3],
    ]

    private var padSize: CGFloat { 60 * cs }
    private var padSpacing: CGFloat { 6 * cs }

    var body: some View {
        VStack(spacing: padSpacing) {
            HStack(spacing: 4 * cs) {
                ModuleSwapButton(
                    options: [("Keyboard", InputMode.keyboard), ("Pads", InputMode.padGrid)],
                    current: projectState.selectedNode?.inputMode ?? .padGrid,
                    onChange: { mode in
                        guard let nodeID = selectedNodeID else { return }
                        projectState.swapInput(nodeID: nodeID, to: mode)
                    }
                )
                Spacer()
            }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: padSpacing) {
                    ForEach(row, id: \.self) { index in
                        drumPad(index: index)
                    }
                }
            }

            if selectedNodeID != nil {
                captureControlsView
            }
        }
        .padding(.top, 36 * cs)
        .padding(.horizontal, 12 * cs)
        .padding(.bottom, 10 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Pad

    private func drumPad(index: Int) -> some View {
        let isPressed = pressedPads.contains(index)
        let pitch = midiPitches[index]
        let drumColor = CanopyColors.nodeRhythmic

        return VStack(spacing: 2 * cs) {
            RoundedRectangle(cornerRadius: 6 * cs)
                .fill(isPressed ? drumColor.opacity(0.5) : drumColor.opacity(0.12))
                .frame(width: padSize, height: padSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 6 * cs)
                        .stroke(isPressed ? drumColor.opacity(0.9) : drumColor.opacity(0.3), lineWidth: isPressed ? 2 : 1)
                )
                .shadow(color: isPressed ? drumColor.opacity(0.4) : .clear, radius: 8)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !pressedPads.contains(index) {
                                pressedPads.insert(index)
                                if let nodeID = selectedNodeID {
                                    AudioEngine.shared.noteOn(pitch: pitch, velocity: 0.8, nodeID: nodeID)
                                }
                                let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
                                projectState.captureBuffer.noteOn(pitch: pitch, velocity: 0.8, atBeat: beat)
                            }
                        }
                        .onEnded { _ in
                            pressedPads.remove(index)
                            if let nodeID = selectedNodeID {
                                AudioEngine.shared.noteOff(pitch: pitch, nodeID: nodeID)
                            }
                            let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
                            projectState.captureBuffer.noteOff(pitch: pitch, atBeat: beat)
                        }
                )

            Text(padNames[index])
                .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
        }
    }

    // MARK: - Capture Controls

    private var captureControlsView: some View {
        let hasContent = !projectState.captureBuffer.isEmpty

        return HStack(spacing: 8) {
            Button(action: {
                if projectState.capturePerformance() {
                    reloadSequenceAfterCapture()
                }
            }) {
                Circle()
                    .fill(hasContent
                          ? Color(red: 0.7, green: 0.2, blue: 0.2)
                          : Color(red: 0.3, green: 0.3, blue: 0.3))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Text("Q")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Slider(value: $projectState.captureQuantizeStrength, in: 0...1)
                .frame(width: 60)
                .tint(CanopyColors.nodeRhythmic)

            Text("\(Int(projectState.captureQuantizeStrength * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 28, alignment: .trailing)

            HStack(spacing: 2) {
                modeButton(label: "R", mode: .replace)
                modeButton(label: "M", mode: .merge)
            }
        }
    }

    private func modeButton(label: String, mode: CaptureMode) -> some View {
        let isActive = projectState.captureMode == mode
        return Button(action: { projectState.captureMode = mode }) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? Color.white : CanopyColors.chromeText.opacity(0.4))
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive
                              ? CanopyColors.nodeRhythmic.opacity(0.5)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func reloadSequenceAfterCapture() {
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
        let key = node.scaleOverride ?? node.key
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
}
