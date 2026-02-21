import SwiftUI

/// Bloom panel: ORBIT gravitational rhythm sequencer.
/// Circular orbit visualization with bodies crossing trigger zones.
/// 4 sliders: Gravity, Bodies (stepped), Tension, Density.
struct OrbitSequencerPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState

    // Local drag state
    @State private var localGravity: Double = 0.3
    @State private var localBodyCount: Double = 4
    @State private var localTension: Double = 0.0
    @State private var localDensity: Double = 0.5

    private var node: Node? { projectState.selectedNode }

    private var orbitConfig: OrbitConfig? {
        node?.orbitConfig
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            HStack {
                Text("ORBIT")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Pitched", "pitched"), ("Drum", "drum"), ("Orbit", "orbit")],
                    current: "orbit",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "pitched" {
                            projectState.swapSequencer(nodeID: nodeID, to: .pitched)
                        } else if type == "drum" {
                            projectState.swapSequencer(nodeID: nodeID, to: .drum)
                        }
                    }
                )
            }

            // Orbit visualization
            orbitVisualization
                .frame(height: 120 * cs)

            Divider()
                .background(CanopyColors.bloomPanelBorder.opacity(0.3))

            // Parameter sliders
            orbitSliders
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 260 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear { syncFromModel() }
        .onChange(of: projectState.selectedNodeID) { _ in syncFromModel() }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = orbitConfig else { return }
        localGravity = config.gravity
        localBodyCount = Double(config.bodyCount)
        localTension = config.tension
        localDensity = config.density
    }

    // MARK: - Orbit Visualization

    private var orbitVisualization: some View {
        let bodyCount = Int(localBodyCount)
        let zoneCount = zoneCountForDensity(localDensity)
        let angles = pollBodyAngles()
        let gravity = localGravity

        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                drawOrbitCanvas(context: context, size: size, bodyCount: bodyCount,
                               zoneCount: zoneCount, angles: angles, gravity: gravity)
            }
        }
    }

    private func drawOrbitCanvas(context: GraphicsContext, size: CGSize,
                                  bodyCount: Int, zoneCount: Int,
                                  angles: [Float], gravity: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) * 0.45
        let orbitColor = CanopyColors.chromeText

        // Orbit paths
        for i in 0..<bodyCount {
            let r = maxRadius * CGFloat(i + 1) / CGFloat(bodyCount + 1)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(orbitColor.opacity(0.1)), lineWidth: 1)
        }

        // Center dot
        let cd = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: cd), with: .color(orbitColor.opacity(0.3)))

        // Trigger zones
        for z in 0..<zoneCount {
            let za = CGFloat(z) * 2.0 * .pi / CGFloat(zoneCount)
            let inner = CGPoint(x: center.x + CGFloat(cos(Double(za))) * maxRadius * 0.15,
                                y: center.y + CGFloat(sin(Double(za))) * maxRadius * 0.15)
            let outer = CGPoint(x: center.x + CGFloat(cos(Double(za))) * maxRadius * 1.05,
                                y: center.y + CGFloat(sin(Double(za))) * maxRadius * 1.05)
            var p = Path()
            p.move(to: inner)
            p.addLine(to: outer)
            context.stroke(p, with: .color(orbitColor.opacity(0.08)), lineWidth: 1)
        }

        // Body positions
        let bodyColors: [Color] = [.red, .yellow, .cyan, .green, .orange, .purple]
        for i in 0..<bodyCount {
            let r = maxRadius * CGFloat(i + 1) / CGFloat(bodyCount + 1)
            let a = Double(angles[i])
            let pos = CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
            let dotRect = CGRect(x: pos.x - 4, y: pos.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dotRect), with: .color(bodyColors[i].opacity(0.8)))
        }

        // Gravitational links
        if gravity > 0.3 {
            drawGravityLinks(context: context, center: center, maxRadius: maxRadius,
                           bodyCount: bodyCount, angles: angles, gravity: gravity)
        }
    }

    private func drawGravityLinks(context: GraphicsContext, center: CGPoint,
                                   maxRadius: CGFloat, bodyCount: Int,
                                   angles: [Float], gravity: Double) {
        for i in 0..<bodyCount {
            for j in (i+1)..<bodyCount {
                let r1 = maxRadius * CGFloat(i + 1) / CGFloat(bodyCount + 1)
                let r2 = maxRadius * CGFloat(j + 1) / CGFloat(bodyCount + 1)
                let a1 = Double(angles[i])
                let a2 = Double(angles[j])
                let p1 = CGPoint(x: center.x + CGFloat(cos(a1)) * r1,
                               y: center.y + CGFloat(sin(a1)) * r1)
                let p2 = CGPoint(x: center.x + CGFloat(cos(a2)) * r2,
                               y: center.y + CGFloat(sin(a2)) * r2)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(CanopyColors.chromeText.opacity(0.05 * gravity)), lineWidth: 0.5)
            }
        }
    }

    private func pollBodyAngles() -> [Float] {
        guard let nodeID = projectState.selectedNodeID,
              let unit = AudioEngine.shared.graph.unit(for: nodeID) else {
            return [0, 0, 0, 0, 0, 0]
        }
        let a = unit.orbitBodyAngles
        return [a.0, a.1, a.2, a.3, a.4, a.5]
    }

    private func zoneCountForDensity(_ d: Double) -> Int {
        if d < 0.125 { return 1 }
        if d < 0.375 { return 2 }
        if d < 0.625 { return 4 }
        if d < 0.875 { return 8 }
        return 16
    }

    // MARK: - Parameter Sliders

    private var orbitSliders: some View {
        let orbitColor = CanopyColors.nodeRhythmic

        return VStack(spacing: 5 * cs) {
            paramSlider(label: "GRAVITY", value: $localGravity, range: 0...1, color: orbitColor, format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.gravity = localGravity }
            } onDrag: {
                pushToEngine()
            }

            // Stepped body count: 2–6
            paramSlider(label: "BODIES", value: $localBodyCount, range: 2...6, color: orbitColor, format: { "\(Int($0))" }) {
                localBodyCount = Double(Int(localBodyCount.rounded()))
                commitConfig { $0.bodyCount = Int(localBodyCount) }
            } onDrag: {
                localBodyCount = Double(Int(localBodyCount.rounded()))
                pushToEngine()
            }

            paramSlider(label: "TENSION", value: $localTension, range: 0...1, color: orbitColor, format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.tension = localTension }
            } onDrag: {
                pushToEngine()
            }

            paramSlider(label: "DENSITY", value: $localDensity, range: 0...1, color: orbitColor, format: { "\(zoneCountForDensity($0))" }) {
                commitConfig { $0.density = localDensity }
            } onDrag: {
                pushToEngine()
            }
        }
    }

    // MARK: - Param Slider

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              color: Color, format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 48 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledWidth = max(0, min(width, width * fraction))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                        .frame(height: 8 * cs)

                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(color.opacity(0.5))
                        .frame(width: filledWidth, height: 8 * cs)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let frac = Double(max(0, min(1, drag.location.x / width)))
                            value.wrappedValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                            onDrag()
                        }
                        .onEnded { _ in
                            onCommit()
                        }
                )
            }
            .frame(height: 8 * cs)

            Text(format(value.wrappedValue))
                .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 36 * cs, alignment: .trailing)
        }
    }

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout OrbitConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            var config = node.orbitConfig ?? OrbitConfig()
            transform(&config)
            node.orbitConfig = config
        }
        pushToEngine()
    }

    private func pushToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        let config = OrbitConfig(
            gravity: localGravity,
            bodyCount: Int(localBodyCount),
            tension: localTension,
            density: localDensity
        )
        AudioEngine.shared.configureOrbit(config, nodeID: nodeID)
    }
}
