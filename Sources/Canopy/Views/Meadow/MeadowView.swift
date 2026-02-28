import SwiftUI

/// Top-level mixer view showing channel strips for ALL trees + master strip.
struct MeadowView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        let trees = projectState.project.trees

        HStack(spacing: 0) {
            if trees.isEmpty {
                emptyState
            } else {
                let allBranches = trees.flatMap { flatBranches(tree: $0) }
                if allBranches.isEmpty {
                    emptyState
                } else {
                    // Scrollable tree groups (vertical scroll for many trees,
                    // horizontal scroll within each group for many branches)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                                let branches = flatBranches(tree: tree)
                                if !branches.isEmpty {
                                    if index > 0 {
                                        // Subtle divider between tree groups
                                        Rectangle()
                                            .fill(CanopyColors.chromeBorder.opacity(0.4))
                                            .frame(height: 1)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                    }
                                    TreeGroupView(
                                        tree: tree,
                                        branches: branches,
                                        projectState: projectState,
                                        transportState: transportState
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
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
