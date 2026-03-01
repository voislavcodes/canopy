import Foundation
import SwiftUI

/// Tracks which level of the UI hierarchy is visible.
enum ViewMode: Equatable {
    case forest                    // Forest canvas — all trees with full node hierarchies
    case focus(nodeID: UUID)       // Single panel full-screen
    case meadow                    // Mixer view (channel strips per branch)
}

/// Manages transitions between Forest, Focus, and Meadow view modes.
/// Injected as an `@EnvironmentObject` so any view can trigger mode switches.
class ViewModeManager: ObservableObject {
    @Published var mode: ViewMode = .forest

    var isForest: Bool {
        if case .forest = mode { return true }
        return false
    }

    var isMeadow: Bool {
        if case .meadow = mode { return true }
        return false
    }

    var focusedNodeID: UUID? {
        if case .focus(let id) = mode { return id }
        return nil
    }

    func enterFocus(nodeID: UUID) {
        mode = .focus(nodeID: nodeID)
    }

    /// Exit focus — returns to forest.
    func exitFocus() {
        mode = .forest
    }

    func enterMeadow() {
        mode = .meadow
    }

    func exitMeadow() {
        mode = .forest
    }
}
