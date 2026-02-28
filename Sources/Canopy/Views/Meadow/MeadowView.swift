import SwiftUI

/// Top-level mixer view showing channel strips for the active tree's branches + master strip.
struct MeadowView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        let tree = projectState.selectedTree ?? projectState.project.trees.first

        HStack(spacing: 0) {
            if let tree = tree {
                let branches = flatBranches(tree: tree)
                if branches.isEmpty {
                    emptyState
                } else {
                    // Scrollable branch strips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            TreeGroupView(
                                tree: tree,
                                branches: branches,
                                projectState: projectState,
                                transportState: transportState
                            )
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
            } else {
                emptyState
            }

            // Divider
            Rectangle()
                .fill(CanopyColors.chromeBorder)
                .frame(width: 1)

            // Master strip (fixed right side)
            MasterStripView(projectState: projectState)
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
        }
        .background(CanopyColors.canvasBackground)
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

    /// Flatten tree into branch list: root node + its children (one level).
    private func flatBranches(tree: NodeTree) -> [Node] {
        var result: [Node] = [tree.rootNode]
        result.append(contentsOf: tree.rootNode.children)
        return result
    }
}
