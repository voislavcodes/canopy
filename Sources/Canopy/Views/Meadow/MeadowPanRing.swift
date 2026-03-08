import AppKit
import SwiftUI

/// Outer ring: pan dot + pan arc. Handles all drag gestures (volume + pan).
/// Shows node name + value transiently during drag.
/// Radius = MeadowMetrics.outerRingRadius (86pt).
struct MeadowPanRing: View {
    let volume: Double
    let pan: Double
    let color: Color
    let onVolumeChange: (Double) -> Void
    let onPanChange: (Double) -> Void
    let onSelect: () -> Void

    @State private var isDragging = false
    @State private var dragStartVolume: Double = 0
    @State private var dragStartPan: Double = 0

    private let radius = MeadowMetrics.outerRingRadius

    /// Pan range: +/-135 degrees from top.
    private let panRangeDeg: Double = 135.0

    var body: some View {
        ZStack {
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
                context.stroke(ringPath, with: .color(color.opacity(0.2)), lineWidth: 1)

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
                context.stroke(centerTick, with: .color(color.opacity(0.4)), lineWidth: 1)

                // 3. Pan arc (from center tick to pan dot)
                let panAngle = panToAngle(pan)
                if abs(pan) > 0.01 {
                    var arcPath = Path()
                    let startAngle = Angle.radians(-.pi / 2.0)
                    let endAngle = Angle.radians(panAngle)
                    let clockwise = pan < 0
                    arcPath.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
                    context.stroke(arcPath, with: .color(color.opacity(0.2)), lineWidth: MeadowMetrics.panArcWidth)
                }

                // 4. Pan dot
                let dotCenter = CGPoint(
                    x: center.x + cos(panAngle) * Double(r),
                    y: center.y + sin(panAngle) * Double(r)
                )
                let dotR = MeadowMetrics.panDotRadius
                let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(color))
                context.stroke(Path(ellipseIn: dotRect), with: .color(Color.black.opacity(0.5)), lineWidth: 0.8)
            }
            .frame(width: radius * 2 + 24, height: radius * 2 + 24)

        }
        .gesture(unifiedDragGesture)
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.command) {
                onPanChange(0)
            } else {
                onVolumeChange(1.0)
            }
        }
    }

    private var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartVolume = volume
                    dragStartPan = pan
                    onSelect()
                }
                if NSEvent.modifierFlags.contains(.command) {
                    let newPan = dragStartPan - value.translation.height / 200.0
                    onPanChange(max(-1, min(1, newPan)))
                } else {
                    let newVol = dragStartVolume - value.translation.height / 200.0
                    onVolumeChange(max(0, min(1, newVol)))
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
