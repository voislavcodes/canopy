import SwiftUI

struct NodeView: View {
    let node: Node
    let isSelected: Bool

    private let nodeRadius: CGFloat = 22

    private var nodeColor: Color {
        switch node.type {
        case .seed: return CanopyColors.nodeSeed
        case .melodic: return CanopyColors.nodeMelodic
        case .harmonic: return CanopyColors.nodeHarmonic
        case .rhythmic: return CanopyColors.nodeRhythmic
        case .effect: return CanopyColors.nodeEffect
        case .group: return CanopyColors.nodeGroup
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if isSelected {
                    NodeGlowEffect(radius: nodeRadius)
                }

                // Node fill — color based on type
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                nodeColor,
                                nodeColor.opacity(0.8),
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
        .opacity(node.isMuted ? 0.35 : 1.0)
        .position(x: node.position.x, y: node.position.y)
    }
}
