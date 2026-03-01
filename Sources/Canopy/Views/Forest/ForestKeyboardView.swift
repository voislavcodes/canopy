import SwiftUI

/// Dispatches to the correct input panel based on the node's effective `InputMode`.
/// Keyboard bloom panel for forest/canvas mode.
struct ForestKeyboardView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        if let node = projectState.selectedNode {
            let inputMode = effectiveInputMode(for: node)
            inputPanel(for: inputMode)
        }
    }

    @ViewBuilder
    private func inputPanel(for mode: InputMode) -> some View {
        switch mode {
        case .padGrid:
            DrumPadGridView(
                selectedNodeID: projectState.selectedNodeID,
                projectState: projectState,
                transportState: transportState
            )
        case .keyboard:
            KeyboardBarView(
                baseOctave: $projectState.keyboardOctave,
                selectedNodeID: projectState.selectedNodeID,
                projectState: projectState,
                transportState: transportState
            )
        }
    }

    /// Resolve the effective input mode from the node's override or SoundType default.
    static func effectiveInputMode(for node: Node) -> InputMode {
        if let override = node.inputMode { return override }
        switch node.patch.soundType {
        case .drumKit, .quake, .volt: return .padGrid
        default: return .keyboard
        }
    }

    private func effectiveInputMode(for node: Node) -> InputMode {
        Self.effectiveInputMode(for: node)
    }
}
