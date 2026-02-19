import Foundation
import SwiftUI

/// Identifies a bloom panel type for offset/focus tracking.
enum BloomPanel: String, CaseIterable {
    case synth
    case sequencer
    case prompt
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

/// Tracks an in-progress drag gesture on a bloom panel.
struct ActivePanelDrag: Equatable {
    let panel: BloomPanel
    var delta: CGSize
}

/// Ephemeral visual state for bloom panel positioning and focus.
/// Follows the CanvasState pattern — not persisted to .canopy files.
class BloomState: ObservableObject {
    /// Per-node custom offsets from dragging panels.
    @Published var panelOffsets: [UUID: BloomPanelOffsets] = [:]

    /// In-progress drag delta (nil when no drag active).
    @Published var activeDrag: ActivePanelDrag?

    /// Which panel is in focus mode (nil = normal bloom layout).
    @Published var focusedPanel: BloomPanel?

    /// Combined stored offset + live drag delta for a panel.
    func effectiveOffset(panel: BloomPanel, nodeID: UUID) -> CGSize {
        let stored = panelOffsets[nodeID]?.offset(for: panel) ?? .zero
        if let drag = activeDrag, drag.panel == panel {
            return CGSize(
                width: stored.width + drag.delta.width,
                height: stored.height + drag.delta.height
            )
        }
        return stored
    }

    /// Commit the active drag delta into stored offsets.
    func commitDrag(nodeID: UUID) {
        guard let drag = activeDrag else { return }
        var current = panelOffsets[nodeID] ?? .zero
        let stored = current.offset(for: drag.panel)
        current.setOffset(
            CGSize(
                width: stored.width + drag.delta.width,
                height: stored.height + drag.delta.height
            ),
            for: drag.panel
        )
        panelOffsets[nodeID] = current
        activeDrag = nil
    }

    /// Exit focus mode.
    func unfocus() {
        focusedPanel = nil
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
