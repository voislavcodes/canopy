import SwiftUI

/// Dispatches to the correct sequencer panel based on the node's effective `SequencerType`.
/// Sequencer bloom panel for forest/canvas mode.
struct ForestSequencerView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        if let node = projectState.selectedNode {
            let seqType = effectiveSequencerType(for: node)
            sequencerPanel(for: seqType)
        }
    }

    @ViewBuilder
    private func sequencerPanel(for seqType: SequencerType) -> some View {
        switch seqType {
        case .sporeSeq:
            SporeSeqPanel(projectState: projectState)
        case .orbit:
            OrbitSequencerPanel(projectState: projectState, transportState: transportState)
        case .drum:
            DrumSequencerPanel(projectState: projectState, transportState: transportState)
        case .pitched:
            ForestPitchedPanel(projectState: projectState, transportState: transportState)
        }
    }

    /// Resolve the effective sequencer type from the node's override or SoundType default.
    static func effectiveSequencerType(for node: Node) -> SequencerType {
        if let override = node.sequencerType { return override }
        switch node.patch.soundType {
        case .spore: return .sporeSeq
        case .drumKit, .quake, .volt: return .drum
        default: return .pitched
        }
    }

    private func effectiveSequencerType(for node: Node) -> SequencerType {
        Self.effectiveSequencerType(for: node)
    }
}
