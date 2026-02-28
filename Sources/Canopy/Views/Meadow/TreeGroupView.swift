import SwiftUI

/// Tree name header + channel strips for each branch, laid out as a vertical column.
/// The header sits above, strips flow horizontally below it.
struct TreeGroupView: View {
    let tree: NodeTree
    let branches: [Node]
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    @State private var isCollapsed = false

    private var treeColor: Color {
        if let pid = tree.rootNode.presetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color)
        }
        return CanopyColors.nodeSeed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Compact tree header
            HStack(spacing: 4) {
                Text(isCollapsed ? "▶" : "▼")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                Circle()
                    .fill(treeColor)
                    .frame(width: 6, height: 6)
                Text(tree.name.lowercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
            }
            .padding(.horizontal, 4)
            .onTapGesture { isCollapsed.toggle() }

            if !isCollapsed {
                HStack(spacing: 1) {
                    ForEach(branches) { node in
                        ChannelStripView(
                            node: node,
                            projectState: projectState,
                            transportState: transportState
                        )
                    }
                }
            }
        }
    }
}
