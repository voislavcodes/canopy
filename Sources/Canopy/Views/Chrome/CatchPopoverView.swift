import SwiftUI

/// Catch popup — duration selector, waveform preview, catch/cancel buttons, and catches list.
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

                // Action buttons — single line
                HStack(spacing: 8) {
                    Button(action: { catchState.togglePreview() }) {
                        HStack(spacing: 4) {
                            Image(systemName: catchState.isPreviewing ? "stop.fill" : "play.fill")
                                .font(.system(size: 9))
                            Text(catchState.isPreviewing ? "Stop" : "Preview")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .fixedSize()
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

                    Button(action: { catchState.dismiss() }) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .fixedSize()
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)

                    Button(action: { catchState.catchAndSave(projectState: projectState) }) {
                        HStack(spacing: 4) {
                            CatchButterflyIcon(palette: SeedColor.sessionPalette, size: 14)
                            Text("Catch")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .fixedSize()
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

            // Catches list (if any exist)
            if !projectState.project.catches.isEmpty {
                Divider()
                    .background(CanopyColors.chromeBorder)

                Text("CAUGHT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(projectState.project.catches.reversed()) { loop in
                        catchRow(loop)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(CanopyColors.bloomPanelBackground)
    }

    // MARK: - Duration Pill

    private func durationPill(label: String, duration: Double) -> some View {
        let isSelected = catchState.selectedDuration == duration
        return Button(action: {
            catchState.selectedDuration = duration
            catchState.regenerateWaveform()
        }) {
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

    // MARK: - Catch Row

    private func catchRow(_ loop: HarvestedLoop) -> some View {
        HStack(spacing: 6) {
            CatchButterflyIcon(palette: SeedColor.paletteForCatch(loop.id), size: 12)

            Text(loop.name.lowercased())
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .lineLimit(1)

            Spacer()

            // Duration
            Text(formatDuration(loop.durationSeconds))
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            // Metadata badge
            if loop.isAnalysing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            } else if let meta = loop.metadata {
                metadataBadge(meta)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }

    private func metadataBadge(_ meta: LoopMetadata) -> some View {
        let parts: [String] = [
            meta.detectedKey?.displayName,
            meta.detectedBPM.map { "\(Int($0))" }
        ].compactMap { $0 }

        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m):\(String(format: "%02d", s))"
        }
    }
}
