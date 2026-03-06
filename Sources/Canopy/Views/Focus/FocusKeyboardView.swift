import SwiftUI

/// Focus-mode keyboard/input view. Phase 1: wraps `ForestKeyboardView` with full-width frame.
/// Phase 2 will add wider octave range.
struct FocusKeyboardView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    private var accentColor: Color {
        guard let nodeID = projectState.selectedNodeID,
              let treeID = projectState.selectedTreeID,
              let tree = projectState.project.trees.first(where: { $0.id == treeID }) else {
            return CanopyColors.nodeSeed
        }
        return SeedColor.colorForNode(nodeID, in: tree)
    }

    var body: some View {
        ForestKeyboardView(projectState: projectState, transportState: transportState, accentColor: accentColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
