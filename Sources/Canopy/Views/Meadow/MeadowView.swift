import SwiftUI

/// Meadow mixer view: dual-ring controls around tree shapes with SHORE master at far right.
struct MeadowView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @EnvironmentObject var viewModeManager: ViewModeManager

    @State private var keyMonitor: Any?

    var body: some View {
        let trees = projectState.project.trees

        GeometryReader { geo in
            ZStack {
                CanopyColors.canvasBackground

                // Click empty to deselect
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { projectState.selectTree(nil) }

                if trees.isEmpty {
                    emptyState
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .center, spacing: treeSpacing(count: trees.count, width: geo.size.width)) {
                            ForEach(trees) { tree in
                                MeadowTreeRingView(
                                    tree: tree,
                                    projectState: projectState,
                                    transportState: transportState
                                )
                            }

                            // Separator
                            Rectangle()
                                .fill(CanopyColors.chromeBorder.opacity(0.4))
                                .frame(width: 1, height: 160)

                            // SHORE master
                            MeadowShoreView(projectState: projectState)
                        }
                        .padding(.horizontal, 32)
                        .frame(minHeight: geo.size.height)
                    }
                }
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

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

    /// Adaptive spacing between tree rings based on available width.
    private func treeSpacing(count: Int, width: CGFloat) -> CGFloat {
        let ringWidth: CGFloat = MeadowMetrics.outerRingRadius * 2 + 24
        let totalRings = CGFloat(count + 1) * ringWidth // +1 for SHORE
        let available = width - totalRings - 64 // padding
        let spacing = max(24, available / CGFloat(count + 1))
        return min(spacing, 60)
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
