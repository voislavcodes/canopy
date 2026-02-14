import SwiftUI
import AppKit

struct CanopyCanvasView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var canvasState: CanvasState
    var transportState: TransportState

    @State private var keyboardOctave: Int = 3
    @State private var scrollMonitor: Any?

    private let dotSpacing: CGFloat = 40
    private let dotSize: CGFloat = 2
    private let canvasCornerRadius: CGFloat = 16

    private func centerOffset(viewSize: CGSize) -> CGSize {
        CGSize(width: viewSize.width / 2, height: viewSize.height * 0.7)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size

            // Pre-compute values from projectState once per body evaluation
            let allNodes = projectState.allNodes()
            let selectedNode = projectState.selectedNode
            let selectedNodeID = projectState.selectedNodeID

            ZStack {
                // Layer 0: Outer background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Layer 1: Canvas area with border + dot grid
                canvasArea(viewSize: viewSize)

                // Layer 2: Scaled content — TreeContentView has value-type inputs,
                // so SwiftUI skips its body when only canvas transform changes.
                TreeContentView(
                    allNodes: allNodes,
                    selectedNode: selectedNode,
                    selectedNodeID: selectedNodeID,
                    onAddBranch: { handleAddBranch(to: $0) }
                )
                .offset(centerOffset(viewSize: viewSize))
                .offset(canvasState.offset)
                .scaleEffect(canvasState.scale)

                // Layer 3: Bloom panels — rendered outside scaleEffect for crisp text at any zoom
                if let selectedNode {
                    bloomContentScreen(node: selectedNode, viewSize: viewSize)
                }

                // Layer 4: Cycle length badge (top-right)
                CycleBadgeView(
                    nodeCount: allNodes.count,
                    cycle: projectState.cycleLengthInBeats()
                )
            }
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        canvasState.scale = canvasState.lastScale * value
                        canvasState.clampScale()
                    }
                    .onEnded { _ in
                        canvasState.lastScale = canvasState.scale
                    }
            )
            .onTapGesture { location in
                handleTap(at: location, viewSize: viewSize)
            }
            .onAppear { installScrollMonitor() }
            .onDisappear { removeScrollMonitor() }
        }
    }

    // MARK: - Canvas Background

    private func canvasArea(viewSize: CGSize) -> some View {
        let inset: CGFloat = 16
        return ZStack {
            // Dot grid
            Canvas { context, size in
                let cols = Int(size.width / dotSpacing) + 1
                let rows = Int(size.height / dotSpacing) + 1
                let offsetX = (size.width - CGFloat(cols - 1) * dotSpacing) / 2
                let offsetY = (size.height - CGFloat(rows - 1) * dotSpacing) / 2

                for row in 0..<rows {
                    for col in 0..<cols {
                        let x = offsetX + CGFloat(col) * dotSpacing
                        let y = offsetY + CGFloat(row) * dotSpacing
                        let rect = CGRect(x: x - dotSize / 2, y: y - dotSize / 2, width: dotSize, height: dotSize)
                        context.fill(Path(ellipseIn: rect), with: .color(CanopyColors.dotGrid))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: canvasCornerRadius))

            // Border
            RoundedRectangle(cornerRadius: canvasCornerRadius)
                .stroke(CanopyColors.canvasBorder.opacity(0.5), lineWidth: 1)
        }
        .padding(inset)
    }

    // MARK: - Bloom Content (screen space)

    /// Single source of truth for bloom panel layout offsets (canvas points).
    private enum BloomLayout {
        // Default offsets from node center (canvas points)
        static let synthOffset = CGPoint(x: -260, y: 20)
        static let seqOffset = CGPoint(x: 260, y: 20)
        static let promptOffset = CGPoint(x: 0, y: 180)
        static let keyboardOffset = CGPoint(x: 0, y: 280)

        // Approximate bounding box sizes for hit-testing
        static let synthSize = CGSize(width: 230, height: 230)
        static let seqSize = CGSize(width: 320, height: 340)
        static let promptSize = CGSize(width: 350, height: 55)
        static let keyboardSize = CGSize(width: 400, height: 110)
    }

    /// Convert a canvas point to screen coordinates (inverse of screenToCanvas).
    private func canvasToScreen(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let center = centerOffset(viewSize: viewSize)
        let scaleAnchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (point.x + canvasState.offset.width + (center.width - scaleAnchor.x)) * canvasState.scale + scaleAnchor.x,
            y: (point.y + canvasState.offset.height + (center.height - scaleAnchor.y)) * canvasState.scale + scaleAnchor.y
        )
    }

    /// Bloom panels rendered at base size (cs=1) and geometrically scaled via
    /// `.scaleEffect()`. This avoids re-rendering 256+ grid cells, sliders, and
    /// keyboard keys on every zoom frame — SwiftUI applies the transform without
    /// re-running any child body.
    private func bloomContentScreen(node: Node, viewSize: CGSize) -> some View {
        // Canvas-space positions
        let synthCanvas = CGPoint(x: node.position.x + BloomLayout.synthOffset.x, y: node.position.y + BloomLayout.synthOffset.y)
        let seqCanvas = CGPoint(x: node.position.x + BloomLayout.seqOffset.x, y: node.position.y + BloomLayout.seqOffset.y)
        let promptCanvas = CGPoint(x: node.position.x + BloomLayout.promptOffset.x, y: node.position.y + BloomLayout.promptOffset.y)
        let keyboardCanvas = CGPoint(x: node.position.x + BloomLayout.keyboardOffset.x, y: node.position.y + BloomLayout.keyboardOffset.y)

        // Convert to screen coordinates
        let nodeScreen = canvasToScreen(CGPoint(x: node.position.x, y: node.position.y), viewSize: viewSize)
        let synthScreen = canvasToScreen(synthCanvas, viewSize: viewSize)
        let seqScreen = canvasToScreen(seqCanvas, viewSize: viewSize)
        let promptScreen = canvasToScreen(promptCanvas, viewSize: viewSize)
        let keyboardScreen = canvasToScreen(keyboardCanvas, viewSize: viewSize)

        let scale = canvasState.scale

        return ZStack {
            BloomConnectors(
                nodeCenter: nodeScreen,
                synthCenter: canvasToScreen(CGPoint(x: synthCanvas.x + 110, y: synthCanvas.y - 50), viewSize: viewSize),
                seqCenter: canvasToScreen(CGPoint(x: seqCanvas.x - 120, y: seqCanvas.y - 50), viewSize: viewSize),
                promptCenter: canvasToScreen(CGPoint(x: promptCanvas.x, y: promptCanvas.y - 20), viewSize: viewSize)
            )

            // Bloom panels render at base size (cs=1.0) — their body only
            // re-runs when projectState changes, NOT on zoom/pan gestures.
            // The geometric scaleEffect handles zoom visually.

            SynthControlsPanel(projectState: projectState)
                .environment(\.canvasScale, 1.0)
                .scaleEffect(scale)
                .position(x: synthScreen.x, y: synthScreen.y)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

            StepSequencerPanel(projectState: projectState, transportState: transportState)
                .environment(\.canvasScale, 1.0)
                .scaleEffect(scale)
                .position(x: seqScreen.x, y: seqScreen.y)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

            ClaudePromptPanel()
                .environment(\.canvasScale, 1.0)
                .scaleEffect(scale)
                .position(x: promptScreen.x, y: promptScreen.y)
                .transition(.scale(scale: 0.8).combined(with: .opacity))

            KeyboardBarView(baseOctave: $keyboardOctave, selectedNodeID: projectState.selectedNodeID)
                .environment(\.canvasScale, 1.0)
                .scaleEffect(scale)
                .position(x: keyboardScreen.x, y: keyboardScreen.y)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    // MARK: - Branch Actions

    private func handleAddBranch(to parentID: UUID) {
        var newNode: Node!
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            newNode = projectState.addChildNode(to: parentID)
            projectState.selectNode(newNode.id)
        }

        // Hot-patch: add single node to live audio graph
        AudioEngine.shared.addNode(newNode)
        if case .oscillator(let config) = newNode.patch.soundType {
            let waveformIndex: Int
            switch config.waveform {
            case .sine: waveformIndex = 0
            case .triangle: waveformIndex = 1
            case .sawtooth: waveformIndex = 2
            case .square: waveformIndex = 3
            case .noise: waveformIndex = 4
            }
            AudioEngine.shared.configurePatch(
                waveform: waveformIndex, detune: config.detune,
                attack: newNode.patch.envelope.attack, decay: newNode.patch.envelope.decay,
                sustain: newNode.patch.envelope.sustain, release: newNode.patch.envelope.release,
                volume: newNode.patch.volume,
                nodeID: newNode.id
            )
        }
        let events = newNode.sequence.notes.map { event in
            SequencerEvent(
                pitch: event.pitch, velocity: event.velocity,
                startBeat: event.startBeat, endBeat: event.startBeat + event.duration
            )
        }
        AudioEngine.shared.loadSequence(events, lengthInBeats: newNode.sequence.lengthInBeats, nodeID: newNode.id)

        // If transport is playing, start the new node's sequencer too
        if transportState.isPlaying {
            AudioEngine.shared.graph.unit(for: newNode.id)?.startSequencer(bpm: transportState.bpm)
        }
    }

    // MARK: - Scroll Panning

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak canvasState] event in
            guard let canvasState = canvasState else { return event }

            if event.modifierFlags.contains(.command) {
                // CMD + scroll → zoom
                let zoomDelta = event.scrollingDeltaY * 0.01
                canvasState.scale += zoomDelta
                canvasState.clampScale()
                canvasState.lastScale = canvasState.scale
            } else {
                // Plain scroll → pan
                canvasState.offset = CGSize(
                    width: canvasState.offset.width + event.scrollingDeltaX,
                    height: canvasState.offset.height + event.scrollingDeltaY
                )
                canvasState.lastOffset = canvasState.offset
                if let windowSize = event.window?.contentView?.frame.size {
                    canvasState.clampOffset(viewSize: windowSize)
                }
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: - Tap Handling

    /// Convert a screen point to canvas coordinates, inverting the transform pipeline:
    /// content → offset(center) → offset(canvasOffset) → scaleEffect(around view center)
    private func screenToCanvas(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let center = centerOffset(viewSize: viewSize)
        let scaleAnchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (point.x - scaleAnchor.x) / canvasState.scale - canvasState.offset.width - (center.width - scaleAnchor.x),
            y: (point.y - scaleAnchor.y) / canvasState.scale - canvasState.offset.height - (center.height - scaleAnchor.y)
        )
    }

    private func handleTap(at location: CGPoint, viewSize: CGSize) {
        let canvas = screenToCanvas(location, viewSize: viewSize)
        let canvasX = canvas.x
        let canvasY = canvas.y

        let hitRadius: CGFloat = 40

        for node in projectState.allNodes() {
            let dx = canvasX - node.position.x
            let dy = canvasY - node.position.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                withAnimation(.spring(duration: 0.3)) {
                    projectState.selectNode(node.id)
                }
                return
            }
        }

        withAnimation(.spring(duration: 0.2)) {
            projectState.selectNode(nil)
        }
    }
}

// MARK: - TreeContentView (value-type inputs — body skipped when only canvas transform changes)

/// Isolated view for tree content (branch lines, nodes, bloom zone, add button).
/// Receives all data as value types so SwiftUI's structural diffing skips its body
/// when only the canvas offset/scale changes in the parent.
private struct TreeContentView: View {
    let allNodes: [Node]
    let selectedNode: Node?
    let selectedNodeID: UUID?
    let onAddBranch: (UUID) -> Void

    var body: some View {
        ZStack {
            // Branch lines (behind everything)
            BranchLineView(nodes: allNodes)

            // Bloom zone circle behind selected node
            if let selectedNode {
                Circle()
                    .fill(CanopyColors.bloomZone.opacity(0.85))
                    .frame(width: 350, height: 350)
                    .position(x: selectedNode.position.x, y: selectedNode.position.y)
            }

            // Nodes
            ForEach(allNodes) { node in
                NodeView(
                    node: node,
                    isSelected: selectedNodeID == node.id
                )
            }

            // Add branch button for selected node
            if let selectedNode {
                AddBranchButton(
                    parentPosition: CGPoint(x: selectedNode.position.x, y: selectedNode.position.y),
                    children: selectedNode.children
                ) {
                    onAddBranch(selectedNode.id)
                }
            }
        }
    }
}

// MARK: - CycleBadgeView (value-type inputs)

private struct CycleBadgeView: View {
    let nodeCount: Int
    let cycle: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if nodeCount > 1 {
                Text("cycle: \(cycle.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", cycle) : String(format: "%.1f", cycle)) beats")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(CanopyColors.bloomPanelBackground.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(28)
        .allowsHitTesting(false)
    }
}

// MARK: - Dashed Connector Lines

struct BloomConnectors: View {
    let nodeCenter: CGPoint
    let synthCenter: CGPoint
    let seqCenter: CGPoint
    let promptCenter: CGPoint

    var body: some View {
        Canvas { context, _ in
            let dash: [CGFloat] = [6, 4]

            // Node → Synth (left)
            var pathLeft = Path()
            pathLeft.move(to: nodeCenter)
            pathLeft.addLine(to: synthCenter)
            context.stroke(
                pathLeft,
                with: .color(CanopyColors.bloomConnector.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: dash)
            )

            // Node → Sequence (right)
            var pathRight = Path()
            pathRight.move(to: nodeCenter)
            pathRight.addLine(to: seqCenter)
            context.stroke(
                pathRight,
                with: .color(CanopyColors.bloomConnector.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: dash)
            )

            // Node → Prompt (below)
            var pathBelow = Path()
            pathBelow.move(to: nodeCenter)
            pathBelow.addLine(to: promptCenter)
            context.stroke(
                pathBelow,
                with: .color(CanopyColors.bloomConnector.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1, dash: dash)
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Claude Prompt Placeholder

struct ClaudePromptPanel: View {
    @Environment(\.canvasScale) var cs

    var body: some View {
        HStack(spacing: 8 * cs) {
            Text("+")
                .font(.system(size: 14 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)

            Text("describe this sound...")
                .font(.system(size: 14 * cs, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Spacer()
        }
        .padding(.horizontal, 20 * cs)
        .padding(.vertical, 14 * cs)
        .frame(width: 340 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
    }
}
