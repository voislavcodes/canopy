import Foundation
import SwiftUI

/// Tracks which level of the UI hierarchy is visible.
enum ViewMode: Equatable {
    case forest                    // Horizontal tree line
    case treeDetail(treeID: UUID)  // Single tree's node hierarchy (canvas)
    case focus(nodeID: UUID)       // Single panel full-screen
    case meadow                    // Mixer view (channel strips per branch)
}

/// Manages transitions between Forest, Tree Detail, and Focus view modes.
/// Injected as an `@EnvironmentObject` so any view can trigger mode switches.
class ViewModeManager: ObservableObject {
    @Published var mode: ViewMode = .forest

    var isForest: Bool {
        if case .forest = mode { return true }
        return false
    }

    var isTreeDetail: Bool {
        if case .treeDetail = mode { return true }
        return false
    }

    var treeDetailID: UUID? {
        if case .treeDetail(let id) = mode { return id }
        return nil
    }

    var isMeadow: Bool {
        if case .meadow = mode { return true }
        return false
    }

    var focusedNodeID: UUID? {
        if case .focus(let id) = mode { return id }
        return nil
    }

    /// Enter tree detail view (single tree's node hierarchy).
    func enterTreeDetail(treeID: UUID) {
        mode = .treeDetail(treeID: treeID)
    }

    /// Exit tree detail back to forest.
    func exitTreeDetail() {
        mode = .forest
    }

    func enterFocus(nodeID: UUID) {
        mode = .focus(nodeID: nodeID)
    }

    /// Exit focus — returns to treeDetail if we came from there, else forest.
    func exitFocus() {
        mode = .forest
    }

    /// Exit focus back to tree detail for a specific tree.
    func exitFocusToTreeDetail(treeID: UUID) {
        mode = .treeDetail(treeID: treeID)
    }

    func enterMeadow() {
        mode = .meadow
    }

    func exitMeadow() {
        mode = .forest
    }
}
