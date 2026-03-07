import SwiftUI

/// Outer ring: pan dot + pan arc + L/R labels.
/// Radius = MeadowMetrics.outerRingRadius (68pt).
struct MeadowPanRing: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    @State private var isDragging = false

    private var treeColor: Color { tree.driftedColor }
    private let radius = MeadowMetrics.outerRingRadius

    /// Pan range: +/-135 degrees from top.
    private let panRangeDeg: Double = 135.0

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = radius

            // 1. Ring stroke
            let ringPath = Path { p in
                p.addEllipse(in: CGRect(
                    x: center.x - r, y: center.y - r,
                    width: r * 2, height: r * 2
                ))
            }
            context.stroke(ringPath, with: .color(treeColor.opacity(0.2)), lineWidth: 1)

            // 2. Center tick at 12 o'clock
            let topAngle = -.pi / 2.0
            var centerTick = Path()
            centerTick.move(to: CGPoint(
                x: center.x + cos(topAngle) * Double(r - 4),
                y: center.y + sin(topAngle) * Double(r - 4)
            ))
            centerTick.addLine(to: CGPoint(
                x: center.x + cos(topAngle) * Double(r + 4),
                y: center.y + sin(topAngle) * Double(r + 4)
            ))
            context.stroke(centerTick, with: .color(treeColor.opacity(0.4)), lineWidth: 1)

            // 3. L/R labels
            let labelFont = Font.system(size: 9, weight: .regular, design: .monospaced)
            let labelColor = treeColor.opacity(0.25)
            // L at 9 o'clock
            context.draw(
                Text("L").font(labelFont).foregroundColor(labelColor),
                at: CGPoint(x: center.x - Double(r) - 10, y: center.y),
                anchor: .center
            )
            // R at 3 o'clock
            context.draw(
                Text("R").font(labelFont).foregroundColor(labelColor),
                at: CGPoint(x: center.x + Double(r) + 10, y: center.y),
                anchor: .center
            )

            // 4. Pan arc (from center tick to pan dot)
            let panAngle = panToAngle(tree.pan)
            if abs(tree.pan) > 0.01 {
                var arcPath = Path()
                let startAngle = Angle.radians(-.pi / 2.0)
                let endAngle = Angle.radians(panAngle)
                let clockwise = tree.pan < 0
                arcPath.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
                context.stroke(arcPath, with: .color(treeColor.opacity(0.2)), lineWidth: MeadowMetrics.panArcWidth)
            }

            // 5. Pan dot
            let dotCenter = CGPoint(
                x: center.x + cos(panAngle) * Double(r),
                y: center.y + sin(panAngle) * Double(r)
            )
            let dotR = MeadowMetrics.panDotRadius
            let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(treeColor))
            context.stroke(Path(ellipseIn: dotRect), with: .color(Color.black.opacity(0.5)), lineWidth: 0.8)
        }
        .frame(width: radius * 2 + 24, height: radius * 2 + 24)
        .gesture(panDragGesture)
        .onTapGesture(count: 2) {
            projectState.setTreePan(tree.id, pan: 0)
        }
    }

    private var panDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    projectState.selectTree(tree.id)
                }
                let frame = radius * 2 + 24
                let center = CGPoint(x: frame / 2, y: frame / 2)
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                let pan = angleToPan(angle)
                projectState.setTreePan(tree.id, pan: pan)
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    /// Map pan (-1...+1) to angle. 0 = top, +1 = 135deg clockwise, -1 = 135deg counterclockwise.
    private func panToAngle(_ pan: Double) -> Double {
        pan * (panRangeDeg * .pi / 180.0) - .pi / 2.0
    }

    /// Map angle back to pan (-1...+1).
    private func angleToPan(_ angle: Double) -> Double {
        let offset = angle + .pi / 2.0
        let rangeRad = panRangeDeg * .pi / 180.0
        return max(-1, min(1, offset / rangeRad))
    }
}
