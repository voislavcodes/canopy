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

        // Second pass: separate panels that overlap each other
        separateOverlappingPanels(
            &result,
            nodePosition: nodePosition,
            defaultOffsets: defaultOffsets,
            panelSizes: panelSizes
        )

        return result
    }

    // MARK: - Inter-Panel Separation

    /// Natural escape directions for each panel type.
    private static let naturalDirections: [BloomPanel: CGPoint] = [
        .synth: CGPoint(x: -1, y: 0),
        .sequencer: CGPoint(x: 1, y: 0),
        .input: CGPoint(x: 0, y: 1)
    ]

    /// Resolves overlaps between bloom panels by pushing them apart along
    /// natural escape directions. Iterates up to 3 passes for convergence.
    private static func separateOverlappingPanels(
        _ offsets: inout BloomPanelOffsets,
        nodePosition: CGPoint,
        defaultOffsets: [BloomPanel: CGPoint],
        panelSizes: [BloomPanel: CGSize]
    ) {
        let padding: CGFloat = 10
        let panels = BloomPanel.allCases
        let maxPasses = 3

        for _ in 0..<maxPasses {
            var hadOverlap = false

            for i in 0..<panels.count {
                for j in (i + 1)..<panels.count {
                    let panelA = panels[i]
                    let panelB = panels[j]

                    guard let defA = defaultOffsets[panelA],
                          let sizeA = panelSizes[panelA],
                          let defB = defaultOffsets[panelB],
                          let sizeB = panelSizes[panelB] else { continue }

                    let pushA = offsets.offset(for: panelA)
                    let pushB = offsets.offset(for: panelB)

                    let rectA = panelRect(
                        nodePosition: nodePosition, defaultOffset: defA,
                        push: pushA, size: sizeA
                    ).insetBy(dx: -padding / 2, dy: -padding / 2)

                    let rectB = panelRect(
                        nodePosition: nodePosition, defaultOffset: defB,
                        push: pushB, size: sizeB
                    ).insetBy(dx: -padding / 2, dy: -padding / 2)

                    guard rectA.intersects(rectB) else { continue }
                    hadOverlap = true

                    // Compute overlap on each axis
                    let overlapX = min(rectA.maxX, rectB.maxX) - max(rectA.minX, rectB.minX)
                    let overlapY = min(rectA.maxY, rectB.maxY) - max(rectA.minY, rectB.minY)

                    let dirA = naturalDirections[panelA] ?? .zero
                    let dirB = naturalDirections[panelB] ?? .zero

                    // Resolve on minimum penetration axis
                    if overlapX < overlapY {
                        // Push horizontally
                        let aAligns = dirA.x != 0
                        let bAligns = dirB.x != 0
                        let pushAmount = overlapX + padding

                        if aAligns && !bAligns {
                            applyPush(&offsets, panel: panelA, dx: dirA.x * pushAmount, dy: 0)
                        } else if bAligns && !aAligns {
                            applyPush(&offsets, panel: panelB, dx: dirB.x * pushAmount, dy: 0)
                        } else {
                            // Both or neither align — split evenly away from each other
                            let sign: CGFloat = rectA.midX < rectB.midX ? -1 : 1
                            applyPush(&offsets, panel: panelA, dx: sign * pushAmount / 2, dy: 0)
                            applyPush(&offsets, panel: panelB, dx: -sign * pushAmount / 2, dy: 0)
                        }
                    } else {
                        // Push vertically
                        let aAligns = dirA.y != 0
                        let bAligns = dirB.y != 0
                        let pushAmount = overlapY + padding

                        if aAligns && !bAligns {
                            applyPush(&offsets, panel: panelA, dx: 0, dy: dirA.y * pushAmount)
                        } else if bAligns && !aAligns {
                            applyPush(&offsets, panel: panelB, dx: 0, dy: dirB.y * pushAmount)
                        } else {
                            let sign: CGFloat = rectA.midY < rectB.midY ? -1 : 1
                            applyPush(&offsets, panel: panelA, dx: 0, dy: sign * pushAmount / 2)
                            applyPush(&offsets, panel: panelB, dx: 0, dy: -sign * pushAmount / 2)
                        }
                    }
                }
            }

            if !hadOverlap { break }
        }
    }

    /// Build a panel's rect from its position components.
    private static func panelRect(
        nodePosition: CGPoint,
        defaultOffset: CGPoint,
        push: CGSize,
        size: CGSize
    ) -> CGRect {
        let cx = nodePosition.x + defaultOffset.x + push.width
        let cy = nodePosition.y + defaultOffset.y + push.height
        return CGRect(
            x: cx - size.width / 2,
            y: cy - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Add a delta to a panel's existing offset.
    private static func applyPush(
        _ offsets: inout BloomPanelOffsets,
        panel: BloomPanel,
        dx: CGFloat,
        dy: CGFloat
    ) {
        let current = offsets.offset(for: panel)
        offsets.setOffset(
            CGSize(width: current.width + dx, height: current.height + dy),
            for: panel
        )
    }
}
