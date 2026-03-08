import SwiftUI

/// Subtle dashed lines connecting adjacent tree roots at their ring edges.
/// Each line is a fixed-height rectangle positioned via .offset() to match
/// the same coordinate system the per-tree ZStacks use.
struct TreeConnectorLines: View {
    let trees: [NodeTree]
    let treeOffsets: [CGPoint]

    private let ringEdge = NodeMetrics.ringRadius + NodeMetrics.playheadDotRadius + 4

    var body: some View {
        ForEach(0..<max(0, trees.count - 1), id: \.self) { i in
            let rootA = trees[i].rootNode.position
            let rootB = trees[i + 1].rootNode.position
            let ax = treeOffsets[i].x + rootA.x
            let bx = treeOffsets[i + 1].x + rootB.x
            // The visual ring center is offset above position.y because
            // NodeView's frame includes labels below the ring.
            let ringCenterOffset: CGFloat = -17.5
            let ay = treeOffsets[i].y + rootA.y + ringCenterOffset
            let by = treeOffsets[i + 1].y + rootB.y + ringCenterOffset
            let startX = ax + ringEdge
            let endX = bx - ringEdge
            let midY = (ay + by) / 2
            let lineWidth = endX - startX
            let midX = (startX + endX) / 2

            if lineWidth > 0 {
                DashedLine()
                    .stroke(
                        CanopyColors.branchLine.opacity(0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                    )
                    .frame(width: lineWidth, height: 1)
                    .position(x: midX, y: midY)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A horizontal line shape from leading edge to trailing edge.
struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}
