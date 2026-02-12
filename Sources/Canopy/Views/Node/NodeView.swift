import SwiftUI

struct NodeView: View {
    let node: Node
    let isSelected: Bool

    private let nodeRadius: CGFloat = 22

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if isSelected {
                    NodeGlowEffect(radius: nodeRadius)
                }

                // Node fill — bright green circle
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                CanopyColors.nodeFill,
                                CanopyColors.nodeFill.opacity(0.8),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: nodeRadius
                        )
                    )
                    .frame(width: nodeRadius * 2, height: nodeRadius * 2)
            }

            // Label below node
            Text(node.name.lowercased())
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.nodeLabel)
        }
        .position(x: node.position.x, y: node.position.y)
    }
}
