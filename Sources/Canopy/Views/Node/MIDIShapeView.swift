import SwiftUI

/// Draws an organic star/spike fingerprint from note event data.
/// Static rendering — only redraws when notes change, not at 30fps.
struct MIDIShapeView: View {
    let notes: [NoteEvent]
    let lengthInBeats: Double
    let color: Color

    var body: some View {
        Canvas { context, size in
            drawShape(context: &context, size: size)
        }
        .frame(width: NodeMetrics.midiShapeMaxRadius * 2 + 4, height: NodeMetrics.midiShapeMaxRadius * 2 + 4)
    }

    private func drawShape(context: inout GraphicsContext, size: CGSize) {
        guard !notes.isEmpty, lengthInBeats > 0 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minR: CGFloat = NodeMetrics.midiShapeMinRadius
        let maxR: CGFloat = NodeMetrics.midiShapeMaxRadius

        // Group notes by beat position, keeping max velocity per beat
        var beatVelocities: [Double: Double] = [:]
        for note in notes {
            let beat = note.startBeat.truncatingRemainder(dividingBy: lengthInBeats)
            let existing = beatVelocities[beat] ?? 0
            beatVelocities[beat] = max(existing, note.velocity)
        }

        // Sort by angular position
        let sorted: [(key: Double, value: Double)] = beatVelocities.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return }

        let path = buildPath(sorted: sorted, center: center, minR: minR, maxR: maxR)

        context.fill(path, with: .color(color.opacity(0.15)))
        context.stroke(path, with: .color(color.opacity(0.3)), lineWidth: 1.0)
    }

    private func buildPath(sorted: [(key: Double, value: Double)], center: CGPoint, minR: CGFloat, maxR: CGFloat) -> Path {
        var path = Path()
        let count = sorted.count

        for i in 0..<count {
            let entry = sorted[i]
            let angle: CGFloat = CGFloat(entry.key / lengthInBeats) * 2.0 * .pi - .pi / 2.0
            let spikeR: CGFloat = minR + (maxR - minR) * CGFloat(entry.value)

            let spikePoint = CGPoint(
                x: center.x + cos(angle) * spikeR,
                y: center.y + sin(angle) * spikeR
            )

            if i == 0 {
                // Start at the valley before the first spike (same point the last valley lands on)
                let prevBeat = sorted[count - 1].key
                let midBeat: Double = (prevBeat + entry.key + lengthInBeats) / 2.0
                let midAngle: CGFloat = CGFloat(midBeat / lengthInBeats) * 2.0 * .pi - .pi / 2.0
                let valleyStart = CGPoint(
                    x: center.x + cos(midAngle) * minR,
                    y: center.y + sin(midAngle) * minR
                )
                path.move(to: valleyStart)
            }

            // Control point for curve to spike
            let ctrlR: CGFloat = spikeR * 0.7 + minR * 0.3
            let spikeCtrl = CGPoint(
                x: center.x + cos(angle) * ctrlR,
                y: center.y + sin(angle) * ctrlR
            )
            path.addQuadCurve(to: spikePoint, control: spikeCtrl)

            // Valley between this spike and the next
            let nextEntry = sorted[(i + 1) % count]
            let nextBeat: Double = (i + 1 >= count) ? nextEntry.key + lengthInBeats : nextEntry.key
            let valleyBeat: Double = (entry.key + nextBeat) / 2.0
            let valleyAngle: CGFloat = CGFloat(valleyBeat / lengthInBeats) * 2.0 * .pi - .pi / 2.0
            let valleyPoint = CGPoint(
                x: center.x + cos(valleyAngle) * minR,
                y: center.y + sin(valleyAngle) * minR
            )

            let midCtrlAngle: CGFloat = (angle + valleyAngle) / 2.0
            let valleyCtrl = CGPoint(
                x: center.x + cos(midCtrlAngle) * minR,
                y: center.y + sin(midCtrlAngle) * minR
            )
            path.addQuadCurve(to: valleyPoint, control: valleyCtrl)
        }

        path.closeSubpath()
        return path
    }
}
