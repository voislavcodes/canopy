import SwiftUI

/// Catch popup — duration selector, waveform preview, and catch/cancel buttons.
struct CatchPopoverView: View {
    @ObservedObject var catchState: CatchState
    @EnvironmentObject var projectState: ProjectState

    private let durations: [(String, Double)] = [
        ("10s", 10), ("30s", 30), ("60s", 60), ("90s", 90)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("CATCH")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            if catchState.isEmpty {
                // Empty state
                Text("Nothing to catch — play some sounds first.")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                // Duration pills
                HStack(spacing: 4) {
                    ForEach(durations, id: \.1) { label, duration in
                        durationPill(label: label, duration: duration)
                    }
                }

                // Waveform preview
                waveformView
                    .frame(height: 40)

                // Quiet warning
                if catchState.isVeryQuiet {
                    Text("Captured audio is very quiet.")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }

                // Action buttons
                HStack(spacing: 8) {
                    // Preview button
                    Button(action: { catchState.togglePreview() }) {
                        HStack(spacing: 4) {
                            Image(systemName: catchState.isPreviewing ? "stop.fill" : "play.fill")
                                .font(.system(size: 9))
                            Text(catchState.isPreviewing ? "Stop" : "Preview")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(CanopyColors.chromeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Cancel
                    Button(action: { catchState.dismiss() }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)

                    // Catch button
                    Button(action: { catchState.catchAndSave(projectState: projectState) }) {
                        HStack(spacing: 4) {
                            Text("🦋")
                                .font(.system(size: 11))
                            Text("Catch")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(CanopyColors.glowColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(CanopyColors.glowColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(CanopyColors.glowColor.opacity(0.4), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(catchState.isSaving)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(CanopyColors.bloomPanelBackground)
        .onChange(of: catchState.selectedDuration) { _ in
            catchState.showPopover = true // regenerate waveform on duration change
        }
    }

    // MARK: - Duration Pill

    private func durationPill(label: String, duration: Double) -> some View {
        let isSelected = catchState.selectedDuration == duration
        return Button(action: { catchState.selectedDuration = duration }) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isSelected ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.chromeBorder.opacity(0.2),
                            lineWidth: 0.5
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Waveform View

    private var waveformView: some View {
        Canvas { context, size in
            let preview = catchState.waveformPreview
            guard !preview.isEmpty else { return }

            let barWidth = size.width / CGFloat(preview.count)
            let midY = size.height / 2

            for (i, amplitude) in preview.enumerated() {
                let barHeight = CGFloat(amplitude) * size.height * 0.9
                let x = CGFloat(i) * barWidth
                let rect = CGRect(
                    x: x,
                    y: midY - barHeight / 2,
                    width: max(1, barWidth - 1),
                    height: max(1, barHeight)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(CanopyColors.glowColor.opacity(0.6))
                )
            }
        }
        .background(CanopyColors.chromeBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
