import SwiftUI

/// Concentric ring glow around a selected node.
/// Sized to hug the outer playback ring.
struct NodeGlowEffect: View {
    var radius: CGFloat = NodeMetrics.ringRadius
    var color: Color = CanopyColors.glowColor

    @State private var pulse: CGFloat = 0.85

    var body: some View {
        // Soft diffuse glow only — the playback ring handles the bright ring
        Circle()
            .fill(color.opacity(0.06 * Double(pulse)))
            .frame(width: radius * 2.4, height: radius * 2.4)
            .blur(radius: 15)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}
