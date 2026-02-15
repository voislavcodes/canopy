import Foundation

enum NodeType: String, Codable, Equatable {
    case seed
    case melodic
    case harmonic
    case rhythmic
    case effect
    case group
}

/// Which sequencer UI to show. nil = derive from SoundType.
enum SequencerType: String, Codable, Equatable {
    case pitched
    case drum
}

/// Which input UI to show. nil = derive from SoundType.
enum InputMode: String, Codable, Equatable {
    case keyboard
    case padGrid
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
    /// Preset that created this node. nil = seed or legacy node.
    var presetID: String?
    /// Override for sequencer UI. nil = derive from SoundType.
    var sequencerType: SequencerType?
    /// Override for input UI. nil = derive from SoundType.
    var inputMode: InputMode?

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
        scaleOverride: MusicalKey? = nil,
        presetID: String? = nil,
        sequencerType: SequencerType? = nil,
        inputMode: InputMode? = nil
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
        self.presetID = presetID
        self.sequencerType = sequencerType
        self.inputMode = inputMode
    }

    // Backward-compatible decoding — old files lack presetID
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(NodeType.self, forKey: .type)
        key = try container.decode(MusicalKey.self, forKey: .key)
        sequence = try container.decode(NoteSequence.self, forKey: .sequence)
        patch = try container.decode(SoundPatch.self, forKey: .patch)
        effects = try container.decode([Effect].self, forKey: .effects)
        children = try container.decode([Node].self, forKey: .children)
        position = try container.decode(NodePosition.self, forKey: .position)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        isSolo = try container.decode(Bool.self, forKey: .isSolo)
        scaleOverride = try container.decodeIfPresent(MusicalKey.self, forKey: .scaleOverride)
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        sequencerType = try container.decodeIfPresent(SequencerType.self, forKey: .sequencerType)
        inputMode = try container.decodeIfPresent(InputMode.self, forKey: .inputMode)
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
