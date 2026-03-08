import SwiftUI

/// Shared layout utilities for Forest and Meadow canvas views.
enum CanvasLayout {
    /// Compute horizontal offsets for each tree so they don't overlap.
    /// Each tree's nodes use local coordinates (root at 0,0). The offset positions
    /// trees left-to-right with enough spacing for their node extents.
    static func computeTreeOffsets(trees: [NodeTree]) -> [CGPoint] {
        guard !trees.isEmpty else { return [] }

        // Compute horizontal extent of each tree
        var extents: [(minX: CGFloat, maxX: CGFloat)] = []
        for tree in trees {
            let nodes = collectNodes(from: tree.rootNode)
            let xs = nodes.map { CGFloat($0.position.x) }
            let minX = (xs.min() ?? 0) - 100  // pad for outer ring radius (86) + L/R labels
            let maxX = (xs.max() ?? 0) + 100
            extents.append((minX, maxX))
        }

        // Place trees sequentially with gaps
        let gap: CGFloat = 80
        var offsets: [CGPoint] = []
        var cursor: CGFloat = 0

        for (i, ext) in extents.enumerated() {
            if i == 0 {
                // First tree: center its local coordinates at cursor
                let centerX = -ext.minX  // shifts so minX lands at 0
                cursor = centerX + ext.maxX + gap
                offsets.append(CGPoint(x: centerX, y: 0))
            } else {
                // Next tree starts after cursor, shifted so its minX aligns at cursor
                let x = cursor - ext.minX
                cursor = x + ext.maxX + gap
                offsets.append(CGPoint(x: x, y: 0))
            }
        }

        // Center the whole set
        let totalMin = offsets.enumerated().map { (i, o) in o.x + extents[i].minX }.min() ?? 0
        let totalMax = offsets.enumerated().map { (i, o) in o.x + extents[i].maxX }.max() ?? 0
        let totalCenter = (totalMin + totalMax) / 2
        return offsets.map { CGPoint(x: $0.x - totalCenter, y: $0.y) }
    }

    /// Recursively collect all nodes from a root node into a flat array.
    static func collectNodes(from node: Node) -> [Node] {
        var result: [Node] = []
        collectNodesRecursive(from: node, into: &result)
        return result
    }

    private static func collectNodesRecursive(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodesRecursive(from: child, into: &result)
        }
    }
}
