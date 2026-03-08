import SwiftUI

/// Inner ring: volume dot + loudness arc + beat ticks. Display only — gestures handled by MeadowPanRing.
/// Radius = MeadowMetrics.innerRingRadius (68pt).
struct MeadowVolumeRing: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    @State private var smoothedLevel: Double = 0

    private var treeColor: Color { tree.driftedColor }
    private let radius = MeadowMetrics.innerRingRadius

    var body: some View {
        TimelineView(.animation) { timeline in
            ringCanvas
                .onChange(of: timeline.date) { _ in
                    updateLevel()
                }
        }
        .frame(width: radius * 2 + 20, height: radius * 2 + 20)
        .allowsHitTesting(false)
    }

    private var ringCanvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = radius

            drawRingStroke(context: &context, center: center, r: r)
            drawBeatTicks(context: &context, center: center, r: r)
            drawVolumeArc(context: &context, center: center, r: r)
            drawLoudnessArc(context: &context, center: center, r: r)
            drawVolumeDot(context: &context, center: center, r: r)
        }
    }

    private func drawRingStroke(context: inout GraphicsContext, center: CGPoint, r: CGFloat) {
        let ringPath = Path { p in
            p.addEllipse(in: CGRect(
                x: center.x - r, y: center.y - r,
                width: r * 2, height: r * 2
            ))
        }
        context.stroke(ringPath, with: .color(treeColor.opacity(0.3)), lineWidth: 1.5)
    }

    private func drawBeatTicks(context: inout GraphicsContext, center: CGPoint, r: CGFloat) {
        let beats = Int(tree.rootNode.sequence.lengthInBeats)
        guard beats > 0 else { return }

        for beat in 0..<beats {
            let tickAngle = (Double(beat) / Double(beats)) * 2.0 * .pi - .pi / 2.0
            let isDownbeat = beat % 4 == 0
            let tickLen: CGFloat = isDownbeat ? MeadowMetrics.tickLength + 2 : MeadowMetrics.tickLength
            let tickWidth: CGFloat = isDownbeat ? 1.5 : 0.8
            let innerR = r - tickLen
            let start = CGPoint(
                x: center.x + cos(tickAngle) * Double(innerR),
                y: center.y + sin(tickAngle) * Double(innerR)
            )
            let end = CGPoint(
                x: center.x + cos(tickAngle) * Double(r),
                y: center.y + sin(tickAngle) * Double(r)
            )
            var tickPath = Path()
            tickPath.move(to: start)
            tickPath.addLine(to: end)
            context.stroke(tickPath, with: .color(treeColor.opacity(isDownbeat ? 0.35 : 0.2)), lineWidth: tickWidth)
        }
    }

    private func drawVolumeArc(context: inout GraphicsContext, center: CGPoint, r: CGFloat) {
        guard tree.volume > 0.001 else { return }
        let volAngle = volumeToAngle(tree.volume)
        var arcPath = Path()
        arcPath.addArc(center: center, radius: r, startAngle: .radians(-.pi / 2), endAngle: .radians(volAngle), clockwise: false)
        context.stroke(arcPath, with: .color(treeColor.opacity(0.15)), lineWidth: 1)
    }

    private func drawLoudnessArc(context: inout GraphicsContext, center: CGPoint, r: CGFloat) {
        guard smoothedLevel > 0.001 else { return }
        let loudnessAngle = volumeToAngle(smoothedLevel)
        var loudPath = Path()
        loudPath.addArc(center: center, radius: r, startAngle: .radians(-.pi / 2), endAngle: .radians(loudnessAngle), clockwise: false)
        context.stroke(loudPath, with: .color(treeColor.opacity(0.25)), lineWidth: MeadowMetrics.loudnessArcWidth)
    }

    private func drawVolumeDot(context: inout GraphicsContext, center: CGPoint, r: CGFloat) {
        let volAngle = volumeToAngle(tree.volume)
        let dotCenter = CGPoint(
            x: center.x + cos(volAngle) * Double(r),
            y: center.y + sin(volAngle) * Double(r)
        )
        let dotR = MeadowMetrics.volumeDotRadius
        let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
        context.fill(Path(ellipseIn: dotRect), with: .color(treeColor))
        context.stroke(Path(ellipseIn: dotRect), with: .color(Color.black.opacity(0.6)), lineWidth: 1)
    }

    private func updateLevel() {
        let nodes = projectState.nodesForTree(tree.id)
        var sumSq: Float = 0
        for node in nodes {
            let m = AudioEngine.shared.nodeMeterLevels(nodeID: node.id)
            let peak = max(m.rmsL, m.rmsR)
            sumSq += peak * peak
        }
        let rawLevel = Double(sqrt(sumSq))
        let clamped = min(rawLevel, tree.volume)
        smoothedLevel = smoothedLevel * MeadowMetrics.smoothingFactor + clamped * (1 - MeadowMetrics.smoothingFactor)
    }

    /// Map volume (0-1) to angle (radians). 0 at 12 o'clock, clockwise to full rotation.
    private func volumeToAngle(_ volume: Double) -> Double {
        volume * 2.0 * .pi - .pi / 2.0
    }

}
