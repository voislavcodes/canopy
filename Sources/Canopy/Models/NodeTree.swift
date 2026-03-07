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
    /// Tree-level volume multiplier (0.0–1.0). Applied on top of per-node volumes.
    var volume: Double = 1.0
    /// Tree-level pan offset (-1.0 to +1.0). Added to per-node pan values.
    var pan: Double = 0.0
    /// Tree-level mute state (separate from per-node mute).
    var isMuted: Bool = false
    /// Tree-level solo state (separate from per-node solo).
    var isSolo: Bool = false

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
        colorSeedId: Int = Int.random(in: 0..<1_000_000),
        volume: Double = 1.0,
        pan: Double = 0.0,
        isMuted: Bool = false,
        isSolo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootNode = rootNode
        self.scale = scale
        self.sourceTreeID = sourceTreeID
        self.variationType = variationType
        self.anchor = anchor
        self.colorSeedId = colorSeedId
        self.volume = volume
        self.pan = pan
        self.isMuted = isMuted
        self.isSolo = isSolo
    }
}

// MARK: - Codable (backward-compatible)

extension NodeTree: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, rootNode, scale, sourceTreeID, variationType, anchor, colorSeedId
        case volume, pan, isMuted, isSolo
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
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSolo = try container.decodeIfPresent(Bool.self, forKey: .isSolo) ?? false
    }
}
