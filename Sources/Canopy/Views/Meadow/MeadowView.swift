import SwiftUI
import AppKit

/// Meadow mixer view: same canvas as Forest with mixer ring overlays on root nodes.
struct MeadowView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var canvasState: CanvasState
    var transportState: TransportState
    @EnvironmentObject var viewModeManager: ViewModeManager

    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?

    private let dotSpacing: CGFloat = 40
    private let dotSize: CGFloat = 2
    private let canvasCornerRadius: CGFloat = 16

    var body: some View {
        let trees = projectState.project.trees

        GeometryReader { geometry in
            let viewSize = geometry.size
            let treeOffsets = CanvasLayout.computeTreeOffsets(trees: trees)

            ZStack {
                // Layer 0: background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Layer 1: canvas area with dot grid + border
                canvasArea(viewSize: viewSize)

                if trees.isEmpty {
                    emptyState
                } else {
                    // Layer 2: scaled content — node hierarchies + branches
                    MeadowContentView(
                        trees: trees,
                        treeOffsets: treeOffsets,
                        selectedTreeID: projectState.selectedTreeID,
                        isPlaying: transportState.isPlaying,
                        projectState: projectState
                    )
                    .offset(CGSize(width: viewSize.width / 2, height: viewSize.height / 2))
                    .offset(canvasState.offset)
                    .scaleEffect(canvasState.scale)

                    // Layer 3: mixer overlays in screen space
                    mixerOverlays(viewSize: viewSize, treeOffsets: treeOffsets)
                }
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
                handleTap(at: location, viewSize: viewSize, treeOffsets: treeOffsets)
            }
            .onAppear { installScrollMonitor(); installKeyMonitor() }
            .onDisappear { removeScrollMonitor(); removeKeyMonitor() }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Add a branch in Forest to start mixing")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Canvas Background

    private func canvasArea(viewSize: CGSize) -> some View {
        let inset: CGFloat = 16
        return ZStack {
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

            RoundedRectangle(cornerRadius: canvasCornerRadius)
                .stroke(CanopyColors.canvasBorder.opacity(0.5), lineWidth: 1)
        }
        .padding(inset)
    }

    // MARK: - Coordinate Transforms

    private func canvasToScreen(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let centerX = viewSize.width / 2
        let centerY = viewSize.height / 2
        let scaleAnchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (point.x + canvasState.offset.width + (centerX - scaleAnchor.x)) * canvasState.scale + scaleAnchor.x,
            y: (point.y + canvasState.offset.height + (centerY - scaleAnchor.y)) * canvasState.scale + scaleAnchor.y
        )
    }

    private func screenToCanvas(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let centerX = viewSize.width / 2
        let centerY = viewSize.height / 2
        let scaleAnchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        return CGPoint(
            x: (point.x - scaleAnchor.x) / canvasState.scale - canvasState.offset.width - (centerX - scaleAnchor.x),
            y: (point.y - scaleAnchor.y) / canvasState.scale - canvasState.offset.height - (centerY - scaleAnchor.y)
        )
    }

    // MARK: - Mixer Overlays (screen space)

    @ViewBuilder
    private func mixerOverlays(viewSize: CGSize, treeOffsets: [CGPoint]) -> some View {
        let trees = projectState.project.trees

        ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
            if index < treeOffsets.count {
                let offset = treeOffsets[index]
                let allNodes = CanvasLayout.collectNodes(from: tree.rootNode)

                ForEach(allNodes) { node in
                    let nodePos = CGPoint(
                        x: offset.x + node.position.x,
                        y: offset.y + node.position.y - 17.5
                    )
                    let screenPos = canvasToScreen(nodePos, viewSize: viewSize)
                    let isRoot = node.id == tree.rootNode.id
                    let nodeColor = SeedColor.colorForNode(node.id, in: tree)

                    if isRoot {
                        // Root: tree-level volume/pan, full label
                        let allNodeIDs = allNodes.map { $0.id }
                        MeadowVolumeRing(
                            volume: tree.volume,
                            beats: Int(node.sequence.lengthInBeats),
                            color: nodeColor,
                            meterNodeIDs: allNodeIDs
                        )
                        .scaleEffect(canvasState.scale)
                        .position(screenPos)

                        MeadowPanRing(
                            volume: tree.volume,
                            pan: tree.pan,
                            color: nodeColor,
                            onVolumeChange: { projectState.setTreeVolume(tree.id, volume: $0) },
                            onPanChange: { projectState.setTreePan(tree.id, pan: $0) },
                            onSelect: { projectState.selectTree(tree.id) }
                        )
                        .scaleEffect(canvasState.scale)
                        .position(screenPos)

                        MeadowMixerLabel(tree: tree, projectState: projectState)
                            .scaleEffect(canvasState.scale)
                            .position(x: screenPos.x, y: screenPos.y + 90 * canvasState.scale)
                    } else {
                        // Branch: per-node patch volume/pan
                        MeadowVolumeRing(
                            volume: node.patch.volume,
                            beats: Int(node.sequence.lengthInBeats),
                            color: nodeColor,
                            meterNodeIDs: [node.id]
                        )
                        .scaleEffect(canvasState.scale)
                        .position(screenPos)

                        MeadowPanRing(
                            volume: node.patch.volume,
                            pan: node.patch.pan,
                            color: nodeColor,
                            onVolumeChange: { projectState.setNodeVolume(node.id, volume: $0) },
                            onPanChange: { projectState.setNodePan(node.id, pan: $0) },
                            onSelect: { projectState.selectTree(tree.id) }
                        )
                        .scaleEffect(canvasState.scale)
                        .position(screenPos)
                    }
                }
            }
        }

        // SHORE master
        let shoreCanvasPos = shorePosition(treeOffsets: treeOffsets, trees: trees)
        let shoreScreen = canvasToScreen(shoreCanvasPos, viewSize: viewSize)
        MeadowShoreView(projectState: projectState)
            .scaleEffect(canvasState.scale)
            .position(shoreScreen)
    }

    // MARK: - SHORE Position

    private func shorePosition(treeOffsets: [CGPoint], trees: [NodeTree]) -> CGPoint {
        guard let lastOffset = treeOffsets.last, let lastTree = trees.last else {
            return CGPoint(x: 160, y: 0)
        }
        let lastNodes = CanvasLayout.collectNodes(from: lastTree.rootNode)
        let maxX = lastNodes.map { CGFloat($0.position.x) }.max() ?? 0
        return CGPoint(x: lastOffset.x + maxX + 240, y: 0)
    }

    // MARK: - Interactions

    private func handleTap(at location: CGPoint, viewSize: CGSize, treeOffsets: [CGPoint]) {
        let canvas = screenToCanvas(location, viewSize: viewSize)
        let hitRadius: CGFloat = 55
        let trees = projectState.project.trees

        // Hit test all nodes across all trees (in forest coordinates)
        for (treeIdx, tree) in trees.enumerated() {
            guard treeIdx < treeOffsets.count else { continue }
            let offset = treeOffsets[treeIdx]
            let nodes = CanvasLayout.collectNodes(from: tree.rootNode)
            for node in nodes {
                let fx = offset.x + node.position.x
                let fy = offset.y + node.position.y
                let dx = canvas.x - fx
                let dy = canvas.y - fy
                if dx * dx + dy * dy <= hitRadius * hitRadius {
                    projectState.selectTree(tree.id)
                    return
                }
            }
        }

        // Background tap — deselect tree
        projectState.selectTree(nil)
    }

    // MARK: - Scroll Panning

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak canvasState] event in
            guard let canvasState = canvasState else { return event }

            if event.modifierFlags.contains(.command) {
                let zoomDelta = event.scrollingDeltaY * 0.01
                canvasState.scale += zoomDelta
                canvasState.clampScale()
                canvasState.lastScale = canvasState.scale
            } else {
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

    // MARK: - Keyboard Shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModeManager, weak projectState] event in
            guard let viewModeManager = viewModeManager,
                  let projectState = projectState,
                  viewModeManager.isMeadow else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s":
                if let treeID = projectState.selectedTreeID {
                    DispatchQueue.main.async {
                        projectState.toggleTreeSolo(treeID: treeID)
                    }
                    return nil
                }
            case "m":
                if let treeID = projectState.selectedTreeID {
                    DispatchQueue.main.async {
                        projectState.toggleTreeMute(treeID: treeID)
                    }
                    return nil
                }
            default:
                break
            }

            switch event.keyCode {
            case 126: // Up arrow — nudge volume +1%
                if let treeID = projectState.selectedTreeID,
                   let tree = projectState.project.trees.first(where: { $0.id == treeID }) {
                    DispatchQueue.main.async {
                        projectState.setTreeVolume(treeID, volume: min(1, tree.volume + 0.01))
                    }
                    return nil
                }
            case 125: // Down arrow — nudge volume -1%
                if let treeID = projectState.selectedTreeID,
                   let tree = projectState.project.trees.first(where: { $0.id == treeID }) {
                    DispatchQueue.main.async {
                        projectState.setTreeVolume(treeID, volume: max(0, tree.volume - 0.01))
                    }
                    return nil
                }
            case 124: // Right arrow — nudge pan +0.05
                if let treeID = projectState.selectedTreeID,
                   let tree = projectState.project.trees.first(where: { $0.id == treeID }) {
                    DispatchQueue.main.async {
                        projectState.setTreePan(treeID, pan: min(1, tree.pan + 0.05))
                    }
                    return nil
                }
            case 123: // Left arrow — nudge pan -0.05
                if let treeID = projectState.selectedTreeID,
                   let tree = projectState.project.trees.first(where: { $0.id == treeID }) {
                    DispatchQueue.main.async {
                        projectState.setTreePan(treeID, pan: max(-1, tree.pan - 0.05))
                    }
                    return nil
                }
            case 53: // Escape — deselect
                DispatchQueue.main.async {
                    projectState.selectTree(nil)
                }
                return nil
            default:
                break
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

// MARK: - MeadowContentView

private struct MeadowContentView: View {
    let trees: [NodeTree]
    let treeOffsets: [CGPoint]
    let selectedTreeID: UUID?
    let isPlaying: Bool
    var projectState: ProjectState

    var body: some View {
        ZStack {
            // Inter-tree connectors
            if trees.count > 1 {
                TreeConnectorLines(trees: trees, treeOffsets: treeOffsets)
            }

            // Per-tree rendering
            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                if index < treeOffsets.count {
                    let offset = treeOffsets[index]
                    let nodes = CanvasLayout.collectNodes(from: tree.rootNode)
                    let isTreeSelected = selectedTreeID == tree.id
                    let anyTreeSoloed = trees.contains { $0.isSolo }
                    let dimmed = tree.isMuted || (anyTreeSoloed && !tree.isSolo)
                    let dimOpacity: Double = tree.isMuted ? 0.35 : (dimmed ? 0.15 : 1.0)

                    ZStack {
                        // Branch lines
                        BranchLineView(nodes: nodes, tree: tree)

                        // All nodes via NodeView
                        ForEach(nodes) { node in
                            NodeView(
                                node: node,
                                isSelected: isTreeSelected && node.id == tree.rootNode.id,
                                isPlaying: isPlaying,
                                nodeColor: SeedColor.colorForNode(node.id, in: tree),
                                showGlow: false,
                                showLabels: false
                            )
                            .onTapGesture {
                                projectState.selectTree(tree.id)
                            }
                        }
                    }
                    .opacity(dimOpacity)
                    .offset(x: offset.x, y: offset.y)
                }
            }
        }
    }
}
