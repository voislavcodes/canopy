import SwiftUI

struct CanopyCanvasView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var canvasState: CanvasState
    @ObservedObject var transportState: TransportState

    private let dotSpacing: CGFloat = 40
    private let dotSize: CGFloat = 2
    private let canvasCornerRadius: CGFloat = 16

    private func centerOffset(viewSize: CGSize) -> CGSize {
        CGSize(width: viewSize.width / 2, height: viewSize.height / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size

            ZStack {
                // Layer 0: Outer background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Layer 1: Canvas area with border + dot grid
                canvasArea(viewSize: viewSize)

                // Layer 2: Transformed content (bloom zone + nodes)
                transformedContent(viewSize: viewSize)

                // Layer 3: Bloom panels (screen-space, positioned from node)
                if let selectedNode = projectState.selectedNode {
                    bloomOverlay(node: selectedNode, viewSize: viewSize)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        canvasState.offset = CGSize(
                            width: canvasState.lastOffset.width + value.translation.width,
                            height: canvasState.lastOffset.height + value.translation.height
                        )
                        canvasState.clampOffset(viewSize: viewSize)
                    }
                    .onEnded { _ in
                        canvasState.lastOffset = canvasState.offset
                    }
            )
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

    // MARK: - Transformed Content (canvas space)

    private func transformedContent(viewSize: CGSize) -> some View {
        ZStack {
            // Bloom zone circle behind selected node
            if let selectedNode = projectState.selectedNode {
                Circle()
                    .fill(CanopyColors.bloomZone.opacity(0.85))
                    .frame(width: 350, height: 350)
                    .position(x: selectedNode.position.x, y: selectedNode.position.y)
            }

            // Nodes
            ForEach(projectState.allNodes()) { node in
                NodeView(
                    node: node,
                    isSelected: projectState.selectedNodeID == node.id
                )
            }
        }
        .offset(centerOffset(viewSize: viewSize))
        .offset(canvasState.offset)
        .scaleEffect(canvasState.scale)
    }

    // MARK: - Bloom Overlay (screen space)

    @State private var keyboardOctave: Int = 3

    private func bloomOverlay(node: Node, viewSize: CGSize) -> some View {
        let screenPos = nodeScreenPosition(node: node, viewSize: viewSize)

        // Panel offsets from node center
        let synthOffset = CGPoint(x: -290, y: -20)
        let sequenceOffset = CGPoint(x: 100, y: -40)
        let promptOffset = CGPoint(x: 0, y: 160)
        let keyboardOffset = CGPoint(x: 0, y: 260)

        let synthCenter = CGPoint(x: screenPos.x + synthOffset.x, y: screenPos.y + synthOffset.y)
        let seqCenter = CGPoint(x: screenPos.x + sequenceOffset.x, y: screenPos.y + sequenceOffset.y)
        let promptCenter = CGPoint(x: screenPos.x + promptOffset.x, y: screenPos.y + promptOffset.y)
        let keyboardCenter = CGPoint(x: screenPos.x + keyboardOffset.x, y: screenPos.y + keyboardOffset.y)

        return ZStack {
            // Dashed connector lines
            BloomConnectors(
                nodeCenter: screenPos,
                synthCenter: CGPoint(x: synthCenter.x + 150, y: synthCenter.y + 50),
                seqCenter: CGPoint(x: seqCenter.x - 10, y: seqCenter.y + 50),
                promptCenter: CGPoint(x: promptCenter.x, y: promptCenter.y - 20)
            )

            // Synth panel (left)
            SynthControlsPanel(projectState: projectState)
                .position(x: synthCenter.x, y: synthCenter.y)

            // Sequence panel (right)
            StepSequencerPanel(projectState: projectState, transportState: transportState)
                .position(x: seqCenter.x, y: seqCenter.y)

            // Claude prompt (below)
            ClaudePromptPanel()
                .position(x: promptCenter.x, y: promptCenter.y)

            // Keyboard (bottom of bloom)
            KeyboardBarView(baseOctave: $keyboardOctave)
                .position(x: keyboardCenter.x, y: keyboardCenter.y)
        }
        .allowsHitTesting(true)
    }

    // MARK: - Helpers

    private func nodeScreenPosition(node: Node, viewSize: CGSize) -> CGPoint {
        let center = centerOffset(viewSize: viewSize)
        let x = (node.position.x + center.width) * canvasState.scale + canvasState.offset.width
        let y = (node.position.y + center.height) * canvasState.scale + canvasState.offset.height
        return CGPoint(x: x, y: y)
    }

    private func handleTap(at location: CGPoint, viewSize: CGSize) {
        let center = centerOffset(viewSize: viewSize)
        let canvasX = (location.x - canvasState.offset.width) / canvasState.scale - center.width
        let canvasY = (location.y - canvasState.offset.height) / canvasState.scale - center.height

        let hitRadius: CGFloat = 40

        for node in projectState.allNodes() {
            let dx = canvasX - node.position.x
            let dy = canvasY - node.position.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                projectState.selectNode(node.id)
                return
            }
        }

        projectState.selectNode(nil)
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
    var body: some View {
        HStack(spacing: 8) {
            Text("+")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)

            Text("describe this sound...")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 340)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
    }
}
