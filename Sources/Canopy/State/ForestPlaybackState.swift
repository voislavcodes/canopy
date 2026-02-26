import Foundation

/// Manages multi-tree sequential playback state.
/// Tracks which tree is currently playing and which comes next.
class ForestPlaybackState: ObservableObject {
    @Published var playbackMode: TreePlaybackMode = .sequential
    @Published var transitionMode: TreeTransitionMode = .instant
    @Published var activeTreeID: UUID?    // Currently playing tree (during playback)
    @Published var nextTreeID: UUID?      // Next tree (for visual indicator)

    enum TreePlaybackMode: String, CaseIterable {
        case sequential  // →
    }

    enum TreeTransitionMode: String, CaseIterable {
        case instant
    }

    // MARK: - Advance Logic

    /// Compute the next tree ID from the current active tree.
    func computeNextTree(trees: [NodeTree]) {
        guard let activeID = activeTreeID,
              let currentIdx = trees.firstIndex(where: { $0.id == activeID }),
              trees.count >= 2 else {
            nextTreeID = nil
            return
        }
        let nextIdx = (currentIdx + 1) % trees.count
        nextTreeID = trees[nextIdx].id
    }

    /// Check if a cycle has completed and advance to the next tree.
    /// Returns the new tree if an advance occurred, nil otherwise.
    @discardableResult
    func checkAndAdvance(clockSamples: Int64, sampleRate: Double, bpm: Double,
                         cycleLengthInBeats: Double, trees: [NodeTree]) -> NodeTree? {
        guard trees.count >= 2, activeTreeID != nil else { return nil }

        let beat = Double(clockSamples) * bpm / (60.0 * sampleRate)
        guard beat >= cycleLengthInBeats else { return nil }

        return advanceToNextTree(trees: trees)
    }

    /// Advance to the next tree based on the current playback mode.
    @discardableResult
    func advanceToNextTree(trees: [NodeTree]) -> NodeTree? {
        guard let activeID = activeTreeID,
              let currentIdx = trees.firstIndex(where: { $0.id == activeID }),
              trees.count >= 2 else { return nil }

        let nextIdx: Int
        switch playbackMode {
        case .sequential:
            nextIdx = (currentIdx + 1) % trees.count
        }

        let newTree = trees[nextIdx]
        activeTreeID = newTree.id
        computeNextTree(trees: trees)
        return newTree
    }
}
