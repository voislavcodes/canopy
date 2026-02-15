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
    var lfos: [LFODefinition]
    var modulationRoutings: [ModulationRouting]

    init(
        id: UUID = UUID(),
        name: String = "Untitled",
        bpm: Double = 120,
        globalKey: MusicalKey = MusicalKey(root: .C, mode: .minor),
        trees: [NodeTree] = [],
        arrangements: [Arrangement] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        lfos: [LFODefinition] = [],
        modulationRoutings: [ModulationRouting] = []
    ) {
        self.id = id
        self.name = name
        self.bpm = bpm
        self.globalKey = globalKey
        self.trees = trees
        self.arrangements = arrangements
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.modifiedAt = Date(timeIntervalSince1970: modifiedAt.timeIntervalSince1970.rounded(.down))
        self.lfos = lfos
        self.modulationRoutings = modulationRoutings
    }

    // Custom decoder for backward compatibility with projects saved before LFO support.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bpm = try container.decode(Double.self, forKey: .bpm)
        globalKey = try container.decode(MusicalKey.self, forKey: .globalKey)
        trees = try container.decode([NodeTree].self, forKey: .trees)
        arrangements = try container.decode([Arrangement].self, forKey: .arrangements)
        let rawCreated = try container.decode(Date.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: rawCreated.timeIntervalSince1970.rounded(.down))
        let rawModified = try container.decode(Date.self, forKey: .modifiedAt)
        modifiedAt = Date(timeIntervalSince1970: rawModified.timeIntervalSince1970.rounded(.down))
        lfos = try container.decodeIfPresent([LFODefinition].self, forKey: .lfos) ?? []
        modulationRoutings = try container.decodeIfPresent([ModulationRouting].self, forKey: .modulationRoutings) ?? []
    }
}
