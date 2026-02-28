import SwiftUI

/// Top-level mixer view showing channel strips for ALL trees + master strip.
/// All channel strips flow left to right in one horizontal row, grouped by tree.
struct MeadowView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        let trees = projectState.project.trees

        HStack(spacing: 0) {
            if trees.isEmpty {
                emptyState
            } else {
                let hasAnyBranches = trees.contains { !flatBranches(tree: $0).isEmpty }
                if !hasAnyBranches {
                    emptyState
                } else {
                    // Single horizontal scroll — all trees' strips in one row
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(trees.enumerated()), id: \.element.id) { index, tree in
                                let branches = flatBranches(tree: tree)
                                if !branches.isEmpty {
                                    if index > 0 {
                                        // Vertical divider between tree groups
                                        Rectangle()
                                            .fill(CanopyColors.chromeBorder.opacity(0.4))
                                            .frame(width: 1)
                                            .padding(.vertical, 8)
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
