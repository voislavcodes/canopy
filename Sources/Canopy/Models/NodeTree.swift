import Foundation

struct NodeTree: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var rootNode: Node
    /// Per-tree scale override. nil = inherit from `CanopyProject.globalKey`.
    var scale: MusicalKey?
    /// Which tree this was variated from (metadata only, no live link).
    var sourceTreeID: UUID?
    /// What variation was applied to create this tree.
    var variationType: VariationType?

    init(
        id: UUID = UUID(),
        name: String = "Tree 1",
        rootNode: Node = Node(),
        scale: MusicalKey? = nil,
        sourceTreeID: UUID? = nil,
        variationType: VariationType? = nil
    ) {
        self.id = id
        self.name = name
        self.rootNode = rootNode
        self.scale = scale
        self.sourceTreeID = sourceTreeID
        self.variationType = variationType
    }
}
