import SwiftUI
import AppKit

struct ForestCanvasView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var canvasState: CanvasState
    @ObservedObject var bloomState: BloomState
    @ObservedObject var viewModeManager: ViewModeManager
    var transportState: TransportState
    var forestPlayback: ForestPlaybackState

    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var editingTreeID: UUID?
    @State private var editingName: String = ""
    @State private var showNewTreePopover = false
    @State private var presetPickerNodeID: UUID?
    @State private var hoveredNodeID: UUID?
    @State private var hoverDismissWork: DispatchWorkItem?
    @State private var editingNodeID: UUID?
    @State private var editingNodeName: String = ""
    @State private var lastNodeTapID: UUID?
    @State private var lastNodeTapTime: Date?

    private let dotSpacing: CGFloat = 40
    private let dotSize: CGFloat = 2
    private let canvasCornerRadius: CGFloat = 16
    /// Minimum horizontal gap between tree origins.
    private let minTreeSpacing: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            let trees = projectState.project.trees
            let selectedNodeID = projectState.selectedNodeID
            let treeOffsets = computeTreeOffsets(trees: trees)

            ZStack {
                // Layer 0: background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Layer 1: canvas area with dot grid + border
                canvasArea(viewSize: viewSize)

                // Layer 2: scaled content — node hierarchies per tree
                ForestContentView(
                    trees: trees,
                    treeOffsets: treeOffsets,
                    selectedNodeID: selectedNodeID,
                    selectedTreeID: projectState.selectedTreeID,
                    activeTreeID: forestPlayback.activeTreeID,
                    nextTreeID: forestPlayback.nextTreeID,
                    isPlaying: transportState.isPlaying,
                    presetPickerNodeID: presetPickerNodeID,
                    hoveredNodeID: hoveredNodeID,
                    projectState: projectState,
                    onNodeTap: { nodeID in handleNodeTap(nodeID) },
                    onAddBranch: { nodeID in
                        if let node = projectState.findNode(id: nodeID) {
                            ensureInitialOffsets(for: node)
                        }
                        presetPickerNodeID = nodeID
                    },
                    onPresetSelected: { preset in
                        if let targetID = presetPickerNodeID {
                            presetPickerNodeID = nil
                            projectState.selectNodeInTree(targetID)
                            handleAddBranch(to: targetID, preset: preset)
                        }
                    },
                    onPickerDismiss: { presetPickerNodeID = nil },
                    onHover: { nodeID, isHovered in
                        handleNodeHover(nodeID: nodeID, isHovered: isHovered)
                    },
                    onNewTreeTap: { handleNewTreeTap() },
                    showNewTreePopover: $showNewTreePopover
                )
                .offset(CGSize(width: viewSize.width / 2, height: viewSize.height / 2))
                .offset(canvasState.offset)
                .scaleEffect(canvasState.scale)

                // Layer 3: Bloom panels for selected node
                if let selectedNode = projectState.selectedNode {
                    forestBloomContent(node: selectedNode, viewSize: viewSize, treeOffsets: treeOffsets)
                }

                // Layer 3.5: Inline rename overlay (tree name)
                if let editID = editingTreeID,
                   let treeIdx = trees.firstIndex(where: { $0.id == editID }) {
                    let offset = treeOffsets[treeIdx]
                    let screenPos = canvasToScreen(
                        CGPoint(x: offset.x, y: offset.y + 46),
                        viewSize: viewSize
                    )
                    InlineTreeRenameField(
                        name: $editingName,
                        onCommit: {
                            let name = editingName
                            let id = editID
                            editingTreeID = nil
                            projectState.renameTree(id: id, name: name)
                        },
                        onCancel: { editingTreeID = nil }
                    )
                    .scaleEffect(canvasState.scale)
                    .position(x: screenPos.x, y: screenPos.y)
                }

                // Layer 3.6: Inline rename overlay (node name)
                if let editNodeID = editingNodeID,
                   let editNode = projectState.findNode(id: editNodeID) {
                    let nodeForest = forestPositionForNode(editNode, treeOffsets: treeOffsets)
                    let screenPos = canvasToScreen(
                        CGPoint(x: nodeForest.x, y: nodeForest.y + 36),
                        viewSize: viewSize
                    )
                    InlineNodeRenameField(
                        name: $editingNodeName,
                        onCommit: {
                            let finalName = editingNodeName
                            let nid = editNodeID
                            editingNodeID = nil
                            projectState.updateNode(id: nid) { $0.name = finalName }
                        },
                        onCancel: { editingNodeID = nil }
                    )
                    .scaleEffect(canvasState.scale)
                    .position(x: screenPos.x, y: screenPos.y)
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
            .onChange(of: projectState.selectedNodeID) { _ in
                editingNodeID = nil
            }
        }
    }

    // MARK: - Tree Layout

    /// Compute horizontal offsets for each tree so they don't overlap.
    /// Each tree's nodes use local coordinates (root at 0,0). The offset positions
    /// trees left-to-right with enough spacing for their node extents.
    private func computeTreeOffsets(trees: [NodeTree]) -> [CGPoint] {
        guard !trees.isEmpty else { return [] }

        // Compute horizontal extent of each tree
        var extents: [(minX: CGFloat, maxX: CGFloat)] = []
        for tree in trees {
            var nodes: [Node] = []
            collectNodes(from: tree.rootNode, into: &nodes)
            let xs = nodes.map { CGFloat($0.position.x) }
            let minX = (xs.min() ?? 0) - 60  // pad for ring radius + label
            let maxX = (xs.max() ?? 0) + 60
            extents.append((minX, maxX))
        }

        // Place trees sequentially with gaps
        let gap: CGFloat = 80
        var offsets: [CGPoint] = []
        var cursor: CGFloat = 0

        for (i, ext) in extents.enumerated() {
            if i == 0 {
                // First tree: center its local coordinates at cursor
                let centerX = -ext.minX  // shifts so minX lands at 0
                cursor = centerX + ext.maxX + gap
                offsets.append(CGPoint(x: centerX, y: 0))
            } else {
                // Next tree starts after cursor, shifted so its minX aligns at cursor
                let x = cursor - ext.minX
                cursor = x + ext.maxX + gap
                offsets.append(CGPoint(x: x, y: 0))
            }
        }

        // Center the whole set
        let totalMin = offsets.enumerated().map { (i, o) in o.x + extents[i].minX }.min() ?? 0
        let totalMax = offsets.enumerated().map { (i, o) in o.x + extents[i].maxX }.max() ?? 0
        let totalCenter = (totalMin + totalMax) / 2
        return offsets.map { CGPoint(x: $0.x - totalCenter, y: $0.y) }
    }

    /// Convert a node's local position to forest coordinates using tree offsets.
    private func forestPositionForNode(_ node: Node, treeOffsets: [CGPoint]) -> CGPoint {
        if let (index, _) = projectState.treeContainingNode(node.id),
           index < treeOffsets.count {
            let offset = treeOffsets[index]
            return CGPoint(x: offset.x + node.position.x, y: offset.y + node.position.y)
        }
        return CGPoint(x: node.position.x, y: node.position.y)
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

    // MARK: - Bloom Content (screen space)

    private enum BloomLayout {
        static let synthOffset = CGPoint(x: -330, y: -100)
        static let seqOffset = CGPoint(x: 260, y: -100)
        static let keyboardOffset = CGPoint(x: 0, y: 205)

        static let synthSize = CGSize(width: 220, height: 260)
        static let seqSize = CGSize(width: 440, height: 340)
        static let keyboardSize = CGSize(width: 420, height: 250)

        static let defaultOffsets: [BloomPanel: CGPoint] = [
            .synth: synthOffset, .sequencer: seqOffset,
            .input: keyboardOffset
        ]
        static let panelSizes: [BloomPanel: CGSize] = [
            .synth: synthSize, .sequencer: seqSize,
            .input: keyboardSize
        ]
    }

    @ViewBuilder
    private func forestBloomContent(node: Node, viewSize: CGSize, treeOffsets: [CGPoint]) -> some View {
        let _ = ensureInitialOffsets(for: node)
        let nodeForest = forestPositionForNode(node, treeOffsets: treeOffsets)
        let bloomAccentColor = resolveNodeAccentColor(node.id)

        let synthUserOffset = bloomState.storedOffset(panel: .synth, nodeID: node.id)
        let seqUserOffset = bloomState.storedOffset(panel: .sequencer, nodeID: node.id)
        let keyboardUserOffset = bloomState.storedOffset(panel: .input, nodeID: node.id)

        let synthCanvas = CGPoint(
            x: nodeForest.x + BloomLayout.synthOffset.x + synthUserOffset.width,
            y: nodeForest.y + BloomLayout.synthOffset.y + synthUserOffset.height
        )
        let seqCanvas = CGPoint(
            x: nodeForest.x + BloomLayout.seqOffset.x + seqUserOffset.width,
            y: nodeForest.y + BloomLayout.seqOffset.y + seqUserOffset.height
        )
        let keyboardCanvas = CGPoint(
            x: nodeForest.x + BloomLayout.keyboardOffset.x + keyboardUserOffset.width,
            y: nodeForest.y + BloomLayout.keyboardOffset.y + keyboardUserOffset.height
        )

        let nodeScreen = canvasToScreen(nodeForest, viewSize: viewSize)
        let synthScreen = canvasToScreen(synthCanvas, viewSize: viewSize)
        let seqScreen = canvasToScreen(seqCanvas, viewSize: viewSize)
        let keyboardScreen = canvasToScreen(keyboardCanvas, viewSize: viewSize)

        let scale = canvasState.scale

        ZStack {
            BloomConnectors(
                nodeCenter: nodeScreen,
                synthCenter: canvasToScreen(CGPoint(x: synthCanvas.x + 180, y: synthCanvas.y - 50), viewSize: viewSize),
                seqCenter: canvasToScreen(CGPoint(x: seqCanvas.x - 120, y: seqCanvas.y - 50), viewSize: viewSize),
                inputCenter: canvasToScreen(CGPoint(x: keyboardCanvas.x, y: keyboardCanvas.y - 20), viewSize: viewSize)
            )

            DraggableBloomPanel(panel: .synth, nodeID: node.id, bloomState: bloomState, canvasScale: scale, screenPosition: synthScreen) {
                ForestEngineView(projectState: projectState, accentColor: bloomAccentColor)
            }

            DraggableBloomPanel(panel: .sequencer, nodeID: node.id, bloomState: bloomState, canvasScale: scale, screenPosition: seqScreen) {
                ForestSequencerView(projectState: projectState, transportState: transportState, accentColor: bloomAccentColor)
            }

            DraggableBloomPanel(panel: .input, nodeID: node.id, bloomState: bloomState, canvasScale: scale, screenPosition: keyboardScreen) {
                ForestKeyboardView(projectState: projectState, transportState: transportState, accentColor: bloomAccentColor)
            }
        }
    }

    /// Lazily compute push-apart offsets on first selection of a node.
    private func ensureInitialOffsets(for node: Node) {
        guard bloomState.panelOffsets[node.id] == nil else { return }
        let allNodes = projectState.allNodes()
        let computed = BloomState.computeInitialOffsets(
            nodePosition: CGPoint(x: node.position.x, y: node.position.y),
            allNodes: allNodes,
            selectedNodeID: node.id,
            defaultOffsets: BloomLayout.defaultOffsets,
            panelSizes: BloomLayout.panelSizes
        )
        let hasNonZero = computed.offsets.values.contains { $0 != .zero }
        if hasNonZero {
            bloomState.panelOffsets[node.id] = computed
        } else {
            bloomState.panelOffsets[node.id] = .zero
        }
    }

    // MARK: - Interactions

    private func handleNodeTap(_ nodeID: UUID) {
        let now = Date()
        // Double-tap detection
        if let lastID = lastNodeTapID, lastID == nodeID,
           let lastTime = lastNodeTapTime, now.timeIntervalSince(lastTime) < 0.35 {
            // Double-tap → rename
            if let node = projectState.findNode(id: nodeID) {
                editingNodeID = nodeID
                editingNodeName = node.name
            }
            lastNodeTapTime = nil
            lastNodeTapID = nil
            return
        }
        lastNodeTapTime = now
        lastNodeTapID = nodeID

        // Single tap — select node and its tree
        presetPickerNodeID = nil
        if let node = projectState.findNode(id: nodeID) {
            ensureInitialOffsets(for: node)
        }
        projectState.selectNodeInTree(nodeID)
    }

    private func handleNodeHover(nodeID: UUID, isHovered: Bool) {
        if isHovered {
            hoverDismissWork?.cancel()
            hoveredNodeID = nodeID
        } else if hoveredNodeID == nodeID {
            let work = DispatchWorkItem { hoveredNodeID = nil }
            hoverDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func handleNewTreeTap() {
        showNewTreePopover = true
    }

    private func handleTap(at location: CGPoint, viewSize: CGSize, treeOffsets: [CGPoint]) {
        let canvas = screenToCanvas(location, viewSize: viewSize)
        let hitRadius: CGFloat = 55
        let trees = projectState.project.trees

        // Hit test all nodes across all trees (in forest coordinates)
        for (treeIdx, tree) in trees.enumerated() {
            guard treeIdx < treeOffsets.count else { continue }
            let offset = treeOffsets[treeIdx]
            let nodes = projectState.nodesForTree(tree.id)
            for node in nodes {
                let fx = offset.x + node.position.x
                let fy = offset.y + node.position.y
                let dx = canvas.x - fx
                let dy = canvas.y - fy
                if dx * dx + dy * dy <= hitRadius * hitRadius {
                    handleNodeTap(node.id)
                    return
                }
            }
        }

        // Hit test new tree node
        let hasContent = trees.first.map { !$0.rootNode.sequence.notes.isEmpty || !$0.rootNode.children.isEmpty } ?? false
        if trees.count < 8, hasContent {
            let newPos = newTreePosition(treeOffsets: treeOffsets, trees: trees)
            let dx = canvas.x - newPos.x
            let dy = canvas.y - newPos.y
            if dx * dx + dy * dy <= 30 * 30 {
                handleNewTreeTap()
                return
            }
        }

        // Background tap — deselect node/bloom but keep tree selected
        projectState.selectNode(nil)
        presetPickerNodeID = nil
        editingNodeID = nil
        editingTreeID = nil
        projectState.selectedLFOID = nil
    }

    private func newTreePosition(treeOffsets: [CGPoint], trees: [NodeTree]) -> CGPoint {
        guard let lastOffset = treeOffsets.last, let lastTree = trees.last else {
            return CGPoint(x: minTreeSpacing, y: 0)
        }
        let lastNodes = projectState.nodesForTree(lastTree.id)
        let maxX = lastNodes.map { CGFloat($0.position.x) }.max() ?? 0
        return CGPoint(x: lastOffset.x + maxX + 120, y: 0)
    }

    // MARK: - Branch Actions

    private func handleAddBranch(to parentID: UUID, preset: NodePreset) {
        var newNode: Node!
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            newNode = projectState.addChildNode(to: parentID, preset: preset)
            projectState.selectNodeInTree(newNode.id)
        }

        AudioEngine.shared.addNode(newNode)
        AudioEngine.shared.configureSingleNodePatch(newNode)
        AudioEngine.shared.loadSingleNodeSequence(newNode, bpm: projectState.project.bpm)
        AudioEngine.shared.configureFilter(
            enabled: newNode.patch.filter.enabled,
            cutoff: newNode.patch.filter.cutoff,
            resonance: newNode.patch.filter.resonance,
            nodeID: newNode.id
        )

        if AudioEngine.shared.isClockRunning {
            AudioEngine.shared.startNodeSequencer(nodeID: newNode.id, bpm: projectState.project.bpm)
        }
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

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModeManager, weak projectState] event in
            guard let viewModeManager = viewModeManager,
                  let projectState = projectState else { return event }

            // Enter → enter focus mode for selected node
            if event.keyCode == 36, viewModeManager.isForest {
                guard let nodeID = projectState.selectedNodeID else { return event }
                DispatchQueue.main.async {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        viewModeManager.enterFocus(nodeID: nodeID)
                    }
                }
                return nil
            }

            // Escape → deselect node
            if event.keyCode == 53, viewModeManager.isForest {
                guard projectState.selectedNodeID != nil else { return event }
                DispatchQueue.main.async {
                    projectState.selectNode(nil)
                }
                return nil
            }

            // Delete/Backspace
            if event.keyCode == 51 || event.keyCode == 117 {
                guard viewModeManager.isForest else { return event }

                if let nodeID = projectState.selectedNodeID {
                    // Check if it's a root node
                    let isRoot = projectState.project.trees.contains { $0.rootNode.id == nodeID }
                    if isRoot {
                        // Root node: delete the tree (if 2+ trees)
                        guard let treeID = projectState.selectedTreeID,
                              projectState.project.trees.count > 1 else { return event }
                        DispatchQueue.main.async {
                            // Collect all node IDs in the tree for audio cleanup
                            let nodes = projectState.nodesForTree(treeID)
                            let idsToRemove = nodes.map { $0.id }
                            projectState.selectNode(nil)
                            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                                projectState.removeTree(id: treeID)
                            }
                            AudioEngine.shared.muteAndRemoveNodes(idsToRemove)
                            // Rebuild audio for newly selected tree
                            if let newTree = projectState.selectedTree {
                                AudioEngine.shared.buildGraph(from: newTree)
                                AudioEngine.shared.configureAllPatches(from: newTree)
                                AudioEngine.shared.loadAllSequences(from: newTree, bpm: projectState.project.bpm)
                            }
                        }
                    } else {
                        // Non-root node: delete node and descendants
                        DispatchQueue.main.async {
                            func collectIDs(_ node: Node) -> [UUID] {
                                [node.id] + node.children.flatMap { collectIDs($0) }
                            }
                            let nodeToDelete = projectState.findNode(id: nodeID)
                            let idsToRemove = nodeToDelete.map { collectIDs($0) } ?? [nodeID]
                            projectState.selectNode(nil)
                            withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                                projectState.removeNode(id: nodeID)
                            }
                            AudioEngine.shared.muteAndRemoveNodes(idsToRemove)
                        }
                    }
                    return nil
                }

                return event
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

    // MARK: - Color Resolution

    /// Resolve the accent color for a node by finding its tree and computing the drifted color.
    private func resolveNodeAccentColor(_ nodeID: UUID) -> Color {
        if let (index, _) = projectState.treeContainingNode(nodeID),
           index < projectState.project.trees.count {
            let tree = projectState.project.trees[index]
            return SeedColor.colorForNode(nodeID, in: tree)
        }
        return CanopyColors.nodeSeed
    }

    // MARK: - Private Helpers

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}

// MARK: - ForestContentView (value-type inputs)

private struct ForestContentView: View {
    let trees: [NodeTree]
    let treeOffsets: [CGPoint]
    let selectedNodeID: UUID?
    let selectedTreeID: UUID?
    let activeTreeID: UUID?
    let nextTreeID: UUID?
    let isPlaying: Bool
    let presetPickerNodeID: UUID?
    let hoveredNodeID: UUID?
    var projectState: ProjectState
    let onNodeTap: (UUID) -> Void
    let onAddBranch: (UUID) -> Void
    let onPresetSelected: (NodePreset) -> Void
    let onPickerDismiss: () -> Void
    let onHover: (UUID, Bool) -> Void
    let onNewTreeTap: () -> Void
    @Binding var showNewTreePopover: Bool

    static func nodeColor(for node: Node, in tree: NodeTree) -> Color {
        SeedColor.colorForNode(node.id, in: tree)
    }

    var body: some View {
        ZStack {
            // Inter-tree dashed connectors
            if trees.count > 1 {
                TreeConnectorLines(trees: trees, treeOffsets: treeOffsets)
            }

            // Per-tree rendering
            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                if index < treeOffsets.count {
                    let offset = treeOffsets[index]
                    let nodes = projectState.nodesForTree(tree.id)

                    ZStack {
                        // Branch lines
                        BranchLineView(nodes: nodes, tree: tree)

                        // Bloom zone behind selected node
                        if let selID = selectedNodeID,
                           let selNode = nodes.first(where: { $0.id == selID }) {
                            Circle()
                                .fill(CanopyColors.bloomZone.opacity(0.85))
                                .frame(width: 350, height: 350)
                                .position(x: selNode.position.x, y: selNode.position.y)
                                .transition(.opacity.animation(.easeOut(duration: 0.15)))
                        }

                        // Node circles with playback ring
                        ForEach(nodes) { node in
                            NodeView(
                                node: node,
                                isSelected: selectedNodeID == node.id,
                                isPlaying: isPlaying,
                                nodeColor: Self.nodeColor(for: node, in: tree)
                            )
                            .onTapGesture { onNodeTap(node.id) }
                            .onHover { isHovered in
                                onHover(node.id, isHovered)
                            }
                        }

                        // Add branch button for hovered (non-selected) node
                        if let hoverID = hoveredNodeID,
                           hoverID != selectedNodeID,
                           presetPickerNodeID == nil,
                           let hoveredNode = nodes.first(where: { $0.id == hoverID }) {
                            AddBranchButton(
                                parentPosition: CGPoint(x: hoveredNode.position.x, y: hoveredNode.position.y),
                                children: [],
                                color: Self.nodeColor(for: hoveredNode, in: tree)
                            ) {
                                onAddBranch(hoveredNode.id)
                            }
                            .onHover { isHovered in
                                if isHovered {
                                    onHover(hoverID, true)
                                } else {
                                    onHover(hoverID, false)
                                }
                            }
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                        }

                        // Preset picker for any node
                        if let pickerID = presetPickerNodeID,
                           let pickerNode = nodes.first(where: { $0.id == pickerID }) {
                            let pickerPos = AddBranchButton.buttonPosition(
                                parentPosition: CGPoint(x: pickerNode.position.x, y: pickerNode.position.y),
                                children: pickerNode.children
                            )
                            PresetPickerView(
                                onSelect: onPresetSelected,
                                onDismiss: onPickerDismiss
                            )
                            .position(pickerPos)
                        }

                        // Add branch button for selected node (when picker not open)
                        if let selID = selectedNodeID,
                           presetPickerNodeID == nil,
                           let selNode = nodes.first(where: { $0.id == selID }) {
                            AddBranchButton(
                                parentPosition: CGPoint(x: selNode.position.x, y: selNode.position.y),
                                children: selNode.children,
                                color: Self.nodeColor(for: selNode, in: tree)
                            ) {
                                onAddBranch(selNode.id)
                            }
                        }
                    }
                    .offset(x: offset.x, y: offset.y)
                }
            }

            // "New tree" node
            if trees.count < 8, hasAnyContent() {
                let pos = newTreePosition()
                NewTreeNodeView()
                    .onTapGesture { onNewTreeTap() }
                    .popover(isPresented: $showNewTreePopover) {
                        NewTreePopoverView(
                            projectState: projectState,
                            onDismiss: { showNewTreePopover = false }
                        )
                    }
                    .position(x: pos.x, y: pos.y)
            }
        }
    }

    private func newTreePosition() -> CGPoint {
        guard let lastOffset = treeOffsets.last, let lastTree = trees.last else {
            return CGPoint(x: 160, y: 0)
        }
        let lastNodes = projectState.nodesForTree(lastTree.id)
        let maxX = lastNodes.map { CGFloat($0.position.x) }.max() ?? 0
        return CGPoint(x: lastOffset.x + maxX + 120, y: 0)
    }

    private func hasAnyContent() -> Bool {
        trees.first.map { !$0.rootNode.sequence.notes.isEmpty || !$0.rootNode.children.isEmpty } ?? false
    }

}

// MARK: - TreeConnectorLines

/// Subtle dashed lines connecting adjacent tree roots at their ring edges.
private struct TreeConnectorLines: View {
    let trees: [NodeTree]
    let treeOffsets: [CGPoint]

    var body: some View {
        Canvas { context, size in
            let ringEdge = NodeMetrics.ringRadius + NodeMetrics.playheadDotRadius + 2
            for i in 0..<(trees.count - 1) {
                guard i + 1 < treeOffsets.count else { continue }
                let rootA = trees[i].rootNode.position
                let rootB = trees[i + 1].rootNode.position
                let ax = treeOffsets[i].x + rootA.x
                let ay = treeOffsets[i].y + rootA.y
                let bx = treeOffsets[i + 1].x + rootB.x
                let by = treeOffsets[i + 1].y + rootB.y

                let dx = bx - ax
                let dy = by - ay
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > ringEdge * 2 else { continue }

                let nx = dx / dist
                let ny = dy / dist
                let startX = ax + nx * ringEdge
                let startY = ay + ny * ringEdge
                let endX = bx - nx * ringEdge
                let endY = by - ny * ringEdge

                var path = Path()
                path.move(to: CGPoint(x: startX, y: startY))
                path.addLine(to: CGPoint(x: endX, y: endY))
                context.stroke(
                    path,
                    with: .color(CanopyColors.branchLine.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 5])
                )
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - NewTreeNodeView

private struct NewTreeNodeView: View {
    @State private var breathing: Bool = false

    private let circleSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .stroke(
                    CanopyColors.glowColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .frame(width: circleSize, height: circleSize)
                .opacity(breathing ? 0.7 : 0.3)

            Text("new")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.nodeLabel.opacity(0.5))
        }
        .frame(width: 80, height: 80)
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

// MARK: - InlineTreeRenameField

private struct InlineTreeRenameField: View {
    @Binding var name: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $name)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundColor(CanopyColors.chromeTextBright)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .frame(width: 100, height: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CanopyColors.bloomPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(CanopyColors.glowColor.opacity(0.5), lineWidth: 1)
            )
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
    }
}

// MARK: - InlineNodeRenameField

private struct InlineNodeRenameField: View {
    @Binding var name: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $name)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundColor(CanopyColors.chromeTextBright)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .frame(width: 100, height: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CanopyColors.bloomPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(CanopyColors.glowColor.opacity(0.5), lineWidth: 1)
            )
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { onCommit() }
            .onExitCommand { onCancel() }
    }
}
