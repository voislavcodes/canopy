import Foundation

struct CanopyProject: Codable, Equatable {
    var id: UUID
    var name: String
    var bpm: Double
    var globalKey: MusicalKey
    var trees: [NodeTree]
    var arrangements: [Arrangement]
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        bpm: Double = 120,
        globalKey: MusicalKey = MusicalKey(root: .C, mode: .minor),
        trees: [NodeTree] = [],
        arrangements: [Arrangement] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.bpm = bpm
        self.globalKey = globalKey
        self.trees = trees
        self.arrangements = arrangements
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.modifiedAt = Date(timeIntervalSince1970: modifiedAt.timeIntervalSince1970.rounded(.down))
    }
}
