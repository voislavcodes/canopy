import Foundation

enum NodeType: String, Codable, Equatable {
    case seed
    case melodic
    case harmonic
    case rhythmic
    case effect
    case group
}

struct Node: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var type: NodeType
    var key: MusicalKey
    var sequence: NoteSequence
    var patch: SoundPatch
    var effects: [Effect]
    var children: [Node]
    var position: NodePosition
    var isMuted: Bool
    var isSolo: Bool
    /// Per-node scale override. nil = inherit from tree/project.
    var scaleOverride: MusicalKey?

    init(
        id: UUID = UUID(),
        name: String = "Seed",
        type: NodeType = .seed,
        key: MusicalKey = MusicalKey(root: .C, mode: .minor),
        sequence: NoteSequence = NoteSequence(),
        patch: SoundPatch = SoundPatch(),
        effects: [Effect] = [],
        children: [Node] = [],
        position: NodePosition = NodePosition(),
        isMuted: Bool = false,
        isSolo: Bool = false,
        scaleOverride: MusicalKey? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.key = key
        self.sequence = sequence
        self.patch = patch
        self.effects = effects
        self.children = children
        self.position = position
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.scaleOverride = scaleOverride
    }
}

struct NodePosition: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}
