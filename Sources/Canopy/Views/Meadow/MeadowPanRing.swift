import AppKit
import SwiftUI

/// Outer ring: pan dot + pan arc + L/R labels. Handles all drag gestures (volume + pan).
/// Radius = MeadowMetrics.outerRingRadius (86pt).
struct MeadowPanRing: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    @State private var isDragging = false
    @State private var dragStartVolume: Double = 0
    @State private var dragStartPan: Double = 0

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
        .gesture(unifiedDragGesture)
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.command) {
                projectState.setTreePan(tree.id, pan: 0)
            } else {
                projectState.setTreeVolume(tree.id, volume: 1.0)
            }
        }
    }

    private var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartVolume = tree.volume
                    dragStartPan = tree.pan
                    projectState.selectTree(tree.id)
                }
                if NSEvent.modifierFlags.contains(.command) {
                    // CMD + drag → pan (vertical: up = right, down = left)
                    let pan = dragStartPan - value.translation.height / 200.0
                    projectState.setTreePan(tree.id, pan: max(-1, min(1, pan)))
                } else {
                    // Plain drag → volume (vertical: up = louder)
                    let vol = dragStartVolume - value.translation.height / 200.0
                    projectState.setTreeVolume(tree.id, volume: max(0, min(1, vol)))
                }
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    /// Map pan (-1...+1) to angle. 0 = top, +1 = 135deg clockwise, -1 = 135deg counterclockwise.
    private func panToAngle(_ pan: Double) -> Double {
        pan * (panRangeDeg * .pi / 180.0) - .pi / 2.0
    }
}
