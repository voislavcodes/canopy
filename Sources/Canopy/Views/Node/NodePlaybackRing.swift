import SwiftUI

/// Outer ring around a node showing beat division ticks and an animated playhead dot.
/// Wraps its own TimelineView so NodeView doesn't need to manage polling.
struct NodePlaybackRing: View {
    let nodeID: UUID
    let lengthInBeats: Double
    let color: Color
    let isPlaying: Bool
    let isSelected: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let ringRadius = NodeMetrics.ringRadius
                let tickLen = NodeMetrics.tickLength
                let ticks = max(1, Int(lengthInBeats))

                // 1. Outer ring stroke
                let ringColor: Color
                if isSelected && isPlaying {
                    ringColor = color.opacity(0.7)
                } else if isPlaying {
                    ringColor = color.opacity(0.5)
                } else {
                    ringColor = CanopyColors.branchLine.opacity(0.4)
                }

                let ringPath = Path(ellipseIn: CGRect(
                    x: center.x - ringRadius,
                    y: center.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
                context.stroke(ringPath, with: .color(ringColor), lineWidth: 1.5)

                // 2. Beat division ticks
                let tickColor = color.opacity(0.2)
                for i in 0..<ticks {
                    let angle = (Double(i) / Double(ticks)) * 2.0 * .pi - .pi / 2.0
                    let outerX = center.x + cos(angle) * ringRadius
                    let outerY = center.y + sin(angle) * ringRadius
                    let innerX = center.x + cos(angle) * (ringRadius - tickLen)
                    let innerY = center.y + sin(angle) * (ringRadius - tickLen)

                    var tickPath = Path()
                    tickPath.move(to: CGPoint(x: innerX, y: innerY))
                    tickPath.addLine(to: CGPoint(x: outerX, y: outerY))
                    context.stroke(tickPath, with: .color(tickColor), lineWidth: 1.0)
                }

                // 3. Playhead dot (only when playing)
                if isPlaying {
                    let currentBeat = AudioEngine.shared.currentBeat(for: nodeID)
                    let progress = lengthInBeats > 0
                        ? currentBeat.truncatingRemainder(dividingBy: lengthInBeats) / lengthInBeats
                        : 0
                    let angle = progress * 2.0 * .pi - .pi / 2.0
                    let dotX = center.x + cos(angle) * ringRadius
                    let dotY = center.y + sin(angle) * ringRadius
                    let dotR = NodeMetrics.playheadDotRadius

                    let dotRect = CGRect(
                        x: dotX - dotR, y: dotY - dotR,
                        width: dotR * 2, height: dotR * 2
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(color))
                }
            }
            .frame(width: NodeMetrics.ringRadius * 2 + NodeMetrics.playheadDotRadius * 2 + 4,
                   height: NodeMetrics.ringRadius * 2 + NodeMetrics.playheadDotRadius * 2 + 4)
        }
    }
}
