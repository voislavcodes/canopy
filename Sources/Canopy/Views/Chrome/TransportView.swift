import SwiftUI

/// Transport controls: play/stop buttons and editable BPM field.
/// Replaces TransportPlaceholder from Phase 1.
struct TransportView: View {
    @ObservedObject var transportState: TransportState

    @State private var isEditingBPM = false
    @State private var bpmText = ""

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

            // BPM editor
            if isEditingBPM {
                TextField("BPM", text: $bpmText, onCommit: {
                    if let val = Double(bpmText) {
                        transportState.updateBPM(val)
                    }
                    isEditingBPM = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .frame(width: 60)
                .multilineTextAlignment(.center)
            } else {
                Text("\(Int(transportState.bpm)) BPM")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)
                    .onTapGesture(count: 2) {
                        bpmText = "\(Int(transportState.bpm))"
                        isEditingBPM = true
                    }
            }
        }
    }
}
