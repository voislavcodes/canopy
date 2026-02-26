import Foundation

/// Manages multi-tree playback state with four traversal modes.
/// Tracks which tree is currently playing and which comes next.
class ForestPlaybackState: ObservableObject {
    @Published var playbackMode: TreePlaybackMode = .sequential
    @Published var transitionMode: TreeTransitionMode = .instant
    @Published var activeTreeID: UUID?    // Currently playing tree (during playback)
    @Published var nextTreeID: UUID?      // Next tree (for visual indicator)
    @Published var isLockedToTree: Bool = false  // When true, advance is paused — locked tree loops

    /// Ping-pong direction state. true = forward (→), false = backward (←).
    var pingPongForward: Bool = true

    enum TreePlaybackMode: String, CaseIterable {
        case sequential  // →
        case pingPong    // ↔
        case random      // ?
        case brownian    // ~

        var symbol: String {
            switch self {
            case .sequential: return "→"
            case .pingPong: return "↔"
            case .random: return "?"
            case .brownian: return "~"
            }
        }

        var displayName: String {
            switch self {
            case .sequential: return "Sequential"
            case .pingPong: return "Ping-pong"
            case .random: return "Random"
            case .brownian: return "Brownian"
            }
        }
    }

    enum TreeTransitionMode: String, CaseIterable {
        case instant
        case crossfade

        var displayName: String {
            switch self {
            case .instant: return "Instant"
            case .crossfade: return "Crossfade"
            }
        }
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

        nextTreeID = computeNextIndex(current: currentIdx, count: trees.count).map { trees[$0].id }
    }

    /// Check if a cycle has completed and advance to the next tree.
    /// Returns the new tree if an advance occurred, nil otherwise.
    @discardableResult
    func checkAndAdvance(clockSamples: Int64, sampleRate: Double, bpm: Double,
                         cycleLengthInBeats: Double, trees: [NodeTree]) -> NodeTree? {
        guard !isLockedToTree else { return nil }
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

        guard let nextIdx = computeNextIndex(current: currentIdx, count: trees.count) else {
            return nil
        }

        // Update ping-pong direction after computing index
        if playbackMode == .pingPong {
            if nextIdx == trees.count - 1 {
                pingPongForward = false
            } else if nextIdx == 0 {
                pingPongForward = true
            }
        }

        let newTree = trees[nextIdx]
        activeTreeID = newTree.id
        computeNextTree(trees: trees)
        return newTree
    }

    // MARK: - Private

    /// Compute the next tree index based on the current playback mode.
    /// Returns nil if no valid next tree (shouldn't happen with count >= 2).
    private func computeNextIndex(current: Int, count: Int) -> Int? {
        guard count >= 2 else { return nil }

        switch playbackMode {
        case .sequential:
            return (current + 1) % count

        case .pingPong:
            if pingPongForward {
                if current + 1 < count {
                    return current + 1
                } else {
                    // At end, reverse
                    return max(0, current - 1)
                }
            } else {
                if current - 1 >= 0 {
                    return current - 1
                } else {
                    // At start, go forward
                    return min(count - 1, current + 1)
                }
            }

        case .random:
            // Pick any tree except current
            var next = Int.random(in: 0..<count - 1)
            if next >= current { next += 1 }
            return next

        case .brownian:
            // 33/33/33 stay/left/right. At edges: 50/50 stay/inward.
            let roll = Int.random(in: 0..<3)
            if current == 0 {
                // Left edge: 50% stay, 50% right
                return roll < 1 ? current : current + 1
            } else if current == count - 1 {
                // Right edge: 50% stay, 50% left
                return roll < 1 ? current : current - 1
            } else {
                switch roll {
                case 0: return current       // stay
                case 1: return current - 1   // left
                default: return current + 1  // right
                }
            }
        }
    }
}
