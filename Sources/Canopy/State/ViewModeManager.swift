import Foundation
import SwiftUI

/// Tracks whether the app is in Forest mode (canvas + bloom panels) or Focus mode
/// (single expanded module filling the content area).
enum ViewMode: Equatable {
    case forest
    case focus(nodeID: UUID)
}

/// Manages transitions between Forest and Focus view modes.
/// Injected as an `@EnvironmentObject` so any view can trigger mode switches.
class ViewModeManager: ObservableObject {
    @Published var mode: ViewMode = .forest

    var isForest: Bool {
        if case .forest = mode { return true }
        return false
    }

    var focusedNodeID: UUID? {
        if case .focus(let id) = mode { return id }
        return nil
    }

    func enterFocus(nodeID: UUID) {
        mode = .focus(nodeID: nodeID)
    }

    func exitFocus() {
        mode = .forest
    }
}
