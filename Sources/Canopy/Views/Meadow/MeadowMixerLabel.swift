import SwiftUI

/// Volume/pan readout + solo/mute buttons for a tree in Meadow.
struct MeadowMixerLabel: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    private var treeColor: Color { tree.driftedColor }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Text("S")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(tree.isSolo ? treeColor.opacity(0.9) : CanopyColors.chromeText.opacity(0.2))
                    .onTapGesture {
                        projectState.selectTree(tree.id)
                        projectState.toggleTreeSolo(treeID: tree.id)
                    }

                Text("M")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(tree.isMuted ? treeColor.opacity(0.9) : CanopyColors.chromeText.opacity(0.2))
                    .onTapGesture {
                        projectState.selectTree(tree.id)
                        projectState.toggleTreeMute(treeID: tree.id)
                    }
            }
        }
    }

}
