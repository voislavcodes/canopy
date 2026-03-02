import SwiftUI

/// Concentric ring glow around a selected node.
/// Sized to hug the outer playback ring.
struct NodeGlowEffect: View {
    var radius: CGFloat = NodeMetrics.ringRadius
    var color: Color = CanopyColors.glowColor

    @State private var pulse: CGFloat = 0.85

    var body: some View {
        ZStack {
            // Soft outer glow
            Circle()
                .fill(color.opacity(0.06 * Double(pulse)))
                .frame(width: radius * 2.4, height: radius * 2.4)
                .blur(radius: 15)

            // Bright ring just outside playback ring
            Circle()
                .stroke(color.opacity(0.5 * Double(pulse)), lineWidth: 1.5)
                .frame(width: radius * 2 + 4, height: radius * 2 + 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}
