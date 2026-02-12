import Foundation

enum TraversalMode: String, Codable, Equatable {
    case depthFirst
    case breadthFirst
    case random
    case manual
}

struct Arrangement: Codable, Equatable {
    var id: UUID
    var name: String
    var treeIDs: [UUID]
    var traversalMode: TraversalMode
    var looping: Bool

    init(
        id: UUID = UUID(),
        name: String = "Main",
        treeIDs: [UUID] = [],
        traversalMode: TraversalMode = .depthFirst,
        looping: Bool = true
    ) {
        self.id = id
        self.name = name
        self.treeIDs = treeIDs
        self.traversalMode = traversalMode
        self.looping = looping
    }
}
