import Foundation
import SwiftUI

/// Identifies a bloom panel type for offset/focus tracking.
enum BloomPanel: String, CaseIterable {
    case synth
    case sequencer
    case input
}

/// Per-node custom drag offsets for each bloom panel (canvas-space).
struct BloomPanelOffsets: Equatable {
    var offsets: [BloomPanel: CGSize]

    static let zero = BloomPanelOffsets(offsets: [:])

    func offset(for panel: BloomPanel) -> CGSize {
        offsets[panel] ?? .zero
    }

    mutating func setOffset(_ size: CGSize, for panel: BloomPanel) {
        offsets[panel] = size
    }
}

/// Ephemeral visual state for bloom panel positioning and focus.
/// Follows the CanvasState pattern — not persisted to .canopy files.
class BloomState: ObservableObject {
    /// Per-node custom offsets from dragging panels.
    @Published var panelOffsets: [UUID: BloomPanelOffsets] = [:]

    /// Which panel is in focus mode (nil = normal bloom layout).
    @Published var focusedPanel: BloomPanel?

    /// Stored offset for a panel (no live drag component).
    func storedOffset(panel: BloomPanel, nodeID: UUID) -> CGSize {
        panelOffsets[nodeID]?.offset(for: panel) ?? .zero
    }

    /// Exit focus mode.
    func unfocus() {
        focusedPanel = nil
    }

    /// Cycle focused panel by direction (-1 = left, +1 = right). Wraps around.
    func cycleFocusedPanel(direction: Int) {
        guard let current = focusedPanel else { return }
        let panels = BloomPanel.allCases
        guard let idx = panels.firstIndex(of: current) else { return }
        let next = (idx + direction + panels.count) % panels.count
        focusedPanel = panels[next]
    }

    // MARK: - Smart Initial Positioning

    /// Compute push-apart offsets for panels that overlap tree nodes.
    /// Returns non-zero offsets only for panels that actually collide.
    static func computeInitialOffsets(
        nodePosition: CGPoint,
        allNodes: [Node],
        selectedNodeID: UUID,
        defaultOffsets: [BloomPanel: CGPoint],
        panelSizes: [BloomPanel: CGSize]
    ) -> BloomPanelOffsets {
        let nodeHitSize: CGFloat = 60
        let pushMagnitude: CGFloat = 80

        // Filter out the selected node itself
        let otherNodes = allNodes.filter { $0.id != selectedNodeID }

        var result = BloomPanelOffsets(offsets: [:])

        for panel in BloomPanel.allCases {
            guard let defaultOffset = defaultOffsets[panel],
                  let panelSize = panelSizes[panel] else { continue }

            // Panel rect in canvas space (centered on offset point)
            let panelCenter = CGPoint(
                x: nodePosition.x + defaultOffset.x,
                y: nodePosition.y + defaultOffset.y
            )
            let panelRect = CGRect(
                x: panelCenter.x - panelSize.width / 2,
                y: panelCenter.y - panelSize.height / 2,
                width: panelSize.width,
                height: panelSize.height
            )

            // Check each other node for overlap
            for otherNode in otherNodes {
                let nodeRect = CGRect(
                    x: otherNode.position.x - nodeHitSize / 2,
                    y: otherNode.position.y - nodeHitSize / 2,
                    width: nodeHitSize,
                    height: nodeHitSize
                )

                if panelRect.intersects(nodeRect) {
                    // Push panel away from the overlapping node
                    let dx = panelCenter.x - otherNode.position.x
                    let dy = panelCenter.y - otherNode.position.y
                    let dist = sqrt(dx * dx + dy * dy)

                    if dist > 0.01 {
                        let pushX = (dx / dist) * pushMagnitude
                        let pushY = (dy / dist) * pushMagnitude
                        result.setOffset(CGSize(width: pushX, height: pushY), for: panel)
                    } else {
                        // Degenerate case: push down
                        result.setOffset(CGSize(width: 0, height: pushMagnitude), for: panel)
                    }
                    break // One push per panel is enough
                }
            }
        }

        return result
    }
}
