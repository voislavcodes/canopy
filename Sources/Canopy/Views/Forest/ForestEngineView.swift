import SwiftUI

/// Dispatches to the correct engine panel based on the node's `SoundType`.
/// Engine bloom panel for forest/canvas mode.
/// between Forest (bloom) and Focus modes.
struct ForestEngineView: View {
    @ObservedObject var projectState: ProjectState
    let accentColor: Color

    var body: some View {
        if let node = projectState.selectedNode {
            enginePanel(for: node)
        }
    }

    @ViewBuilder
    private func enginePanel(for node: Node) -> some View {
        switch node.patch.soundType {
        case .quake:
            QuakePanel(projectState: projectState, accentColor: accentColor)
        case .drumKit:
            DrumVoicePanel(projectState: projectState, accentColor: accentColor)
        case .westCoast:
            WestCoastPanel(projectState: projectState, accentColor: accentColor)
        case .flow:
            FlowPanel(projectState: projectState, accentColor: accentColor)
        case .tide:
            TidePanel(projectState: projectState, accentColor: accentColor)
        case .swarm:
            SwarmPanel(projectState: projectState, accentColor: accentColor)
        case .spore:
            SporePanel(projectState: projectState, accentColor: accentColor)
        case .fuse:
            FusePanel(projectState: projectState, accentColor: accentColor)
        case .volt:
            VoltPanel(projectState: projectState, accentColor: accentColor)
        case .schmynth:
            SchmynthPanel(projectState: projectState, accentColor: accentColor)
        default:
            SynthControlsPanel(projectState: projectState, accentColor: accentColor)
        }
    }
}
