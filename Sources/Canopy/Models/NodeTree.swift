import Foundation

import SwiftUI

struct NodeTree: Equatable, Identifiable {
    var id: UUID
    var name: String
    var rootNode: Node
    /// Per-tree scale override. nil = inherit from `CanopyProject.globalKey`.
    var scale: MusicalKey?
    /// Which tree this was variated from (metadata only, no live link).
    var sourceTreeID: UUID?
    /// What variation was applied to create this tree.
    var variationType: VariationType?
    /// Which of 15 color families this tree belongs to.
    var anchor: SeedColor.SeedAnchor
    /// Deterministic drift seed — same anchor + different seedId = different shade.
    var colorSeedId: Int

    /// The tree seed's drifted color (tier-1 drift from anchor).
    var driftedColor: Color {
        SeedColor.driftedColor(anchor: anchor, seedId: colorSeedId)
    }

    init(
        id: UUID = UUID(),
        name: String = "Tree 1",
        rootNode: Node = Node(),
        scale: MusicalKey? = nil,
        sourceTreeID: UUID? = nil,
        variationType: VariationType? = nil,
        anchor: SeedColor.SeedAnchor = SeedColor.SeedAnchor.allCases.randomElement()!,
        colorSeedId: Int = Int.random(in: 0..<1_000_000)
    ) {
        self.id = id
        self.name = name
        self.rootNode = rootNode
        self.scale = scale
        self.sourceTreeID = sourceTreeID
        self.variationType = variationType
        self.anchor = anchor
        self.colorSeedId = colorSeedId
    }
}

// MARK: - Codable (backward-compatible)

extension NodeTree: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, rootNode, scale, sourceTreeID, variationType, anchor, colorSeedId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootNode = try container.decode(Node.self, forKey: .rootNode)
        scale = try container.decodeIfPresent(MusicalKey.self, forKey: .scale)
        sourceTreeID = try container.decodeIfPresent(UUID.self, forKey: .sourceTreeID)
        variationType = try container.decodeIfPresent(VariationType.self, forKey: .variationType)
        anchor = try container.decodeIfPresent(SeedColor.SeedAnchor.self, forKey: .anchor) ?? .canopy
        colorSeedId = try container.decodeIfPresent(Int.self, forKey: .colorSeedId)
            ?? SeedColor.deterministicSeedId(from: id)
    }
}
