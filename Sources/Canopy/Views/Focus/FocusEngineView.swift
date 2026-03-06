import SwiftUI

/// Focus-mode engine view. Phase 1: wraps `ForestEngineView` with expanded frame.
/// Phase 2 will diverge with full circuit schematic, all parameters, etc.
struct FocusEngineView: View {
    @ObservedObject var projectState: ProjectState

    private var accentColor: Color {
        guard let nodeID = projectState.selectedNodeID,
              let treeID = projectState.selectedTreeID,
              let tree = projectState.project.trees.first(where: { $0.id == treeID }) else {
            return CanopyColors.nodeSeed
        }
        return SeedColor.colorForNode(nodeID, in: tree)
    }

    var body: some View {
        ForestEngineView(projectState: projectState, accentColor: accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
