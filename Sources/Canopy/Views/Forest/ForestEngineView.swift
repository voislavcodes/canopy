import SwiftUI

/// Dispatches to the correct engine panel based on the node's `SoundType`.
/// Extracted from `CanopyCanvasView` to eliminate duplicate dispatch logic
/// between Forest (bloom) and Focus modes.
struct ForestEngineView: View {
    @ObservedObject var projectState: ProjectState

    var body: some View {
        if let node = projectState.selectedNode {
            enginePanel(for: node)
        }
    }

    @ViewBuilder
    private func enginePanel(for node: Node) -> some View {
        switch node.patch.soundType {
        case .quake:
            QuakePanel(projectState: projectState)
        case .drumKit:
            DrumVoicePanel(projectState: projectState)
        case .westCoast:
            WestCoastPanel(projectState: projectState)
        case .flow:
            FlowPanel(projectState: projectState)
        case .tide:
            TidePanel(projectState: projectState)
        case .swarm:
            SwarmPanel(projectState: projectState)
        case .spore:
            SporePanel(projectState: projectState)
        case .fuse:
            FusePanel(projectState: projectState)
        case .volt:
            VoltPanel(projectState: projectState)
        case .schmynth:
            SchmynthPanel(projectState: projectState)
        default:
            SynthControlsPanel(projectState: projectState)
        }
    }
}
