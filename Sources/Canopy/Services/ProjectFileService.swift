import Foundation

enum ProjectFileService {
    static func save(_ project: CanopyProject, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> CanopyProject {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(CanopyProject.self, from: data)
    }
}
