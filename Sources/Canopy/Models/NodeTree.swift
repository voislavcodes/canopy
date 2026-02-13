import Foundation

enum TransitionMode: String, Codable, Equatable {
    case immediate
    case crossfade
    case beatSynced
    case barSynced
}

struct TransitionBehavior: Codable, Equatable {
    var mode: TransitionMode
    var durationBeats: Double

    init(mode: TransitionMode = .crossfade, durationBeats: Double = 4.0) {
        self.mode = mode
        self.durationBeats = durationBeats
    }
}

struct NodeTree: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var rootNode: Node
    var transition: TransitionBehavior
    /// Per-tree scale override. nil = inherit from `CanopyProject.globalKey`.
    var scale: MusicalKey?

    init(
        id: UUID = UUID(),
        name: String = "Tree 1",
        rootNode: Node = Node(),
        transition: TransitionBehavior = TransitionBehavior(),
        scale: MusicalKey? = nil
    ) {
        self.id = id
        self.name = name
        self.rootNode = rootNode
        self.transition = transition
        self.scale = scale
    }
}
