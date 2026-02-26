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
    @State private var lastTreeTapID: UUID?
    @State private var lastTreeTapTime: Date?
    @State private var showNewTreePopover = false

    private let treeSpacing: CGFloat = 160
    private let dotSpacing: CGFloat = 40
    private let dotSize: CGFloat = 2
    private let canvasCornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            let trees = projectState.project.trees
            let selectedTreeID = projectState.selectedTreeID

            ZStack {
                // Layer 0: background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Layer 1: canvas area with dot grid + border
                canvasArea(viewSize: viewSize)

                // Layer 2: scaled content — trees, lines, new node
                ForestContentView(
                    trees: trees,
                    selectedTreeID: selectedTreeID,
                    activeTreeID: forestPlayback.activeTreeID,
                    nextTreeID: forestPlayback.nextTreeID,
                    isPlaying: transportState.isPlaying,
                    treeSpacing: treeSpacing,
                    editingTreeID: editingTreeID,
                    showNewTreePopover: $showNewTreePopover,
                    projectState: projectState,
                    onTreeTap: { treeID in handleTreeTap(treeID) },
                    onNewTreeTap: { handleNewTreeTap() }
                )
                .offset(CGSize(width: viewSize.width / 2, height: viewSize.height / 2))
                .offset(canvasState.offset)
                .scaleEffect(canvasState.scale)

                // Layer 3: Bloom panels for selected tree's root node
                if let tree = projectState.selectedTree,
                   projectState.selectedNodeID != nil {
                    forestBloomContent(node: tree.rootNode, viewSize: viewSize)
                }

                // Layer 3.5: Inline rename overlay
                if let editID = editingTreeID,
                   let treeIdx = projectState.project.trees.firstIndex(where: { $0.id == editID }) {
                    let pos = treePosition(index: treeIdx, total: trees.count)
                    let screenPos = canvasToScreen(
                        CGPoint(x: pos.x, y: pos.y + 46),
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
            .onAppear { installScrollMonitor(); installKeyMonitor() }
            .onDisappear { removeScrollMonitor(); removeKeyMonitor() }
        }
    }

    // MARK: - Layout Math

    private func treePosition(index: Int, total: Int) -> CGPoint {
        let startX = -CGFloat(total - 1) * treeSpacing / 2
        return CGPoint(x: startX + CGFloat(index) * treeSpacing, y: 0)
    }

    private func newTreePosition(treeCount: Int) -> CGPoint {
        let startX = -CGFloat(treeCount - 1) * treeSpacing / 2
        return CGPoint(x: startX + CGFloat(treeCount) * treeSpacing, y: 0)
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

    // MARK: - Bloom Content for Forest (screen space)

    @ViewBuilder
    private func forestBloomContent(node: Node, viewSize: CGSize) -> some View {
        if let treeIdx = projectState.project.trees.firstIndex(where: { $0.id == projectState.selectedTreeID }) {
            let treePt = treePosition(index: treeIdx, total: projectState.project.trees.count)
            let nodeScreen = canvasToScreen(treePt, viewSize: viewSize)

            let synthOffset = CGPoint(x: -330, y: -100)
            let seqOffset = CGPoint(x: 260, y: -100)
            let keyboardOffset = CGPoint(x: 0, y: 205)

            let synthUserOffset = bloomState.storedOffset(panel: .synth, nodeID: node.id)
            let seqUserOffset = bloomState.storedOffset(panel: .sequencer, nodeID: node.id)
            let keyboardUserOffset = bloomState.storedOffset(panel: .input, nodeID: node.id)

            let synthCanvas = CGPoint(
                x: treePt.x + synthOffset.x + synthUserOffset.width,
                y: treePt.y + synthOffset.y + synthUserOffset.height
            )
            let seqCanvas = CGPoint(
                x: treePt.x + seqOffset.x + seqUserOffset.width,
                y: treePt.y + seqOffset.y + seqUserOffset.height
            )
            let keyboardCanvas = CGPoint(
                x: treePt.x + keyboardOffset.x + keyboardUserOffset.width,
                y: treePt.y + keyboardOffset.y + keyboardUserOffset.height
            )

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
                    ForestEngineView(projectState: projectState)
                }

                DraggableBloomPanel(panel: .sequencer, nodeID: node.id, bloomState: bloomState, canvasScale: scale, screenPosition: seqScreen) {
                    ForestSequencerView(projectState: projectState, transportState: transportState)
                }

                DraggableBloomPanel(panel: .input, nodeID: node.id, bloomState: bloomState, canvasScale: scale, screenPosition: keyboardScreen) {
                    ForestKeyboardView(projectState: projectState, transportState: transportState)
                }
            }
        }
    }

    // MARK: - Interactions

    private func handleTreeTap(_ treeID: UUID) {
        let now = Date()
        // Double-tap detection
        if let lastID = lastTreeTapID, lastID == treeID,
           let lastTime = lastTreeTapTime, now.timeIntervalSince(lastTime) < 0.35 {
            // Double-tap → enter tree detail
            lastTreeTapTime = nil
            lastTreeTapID = nil
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                viewModeManager.enterTreeDetail(treeID: treeID)
            }
        } else {
            // Single tap → select tree
            projectState.selectTree(treeID)
            lastTreeTapTime = now
            lastTreeTapID = treeID
        }
    }

    private func handleNewTreeTap() {
        showNewTreePopover = true
    }

    private func handleTap(at location: CGPoint, viewSize: CGSize) {
        let canvas = screenToCanvas(location, viewSize: viewSize)
        let hitRadius: CGFloat = 30
        let trees = projectState.project.trees

        // Hit test tree circles
        for (i, tree) in trees.enumerated() {
            let pos = treePosition(index: i, total: trees.count)
            let dx = canvas.x - pos.x
            let dy = canvas.y - pos.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                handleTreeTap(tree.id)
                return
            }
        }

        // Hit test new tree node (only visible when first tree has content)
        let hasContent = trees.first.map { !$0.rootNode.sequence.notes.isEmpty || !$0.rootNode.children.isEmpty } ?? false
        if trees.count < 8, hasContent {
            let newPos = newTreePosition(treeCount: trees.count)
            let dx = canvas.x - newPos.x
            let dy = canvas.y - newPos.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                handleNewTreeTap()
                return
            }
        }

        // Background tap — deselect
        projectState.selectTree(nil)
        projectState.selectNode(nil)
        editingTreeID = nil
        projectState.selectedLFOID = nil
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

            // Enter → enter tree detail for selected tree
            if event.keyCode == 36, viewModeManager.isForest {
                guard let treeID = projectState.selectedTreeID else { return event }
                DispatchQueue.main.async {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        viewModeManager.enterTreeDetail(treeID: treeID)
                    }
                }
                return nil
            }

            // Delete/Backspace → remove selected tree
            if event.keyCode == 51 || event.keyCode == 117 {
                guard viewModeManager.isForest,
                      let treeID = projectState.selectedTreeID,
                      projectState.project.trees.count > 1 else { return event }
                DispatchQueue.main.async {
                    // Fade out audio then teardown for the tree being removed
                    AudioEngine.shared.teardownGraphWithFade()
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        projectState.removeTree(id: treeID)
                    }
                    // Rebuild audio for newly selected tree
                    if let newTree = projectState.selectedTree {
                        AudioEngine.shared.buildGraph(from: newTree)
                        AudioEngine.shared.configureAllPatches(from: newTree)
                        AudioEngine.shared.loadAllSequences(from: newTree, bpm: projectState.project.bpm)
                    }
                }
                return nil
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

// MARK: - ForestContentView (value-type inputs)

private struct ForestContentView: View {
    let trees: [NodeTree]
    let selectedTreeID: UUID?
    let activeTreeID: UUID?
    let nextTreeID: UUID?
    let isPlaying: Bool
    let treeSpacing: CGFloat
    let editingTreeID: UUID?
    @Binding var showNewTreePopover: Bool
    var projectState: ProjectState
    let onTreeTap: (UUID) -> Void
    let onNewTreeTap: () -> Void

    var body: some View {
        ZStack {
            // Connecting line between trees
            if trees.count > 1 {
                ForestConnectorLine(
                    treeCount: trees.count,
                    treeSpacing: treeSpacing
                )
            }

            // Tree circles
            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                let pos = treePosition(index: index, total: trees.count)
                TreeCircleView(
                    tree: tree,
                    isSelected: selectedTreeID == tree.id,
                    isActive: activeTreeID == tree.id,
                    isNext: nextTreeID == tree.id,
                    isPlaying: isPlaying
                )
                .onTapGesture { onTreeTap(tree.id) }
                .position(x: pos.x, y: pos.y)
            }

            // "New tree" node with variation popover
            if trees.count < 8, hasAnyContent() {
                let pos = newTreePosition(treeCount: trees.count)
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

    private func treePosition(index: Int, total: Int) -> CGPoint {
        let startX = -CGFloat(total - 1) * treeSpacing / 2
        return CGPoint(x: startX + CGFloat(index) * treeSpacing, y: 0)
    }

    private func newTreePosition(treeCount: Int) -> CGPoint {
        let startX = -CGFloat(treeCount - 1) * treeSpacing / 2
        return CGPoint(x: startX + CGFloat(treeCount) * treeSpacing, y: 0)
    }

    private func hasAnyContent() -> Bool {
        trees.first.map { !$0.rootNode.sequence.notes.isEmpty || !$0.rootNode.children.isEmpty } ?? false
    }
}

// MARK: - TreeCircleView

private struct TreeCircleView: View {
    let tree: NodeTree
    let isSelected: Bool
    let isActive: Bool
    let isNext: Bool
    let isPlaying: Bool

    private let circleSize: CGFloat = 44

    private var treeColor: Color {
        if let pid = tree.rootNode.presetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color)
        }
        return CanopyColors.nodeSeed
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Selection glow
                if isSelected {
                    NodeGlowEffect(radius: circleSize / 2, color: treeColor)
                }

                // Next-tree soft glow during playback
                if isNext && isPlaying {
                    Circle()
                        .fill(treeColor.opacity(0.08))
                        .frame(width: circleSize * 2.5, height: circleSize * 2.5)
                        .blur(radius: 10)
                }

                // Main circle
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [treeColor, treeColor.opacity(0.8)],
                            center: .center,
                            startRadius: 0,
                            endRadius: circleSize / 2
                        )
                    )
                    .frame(width: circleSize, height: circleSize)
            }

            // Name label
            Text(tree.name.lowercased())
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.nodeLabel)
                .lineLimit(1)
        }
        .frame(width: 80, height: 80)
        .contentShape(Rectangle())
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

// MARK: - ForestConnectorLine

private struct ForestConnectorLine: View {
    let treeCount: Int
    let treeSpacing: CGFloat

    var body: some View {
        Canvas { context, _ in
            guard treeCount > 1 else { return }
            let startX = -CGFloat(treeCount - 1) * treeSpacing / 2
            var path = Path()
            path.move(to: CGPoint(x: startX, y: 0))
            path.addLine(to: CGPoint(x: startX + CGFloat(treeCount - 1) * treeSpacing, y: 0))
            context.stroke(
                path,
                with: .color(CanopyColors.branchLine.opacity(0.5)),
                style: StrokeStyle(lineWidth: 1.5)
            )
        }
        .allowsHitTesting(false)
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
