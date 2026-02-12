import XCTest
@testable import Canopy

final class ProjectFileServiceTests: XCTestCase {
    func testSaveAndLoad() throws {
        let project = ProjectFactory.newProject()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).canopy")

        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ProjectFileService.save(project, to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let loaded = try ProjectFileService.load(from: fileURL)

        // Compare key fields to diagnose any precision issues
        XCTAssertEqual(project.id, loaded.id)
        XCTAssertEqual(project.name, loaded.name)
        XCTAssertEqual(project.bpm, loaded.bpm)
        XCTAssertEqual(project.globalKey, loaded.globalKey)
        XCTAssertEqual(project.trees, loaded.trees)
        XCTAssertEqual(project.arrangements, loaded.arrangements)
        XCTAssertEqual(project.createdAt.timeIntervalSince1970, loaded.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(project.modifiedAt.timeIntervalSince1970, loaded.modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSavedFileIsValidJSON() throws {
        let project = ProjectFactory.newProject()
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_\(UUID().uuidString).canopy")

        defer { try? FileManager.default.removeItem(at: fileURL) }

        try ProjectFileService.save(project, to: fileURL)

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(json is [String: Any])
    }

    func testLoadNonexistentFileThrows() {
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).canopy")
        XCTAssertThrowsError(try ProjectFileService.load(from: bogusURL))
    }
}
