import SwiftUI

struct NodeGlowEffect: View {
    var color: Color = CanopyColors.glowColor
    var radius: CGFloat = 40

    @State private var pulse: CGFloat = 0.8

    var body: some View {
        ZStack {
            // Outer soft glow
            Circle()
                .fill(color.opacity(0.15 * Double(pulse)))
                .frame(width: radius * 3, height: radius * 3)
                .blur(radius: 20)

            // Mid glow
            Circle()
                .fill(color.opacity(0.25 * Double(pulse)))
                .frame(width: radius * 2.2, height: radius * 2.2)
                .blur(radius: 10)

            // Inner crisp ring
            Circle()
                .stroke(color.opacity(0.6 * Double(pulse)), lineWidth: 2.5)
                .frame(width: radius * 2 + 6, height: radius * 2 + 6)
                .blur(radius: 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
        }
    }
}
