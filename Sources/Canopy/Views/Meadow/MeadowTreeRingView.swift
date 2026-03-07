import SwiftUI

/// Composes dual rings + MIDI shape + core dot + labels for a single tree in Meadow.
struct MeadowTreeRingView: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    private var treeColor: Color { tree.driftedColor }

    private var isSelected: Bool {
        projectState.selectedTreeID == tree.id
    }

    var body: some View {
        let anyTreeSoloed = projectState.project.trees.contains { $0.isSolo }
        let dimmed = tree.isMuted || (anyTreeSoloed && !tree.isSolo)
        let dimOpacity: Double = tree.isMuted ? 0.35 : (dimmed ? 0.15 : 1.0)

        VStack(spacing: 6) {
            ZStack {
                // Selection glow
                if isSelected {
                    NodeGlowEffect(radius: MeadowMetrics.outerRingRadius, color: treeColor)
                }

                // Selection ring overlay
                if isSelected {
                    Circle()
                        .stroke(treeColor.opacity(0.4), lineWidth: 2)
                        .frame(
                            width: MeadowMetrics.outerRingRadius * 2 + 6,
                            height: MeadowMetrics.outerRingRadius * 2 + 6
                        )
                }

                // Outer ring — Pan
                MeadowPanRing(tree: tree, projectState: projectState)

                // Inner ring — Volume + Loudness
                MeadowVolumeRing(tree: tree, projectState: projectState)

                // MIDI fingerprint (root node)
                MIDIShapeView(
                    notes: tree.rootNode.sequence.notes,
                    lengthInBeats: tree.rootNode.sequence.lengthInBeats,
                    color: treeColor,
                    params: MIDIShapeParams(from: tree.rootNode.sequence)
                )

                // Core dot
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [treeColor, treeColor.opacity(0.4)],
                            center: .center,
                            startRadius: 2,
                            endRadius: 14
                        )
                    )
                    .frame(width: 28, height: 28)
            }

            // Label stack
            MeadowTreeLabel(tree: tree, projectState: projectState)
        }
        .opacity(dimOpacity)
        .onTapGesture {
            projectState.selectTree(tree.id)
        }
    }
}

/// Tree name + volume/pan readout + solo/mute buttons.
struct MeadowTreeLabel: View {
    let tree: NodeTree
    @ObservedObject var projectState: ProjectState

    private var treeColor: Color { tree.driftedColor }

    var body: some View {
        VStack(spacing: 2) {
            Text(tree.name.lowercased())
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(treeColor)

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
