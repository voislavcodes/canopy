import SwiftUI

struct NodeView: View {
    let node: Node
    let isSelected: Bool

    private let nodeRadius: CGFloat = 40

    var body: some View {
        ZStack {
            if isSelected {
                NodeGlowEffect(radius: nodeRadius)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            CanopyColors.nodeFill.opacity(0.9),
                            CanopyColors.nodeFill,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: nodeRadius
                    )
                )
                .frame(width: nodeRadius * 2, height: nodeRadius * 2)

            Circle()
                .stroke(CanopyColors.nodeStroke, lineWidth: 2)
                .frame(width: nodeRadius * 2, height: nodeRadius * 2)

            Text(node.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(CanopyColors.nodeLabel)
        }
        .position(x: node.position.x, y: node.position.y)
    }
}
