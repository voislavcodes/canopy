import SwiftUI

/// Focus-mode keyboard/input view. Phase 1: wraps `ForestKeyboardView` with full-width frame.
/// Phase 2 will add wider octave range.
struct FocusKeyboardView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    var body: some View {
        ForestKeyboardView(projectState: projectState, transportState: transportState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
