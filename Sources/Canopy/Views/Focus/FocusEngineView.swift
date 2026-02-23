import SwiftUI

/// Focus-mode engine view. Phase 1: wraps `ForestEngineView` with expanded frame.
/// Phase 2 will diverge with full circuit schematic, all parameters, etc.
struct FocusEngineView: View {
    @ObservedObject var projectState: ProjectState

    var body: some View {
        ForestEngineView(projectState: projectState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
