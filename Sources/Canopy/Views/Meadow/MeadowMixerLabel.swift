import SwiftUI

/// Volume/pan readout + solo/mute buttons for a tree in Meadow.
struct MeadowMixerLabel: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    private var treeColor: Color { tree.driftedColor }

    var body: some View {
        VStack(spacing: 2) {
            Text(volumePanText)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

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

    private var volumePanText: String {
        let volPct = Int(tree.volume * 100)
        let panStr: String
        if abs(tree.pan) < 0.01 {
            panStr = "C"
        } else if tree.pan < 0 {
            panStr = "L\(Int(abs(tree.pan) * 100))"
        } else {
            panStr = "R\(Int(tree.pan * 100))"
        }
        return "\(volPct)% \u{00B7} \(panStr)"
    }
}
