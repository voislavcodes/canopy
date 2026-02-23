import SwiftUI

/// Focus-mode sequencer view. Phase 1: wraps `ForestSequencerView` with expanded frame.
/// Phase 2 will add per-step probability bars, velocity editing, micro-timing, multi-select transforms.
struct FocusSequencerView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        ForestSequencerView(projectState: projectState, transportState: transportState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
