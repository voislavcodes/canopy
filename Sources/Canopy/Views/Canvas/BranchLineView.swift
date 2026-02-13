import SwiftUI

/// Renders lines connecting parent nodes to their children in canvas space.
/// Uses quadratic bezier curves for organic-looking branch connections.
struct BranchLineView: View {
    let nodes: [Node]

    var body: some View {
        Canvas { context, _ in
            for node in nodes {
                for child in node.children {
                    drawBranch(context: context, from: node.position, to: child.position)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drawBranch(context: GraphicsContext, from parent: NodePosition, to child: NodePosition) {
        var path = Path()
        let start = CGPoint(x: parent.x, y: parent.y + 22) // Below parent circle
        let end = CGPoint(x: child.x, y: child.y - 28)     // Above child label

        let midY = (start.y + end.y) / 2
        let control1 = CGPoint(x: start.x, y: midY)
        let control2 = CGPoint(x: end.x, y: midY)

        path.move(to: start)
        path.addCurve(to: end, control1: control1, control2: control2)

        context.stroke(
            path,
            with: .color(CanopyColors.branchLine),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }
}
