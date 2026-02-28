import SwiftUI

/// Stereo level meter rendered via Canvas. Two thin vertical bars (L/R)
/// with green→yellow→red gradient based on dB thresholds.
struct LevelMeterView: View {
    var rmsL: Float
    var rmsR: Float
    var peakL: Float
    var peakR: Float

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 4
            let gap: CGFloat = 2
            let totalWidth = barWidth * 2 + gap
            let offsetX = (size.width - totalWidth) / 2
            let height = size.height

            // Draw left channel
            drawBar(context: context,
                    x: offsetX, height: height, barWidth: barWidth,
                    rms: CGFloat(rmsL), peak: CGFloat(peakL))

            // Draw right channel
            drawBar(context: context,
                    x: offsetX + barWidth + gap, height: height, barWidth: barWidth,
                    rms: CGFloat(rmsR), peak: CGFloat(peakR))
        }
    }

    private func drawBar(context: GraphicsContext, x: CGFloat, height: CGFloat,
                          barWidth: CGFloat, rms: CGFloat, peak: CGFloat) {
        // Background track
        let bgRect = CGRect(x: x, y: 0, width: barWidth, height: height)
        context.fill(Path(roundedRect: bgRect, cornerRadius: 1),
                     with: .color(CanopyColors.chromeBorder.opacity(0.2)))

        guard rms > 0 else { return }

        // RMS fill (bottom-up)
        let rmsDb = rms > 0 ? 20.0 * log10(Double(rms)) : -60.0
        let rmsFraction = max(0, min(1, CGFloat((rmsDb + 60.0) / 60.0)))
        let rmsHeight = rmsFraction * height
        let rmsY = height - rmsHeight

        // Color based on level
        let rmsColor = meterColor(db: rmsDb)
        let rmsRect = CGRect(x: x, y: rmsY, width: barWidth, height: rmsHeight)
        context.fill(Path(roundedRect: rmsRect, cornerRadius: 1),
                     with: .color(rmsColor))

        // Peak indicator line
        if peak > 0 {
            let peakDb = 20.0 * log10(Double(peak))
            let peakFraction = max(0, min(1, CGFloat((peakDb + 60.0) / 60.0)))
            let peakY = height - peakFraction * height
            let peakRect = CGRect(x: x, y: peakY, width: barWidth, height: 1)
            context.fill(Path(peakRect), with: .color(meterColor(db: peakDb).opacity(0.8)))
        }
    }

    private func meterColor(db: Double) -> Color {
        if db > -3 { return .red }
        if db > -12 { return .yellow }
        return .green
    }
}

/// Polls AudioEngine for a specific node's meter levels at display rate.
/// Wraps LevelMeterView in a TimelineView so only the meter redraws at 60fps.
struct NodeMeterView: View {
    let nodeID: UUID

    var body: some View {
        TimelineView(.animation) { _ in
            let levels = AudioEngine.shared.nodeMeterLevels(nodeID: nodeID)
            LevelMeterView(
                rmsL: levels.rmsL, rmsR: levels.rmsR,
                peakL: levels.peakL, peakR: levels.peakR
            )
        }
    }
}

/// Polls AudioEngine for master bus meter levels at display rate.
struct MasterMeterView: View {
    var body: some View {
        TimelineView(.animation) { _ in
            let levels = AudioEngine.shared.masterMeterLevels()
            LevelMeterView(
                rmsL: levels.rmsL, rmsR: levels.rmsR,
                peakL: levels.peakL, peakR: levels.peakR
            )
        }
    }
}
