import SwiftUI

/// Renders lines connecting parent nodes to their children in canvas space.
/// Uses Shape-based rendering so branch lines animate when node positions change.
struct BranchLineView: View {
    let nodes: [Node]

    var body: some View {
        ZStack {
            ForEach(branchPairs, id: \.id) { pair in
                BranchLineShape(from: pair.parentPos, to: pair.childPos)
                    .stroke(pair.lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }

    private var branchPairs: [BranchPair] {
        nodes.flatMap { node in
            node.children.map { child in
                BranchPair(
                    parentID: node.id, childID: child.id,
                    parentPos: node.position, childPos: child.position,
                    childPresetID: child.presetID
                )
            }
        }
    }
}

struct BranchPair: Identifiable {
    let parentID: UUID
    let childID: UUID
    let parentPos: NodePosition
    let childPos: NodePosition
    let childPresetID: String?
    var id: String { "\(parentID)-\(childID)" }

    /// Tint toward child's preset color at low opacity, fall back to default.
    var lineColor: Color {
        if let pid = childPresetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color).opacity(0.4)
        }
        return CanopyColors.branchLine
    }
}

struct BranchLineShape: Shape {
    var from: NodePosition
    var to: NodePosition

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(from.x, from.y), .init(to.x, to.y)) }
        set {
            from = NodePosition(x: Double(newValue.first.first), y: Double(newValue.first.second))
            to = NodePosition(x: Double(newValue.second.first), y: Double(newValue.second.second))
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: from.x, y: from.y - 22)
        let end = CGPoint(x: to.x, y: to.y + 28)
        let midY = (start.y + end.y) / 2
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
        return path
    }
}
