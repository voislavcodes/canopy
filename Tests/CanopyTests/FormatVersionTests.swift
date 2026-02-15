import XCTest
@testable import Canopy

final class FormatVersionTests: XCTestCase {
    func testNewProjectHasCurrentVersion() {
        let project = ProjectFactory.newProject()
        XCTAssertEqual(project.formatVersion, CanopyProject.currentFormatVersion)
    }

    func testOldJSONWithoutFormatVersionDecodesAs1() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Old Project",
            "bpm": 120.0,
            "globalKey": { "root": "C", "mode": "minor" },
            "trees": [],
            "arrangements": [],
            "createdAt": 1700000000,
            "modifiedAt": 1700000000
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1, "Missing formatVersion should default to 1")
    }

    func testFormatVersionRoundTrip() throws {
        var project = ProjectFactory.newProject()
        project.formatVersion = 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1)
    }

    func testMigrateIsNoOpOnCurrentVersion() {
        let project = ProjectFactory.newProject()
        let migrated = CanopyProject.migrate(project)
        XCTAssertEqual(project, migrated)
    }
}
