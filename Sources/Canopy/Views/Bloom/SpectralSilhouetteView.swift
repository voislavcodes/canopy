import SwiftUI

/// Miniature bar chart showing spectral data from an imprint.
/// Displays either 64 harmonic amplitudes (FLOW/SWARM) or 16 band levels (TIDE).
struct SpectralSilhouetteView: View {
    @Environment(\.canvasScale) var cs
    let values: [Float]
    let accentColor: Color

    var body: some View {
        Canvas { context, size in
            let count = values.count
            guard count > 0 else { return }
            let w = size.width
            let h = size.height
            let barWidth = max(1, w / CGFloat(count))

            for i in 0..<count {
                let amp = CGFloat(max(0, min(1, values[i])))
                let barHeight = amp * h * 0.9
                let x = CGFloat(i) * barWidth
                let y = h - barHeight

                let rect = CGRect(x: x, y: y, width: max(1, barWidth - 0.5), height: barHeight)
                let brightness = 0.3 + amp * 0.7
                context.fill(Path(rect), with: .color(accentColor.opacity(brightness)))
            }
        }
        .frame(height: 20 * cs)
        .background(
            RoundedRectangle(cornerRadius: 3 * cs)
                .fill(Color.black.opacity(0.2))
        )
        .clipShape(RoundedRectangle(cornerRadius: 3 * cs))
    }
}
