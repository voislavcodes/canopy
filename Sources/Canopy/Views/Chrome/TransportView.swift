import SwiftUI

/// Transport controls: play/stop buttons and editable BPM field.
/// BPM supports click-to-edit and vertical drag-to-adjust (Ableton-style).
///
/// During BPM drag, uses local @State to avoid broadcasting every pixel
/// through @Published. Pushes tempo to AudioEngine directly during drag,
/// commits to TransportState once on drag end.
struct TransportView: View {
    @ObservedObject var transportState: TransportState

    @State private var isEditingBPM = false
    @State private var bpmText = ""
    @State private var dragStartBPM: Double = 0
    @State private var isDragging = false
    @State private var localBPM: Double = 120

    var body: some View {
        HStack(spacing: 12) {
            // Play/Stop toggle
            Button(action: { transportState.togglePlayback() }) {
                Image(systemName: transportState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(transportState.isPlaying ? CanopyColors.glowColor : CanopyColors.transportIcon)
            }
            .buttonStyle(.plain)

            Button(action: { transportState.stopPlayback() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CanopyColors.transportIcon)
            }
            .buttonStyle(.plain)

            // BPM field
            bpmField
        }
        .onAppear { localBPM = transportState.bpm }
        .onChange(of: transportState.bpm) { newBPM in
            if !isDragging {
                localBPM = newBPM
            }
        }
    }

    private var displayBPM: Double {
        isDragging ? localBPM : transportState.bpm
    }

    private var bpmField: some View {
        Group {
            if isEditingBPM {
                TextField("BPM", text: $bpmText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        commitBPM()
                    }
                    .onExitCommand {
                        isEditingBPM = false
                    }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(displayBPM))")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(isDragging ? CanopyColors.glowColor : CanopyColors.chromeTextBright)
                        .frame(minWidth: 40)
                    Text("BPM")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isDragging ? CanopyColors.glowColor.opacity(0.08) : CanopyColors.chromeBackground.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isDragging ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditingBPM {
                bpmText = "\(Int(displayBPM))"
                isEditingBPM = true
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartBPM = transportState.bpm
                    }
                    // Drag up = faster, drag down = slower
                    // 1 point = 0.5 BPM for fine control
                    let delta = -value.translation.height * 0.5
                    localBPM = max(20, min(300, dragStartBPM + delta))
                    // Push directly to audio engine (no @Published mutation)
                    AudioEngine.shared.setAllSequencersBPM(localBPM)
                }
                .onEnded { _ in
                    isDragging = false
                    // Commit once to TransportState
                    transportState.updateBPM(localBPM)
                }
        )
    }

    private func commitBPM() {
        if let val = Double(bpmText) {
            transportState.updateBPM(val)
            localBPM = max(20, min(300, val))
        }
        isEditingBPM = false
    }
}
