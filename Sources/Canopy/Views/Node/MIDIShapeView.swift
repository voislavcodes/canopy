import SwiftUI

/// Parameters extracted from NoteSequence transform settings that influence the MIDI shape visualization.
struct MIDIShapeParams: Equatable {
    var globalProbability: Double = 1.0
    var mutationAmount: Double = 0.0
    var mutationRange: Int = 1
    var density: Double = 1.0
    var invertEnabled: Bool = false
    var mirrorEnabled: Bool = false
    var bloomAmount: Double = 0.0
    var humanize: Double = 0.0
    var driftRate: Double = 0.0

    init() {}

    init(from seq: NoteSequence) {
        globalProbability = seq.globalProbability
        mutationAmount = seq.mutation?.amount ?? 0
        mutationRange = seq.mutation?.range ?? 1
        density = seq.density ?? 1.0
        invertEnabled = seq.invertEnabled ?? false
        mirrorEnabled = seq.mirrorEnabled ?? false
        bloomAmount = seq.bloomAmount ?? 0
        humanize = seq.humanize ?? 0
        driftRate = seq.driftRate ?? 0
    }
}

/// Draws an organic star/spike fingerprint from note event data.
/// Transform parameters visually influence the shape so users can see
/// how their transform stack changes the node's character.
struct MIDIShapeView: View {
    let notes: [NoteEvent]
    let lengthInBeats: Double
    let color: Color
    var params: MIDIShapeParams = MIDIShapeParams()

    /// Epoch for drift rotation — fixed to avoid jumps on view recreation.
    private static let driftEpoch = Date.distantPast

    var body: some View {
        if params.driftRate > 0 {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                shapeCanvas
                    .rotationEffect(driftAngle(at: timeline.date))
            }
        } else {
            shapeCanvas
        }
    }

    private var shapeCanvas: some View {
        Canvas { context, size in
            drawShape(context: &context, size: size)
        }
        .frame(width: NodeMetrics.midiShapeMaxRadius * 2 + 4, height: NodeMetrics.midiShapeMaxRadius * 2 + 4)
    }

    private func driftAngle(at date: Date) -> Angle {
        let elapsed = date.timeIntervalSince(Self.driftEpoch)
        return .radians(elapsed * params.driftRate * 0.5)
    }

    // MARK: - Drawing

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

        let sorted: [(key: Double, value: Double)] = beatVelocities.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return }

        // Probability scales opacity
        let fillAlpha = 0.15 * params.globalProbability
        let strokeAlpha = 0.3 * max(0.15, params.globalProbability)

        // Compute vertices shared by fill + stroke paths
        let (vertices, ghostPath) = computeVertices(sorted: sorted, center: center, minR: minR, maxR: maxR)

        let fillPath = buildSmoothPath(from: vertices)

        let strokePath: Path
        if params.mutationAmount > 0 {
            let amplitude = 1.5 + CGFloat(params.mutationAmount) * 3.5
            strokePath = buildZigzagPath(from: vertices, amplitude: amplitude)
        } else {
            strokePath = fillPath
        }

        // Layer 1: Density ghost (behind everything)
        if let ghostPath {
            context.stroke(
                ghostPath,
                with: .color(color.opacity(strokeAlpha * 0.3)),
                style: StrokeStyle(lineWidth: 1.0, dash: [3, 2])
            )
        }

        // Layer 2: Main shape
        context.fill(fillPath, with: .color(color.opacity(fillAlpha)))
        context.stroke(strokePath, with: .color(color.opacity(strokeAlpha)), lineWidth: 1.0)
    }

    // MARK: - Vertex Computation

    /// A quad curve segment: from current position → to, guided by control.
    private struct CurveSegment {
        let to: CGPoint
        let control: CGPoint
    }

    /// All geometry needed to draw the shape — shared between smooth fill and zigzag stroke.
    private struct ShapeVertices {
        let startPoint: CGPoint
        let segments: [CurveSegment]
    }

    /// Computes the shape geometry and optional density ghost path.
    private func computeVertices(
        sorted: [(key: Double, value: Double)],
        center: CGPoint,
        minR: CGFloat,
        maxR: CGFloat
    ) -> (vertices: ShapeVertices, ghost: Path?) {
        var segments: [CurveSegment] = []
        var ghostPath: Path? = nil
        var startPoint: CGPoint = .zero
        let count = sorted.count
        let hasDensityCulling = params.density < 1.0

        for i in 0..<count {
            let entry = sorted[i]

            // Mirror — reverse angular direction
            let beatFraction = entry.key / lengthInBeats
            let angle: CGFloat
            if params.mirrorEnabled {
                angle = CGFloat(1.0 - beatFraction) * 2.0 * .pi - .pi / 2.0
            } else {
                angle = CGFloat(beatFraction) * 2.0 * .pi - .pi / 2.0
            }

            // Invert — flip: valleys at outer edge, spikes point inward
            let spikeR: CGFloat
            let baseR: CGFloat
            if params.invertEnabled {
                spikeR = maxR - (maxR - minR) * CGFloat(entry.value)
                baseR = maxR
            } else {
                spikeR = minR + (maxR - minR) * CGFloat(entry.value)
                baseR = minR
            }

            // Humanize — deterministic angular wobble
            let wobbledAngle: CGFloat
            if params.humanize > 0 {
                let beatHash = sin(entry.key * 73.1 + 17.3)
                let maxWobble = (2.0 * .pi / CGFloat(count)) * 0.3
                wobbledAngle = angle + CGFloat(params.humanize * beatHash) * maxWobble
            } else {
                wobbledAngle = angle
            }

            // Bloom — push valley toward spike radius
            let valleyR: CGFloat = baseR + (spikeR - baseR) * CGFloat(params.bloomAmount) * 0.6

            // Density — deterministic culling matching SequenceTransforms hash
            let effectiveR: CGFloat
            let survives: Bool
            if hasDensityCulling {
                let hash = ((i * 7 + 13) * 37) % 100
                let threshold = (1.0 - params.density) * 100
                survives = Double(hash) >= threshold
                effectiveR = survives ? spikeR : valleyR
            } else {
                survives = true
                effectiveR = spikeR
            }

            let spikePoint = CGPoint(
                x: center.x + cos(wobbledAngle) * effectiveR,
                y: center.y + sin(wobbledAngle) * effectiveR
            )

            // Ghost path: show culled spike at original radius
            if hasDensityCulling && !survives {
                if ghostPath == nil { ghostPath = Path() }
                let ghostPoint = CGPoint(
                    x: center.x + cos(wobbledAngle) * spikeR,
                    y: center.y + sin(wobbledAngle) * spikeR
                )
                let ghostCtrlR = spikeR * 0.7 + valleyR * 0.3
                let ghostCtrl = CGPoint(
                    x: center.x + cos(wobbledAngle) * ghostCtrlR,
                    y: center.y + sin(wobbledAngle) * ghostCtrlR
                )
                ghostPath!.move(to: CGPoint(
                    x: center.x + cos(wobbledAngle) * valleyR,
                    y: center.y + sin(wobbledAngle) * valleyR
                ))
                ghostPath!.addQuadCurve(to: ghostPoint, control: ghostCtrl)
            }

            if i == 0 {
                let prevBeat = sorted[count - 1].key
                let prevFraction = prevBeat / lengthInBeats
                let curFraction = entry.key / lengthInBeats

                let midFraction: Double
                if params.mirrorEnabled {
                    midFraction = ((1.0 - prevFraction) + (1.0 - curFraction + 1.0)) / 2.0
                } else {
                    midFraction = (prevFraction + curFraction + 1.0) / 2.0
                }
                let midAngle: CGFloat = CGFloat(midFraction) * 2.0 * .pi - .pi / 2.0
                startPoint = CGPoint(
                    x: center.x + cos(midAngle) * valleyR,
                    y: center.y + sin(midAngle) * valleyR
                )
            }

            // Curve to spike
            let ctrlR: CGFloat = effectiveR * 0.7 + valleyR * 0.3
            let spikeCtrl = CGPoint(
                x: center.x + cos(wobbledAngle) * ctrlR,
                y: center.y + sin(wobbledAngle) * ctrlR
            )
            segments.append(CurveSegment(to: spikePoint, control: spikeCtrl))

            // Valley between this spike and the next
            let nextEntry = sorted[(i + 1) % count]
            let nextFraction: Double
            if params.mirrorEnabled {
                let rawNext = nextEntry.key / lengthInBeats
                nextFraction = 1.0 - rawNext + ((i + 1 >= count) ? -1.0 : 0.0)
            } else {
                let rawNext = nextEntry.key / lengthInBeats
                nextFraction = rawNext + ((i + 1 >= count) ? 1.0 : 0.0)
            }

            let curFractionForValley: Double
            if params.mirrorEnabled {
                curFractionForValley = 1.0 - entry.key / lengthInBeats
            } else {
                curFractionForValley = entry.key / lengthInBeats
            }

            let valleyFraction = (curFractionForValley + nextFraction) / 2.0
            let valleyAngle: CGFloat = CGFloat(valleyFraction) * 2.0 * .pi - .pi / 2.0
            let valleyPoint = CGPoint(
                x: center.x + cos(valleyAngle) * valleyR,
                y: center.y + sin(valleyAngle) * valleyR
            )

            let midCtrlAngle: CGFloat = (wobbledAngle + valleyAngle) / 2.0
            let valleyCtrl = CGPoint(
                x: center.x + cos(midCtrlAngle) * valleyR,
                y: center.y + sin(midCtrlAngle) * valleyR
            )
            segments.append(CurveSegment(to: valleyPoint, control: valleyCtrl))
        }

        return (ShapeVertices(startPoint: startPoint, segments: segments), ghostPath)
    }

    // MARK: - Path Builders

    /// Smooth path from quad curves — used for fill (always) and stroke (when no mutation).
    private func buildSmoothPath(from vertices: ShapeVertices) -> Path {
        var path = Path()
        path.move(to: vertices.startPoint)
        for seg in vertices.segments {
            path.addQuadCurve(to: seg.to, control: seg.control)
        }
        path.closeSubpath()
        return path
    }

    /// Zig-zag path — subdivide each curve into line segments with perpendicular noise.
    private func buildZigzagPath(from vertices: ShapeVertices, amplitude: CGFloat) -> Path {
        var path = Path()
        path.move(to: vertices.startPoint)

        let stepsPerCurve = 10
        var cursor = vertices.startPoint
        var globalStep = 0

        for seg in vertices.segments {
            let from = cursor
            for s in 1...stepsPerCurve {
                let t = CGFloat(s) / CGFloat(stepsPerCurve)

                // Quadratic bezier evaluation
                let oneMinusT = 1 - t
                let x = oneMinusT * oneMinusT * from.x + 2 * oneMinusT * t * seg.control.x + t * t * seg.to.x
                let y = oneMinusT * oneMinusT * from.y + 2 * oneMinusT * t * seg.control.y + t * t * seg.to.y

                // Tangent
                let dx = 2 * oneMinusT * (seg.control.x - from.x) + 2 * t * (seg.to.x - seg.control.x)
                let dy = 2 * oneMinusT * (seg.control.y - from.y) + 2 * t * (seg.to.y - seg.control.y)
                let len = sqrt(dx * dx + dy * dy)

                if len > 0.001 {
                    // Perpendicular normal
                    let nx = -dy / len
                    let ny = dx / len

                    // Deterministic zig-zag: alternating sign modulated by hash
                    let hash = CGFloat(sin(Double(globalStep) * 127.1 + 311.7))
                    let offset = amplitude * hash
                    path.addLine(to: CGPoint(x: x + nx * offset, y: y + ny * offset))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                globalStep += 1
            }
            cursor = seg.to
        }

        path.closeSubpath()
        return path
    }
}
