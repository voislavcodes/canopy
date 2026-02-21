import SwiftUI

/// Reusable IMPRINT button used in FLOW, TIDE, and SWARM panels.
/// States: idle (mic icon) → recording (pulsing, waveform) → analysing (spinner) → imprinted (accent, tap to clear).
struct ImprintButton: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var recorder: ImprintRecorder
    let accentColor: Color
    let onImprint: (SpectralImprint) -> Void
    let onClear: () -> Void

    /// Whether the node already has a saved imprint (for showing imprinted state on load).
    var hasImprint: Bool = false

    var body: some View {
        switch recorder.state {
        case .idle:
            if hasImprint {
                imprintedButton
            } else {
                idleButton
            }
        case .recording(let progress):
            recordingButton(progress: progress)
        case .analysing:
            analysingButton
        case .imprinted(let imprint):
            imprintedButton
                .onAppear { onImprint(imprint) }
        }
    }

    // MARK: - States

    private var idleButton: some View {
        Button(action: { recorder.startRecording() }) {
            HStack(spacing: 3 * cs) {
                Image(systemName: "mic")
                    .font(.system(size: 9 * cs, weight: .medium))
                Text("IMPRINT")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
            }
            .foregroundColor(CanopyColors.chromeText.opacity(0.6))
            .padding(.horizontal, 8 * cs)
            .padding(.vertical, 3 * cs)
            .background(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func recordingButton(progress: Float) -> some View {
        Button(action: { recorder.stopRecording() }) {
            HStack(spacing: 3 * cs) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6 * cs, height: 6 * cs)
                    .opacity(pulseOpacity(progress: progress))

                // Mini waveform
                waveformView
                    .frame(width: 40 * cs, height: 12 * cs)

                Text("\(Int(progress * 100))%")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.red.opacity(0.8))
            }
            .padding(.horizontal, 8 * cs)
            .padding(.vertical, 3 * cs)
            .background(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .stroke(Color.red.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var analysingButton: some View {
        HStack(spacing: 4 * cs) {
            ProgressView()
                .scaleEffect(0.5 * cs)
                .frame(width: 10 * cs, height: 10 * cs)
            Text("ANALYSING")
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(accentColor.opacity(0.7))
        }
        .padding(.horizontal, 8 * cs)
        .padding(.vertical, 3 * cs)
        .background(
            RoundedRectangle(cornerRadius: 4 * cs)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4 * cs)
                .stroke(accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var imprintedButton: some View {
        Button(action: {
            recorder.clear()
            onClear()
        }) {
            HStack(spacing: 3 * cs) {
                Image(systemName: "waveform")
                    .font(.system(size: 9 * cs, weight: .medium))
                Text("IMPRINTED")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                Image(systemName: "xmark")
                    .font(.system(size: 7 * cs, weight: .bold))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
            .foregroundColor(accentColor)
            .padding(.horizontal, 8 * cs)
            .padding(.vertical, 3 * cs)
            .background(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .fill(accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4 * cs)
                    .stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Waveform Preview

    private var waveformView: some View {
        Canvas { context, size in
            let samples = recorder.waveformSamples
            guard !samples.isEmpty else { return }
            let w = size.width
            let h = size.height
            let midY = h / 2
            let step = max(1, samples.count / Int(w))

            var path = Path()
            for x in 0..<Int(w) {
                let idx = min(x * step, samples.count - 1)
                let amp = CGFloat(samples[idx])
                let y = midY - amp * midY * 0.9
                if x == 0 {
                    path.move(to: CGPoint(x: CGFloat(x), y: y))
                } else {
                    path.addLine(to: CGPoint(x: CGFloat(x), y: y))
                }
            }
            context.stroke(path, with: .color(Color.red.opacity(0.7)), lineWidth: 1)
        }
    }

    // MARK: - Pulse

    private func pulseOpacity(progress: Float) -> Double {
        let t = Double(progress) * 8.0
        return 0.5 + 0.5 * sin(t * .pi * 2)
    }
}
