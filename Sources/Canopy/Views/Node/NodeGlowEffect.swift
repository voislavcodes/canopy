import SwiftUI

/// Concentric ring glow around a selected node.
/// Two thin rings at increasing radii + subtle soft glow.
struct NodeGlowEffect: View {
    var radius: CGFloat = 22
    var color: Color = CanopyColors.glowColor

    @State private var pulse: CGFloat = 0.85

    var body: some View {
        ZStack {
            // Soft outer glow
            Circle()
                .fill(color.opacity(0.06 * Double(pulse)))
                .frame(width: radius * 4.5, height: radius * 4.5)
                .blur(radius: 15)

            // Outer ring
            Circle()
                .stroke(color.opacity(0.4 * Double(pulse)), lineWidth: 1)
                .frame(width: radius * 3.6, height: radius * 3.6)

            // Inner ring
            Circle()
                .stroke(color.opacity(0.7 * Double(pulse)), lineWidth: 1.5)
                .frame(width: radius * 2.8, height: radius * 2.8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}
