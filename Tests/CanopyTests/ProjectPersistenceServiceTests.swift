import XCTest
@testable import Canopy

final class ProjectPersistenceServiceTests: XCTestCase {
    private var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanopyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    func testCreateProjectCreatesFileOnDisk() throws {
        var project = ProjectFactory.newProject()
        project.name = "Test"
        let url = testDir.appendingPathComponent("Test.canopy")
        try ProjectFileService.save(project, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNextAvailableNameGeneratesUniqueNames() throws {
        // Empty dir → "Untitled"
        XCTAssertEqual(ProjectPersistenceService.nextAvailableName(in: testDir), "Untitled")

        // Create "Untitled.canopy"
        var p1 = ProjectFactory.newProject()
        p1.name = "Untitled"
        try ProjectFileService.save(p1, to: testDir.appendingPathComponent("Untitled.canopy"))

        // Now should return "Untitled 2"
        XCTAssertEqual(ProjectPersistenceService.nextAvailableName(in: testDir), "Untitled 2")

        // Create "Untitled 2.canopy"
        var p2 = ProjectFactory.newProject()
        p2.name = "Untitled 2"
        try ProjectFileService.save(p2, to: testDir.appendingPathComponent("Untitled 2.canopy"))

        // Now should return "Untitled 3"
        XCTAssertEqual(ProjectPersistenceService.nextAvailableName(in: testDir), "Untitled 3")
    }

    func testDeleteRemovesFile() throws {
        var project = ProjectFactory.newProject()
        project.name = "ToDelete"
        let url = testDir.appendingPathComponent("ToDelete.canopy")
        try ProjectFileService.save(project, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        ProjectPersistenceService.deleteProject(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDuplicateCreatesNewFileWithDifferentID() throws {
        var project = ProjectFactory.newProject()
        project.name = "Original"
        let url = testDir.appendingPathComponent("Original.canopy")
        try ProjectFileService.save(project, to: url)

        let newURL = ProjectPersistenceService.duplicateProject(at: url)
        XCTAssertNotNil(newURL)

        let original = try ProjectFileService.load(from: url)
        let duplicate = try ProjectFileService.load(from: newURL!)

        XCTAssertNotEqual(original.id, duplicate.id)
        XCTAssertEqual(duplicate.name, "Original Copy")
    }

    func testExtractPresetColors() {
        var project = ProjectFactory.newProject()
        // Seed node has no preset, so no colors
        XCTAssertTrue(ProjectPersistenceService.extractPresetColors(from: project).isEmpty)

        // Add a node with a preset ID
        let preset = NodePreset.builtIn.first { $0.id == "drums" }!
        var drumsNode = Node(
            name: preset.name,
            type: preset.nodeType,
            sequence: NoteSequence(lengthInBeats: 4),
            patch: preset.defaultPatch,
            presetID: preset.id
        )
        project.trees[0].rootNode.children.append(drumsNode)

        let colors = ProjectPersistenceService.extractPresetColors(from: project)
        XCTAssertEqual(colors, [.orange])
    }

    func testMarkDirtySetsFlag() {
        let state = ProjectState()
        XCTAssertFalse(state.isDirty)
        state.markDirty()
        XCTAssertTrue(state.isDirty)
    }

    func testPerformAutoSaveClearsDirtyFlag() throws {
        let state = ProjectState()
        let url = testDir.appendingPathComponent("autosave.canopy")
        state.currentFilePath = url

        var savedProject: CanopyProject?
        state.autoSaveHandler = { project, url in
            savedProject = project
            try? ProjectFileService.save(project, to: url)
        }

        state.markDirty()
        XCTAssertTrue(state.isDirty)

        state.performAutoSave()
        XCTAssertFalse(state.isDirty)
        XCTAssertNotNil(savedProject)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAutoSaveSkippedWhenNoFilePath() {
        let state = ProjectState()
        state.currentFilePath = nil

        var handlerCalled = false
        state.autoSaveHandler = { _, _ in handlerCalled = true }

        state.markDirty()
        state.performAutoSave()
        XCTAssertFalse(handlerCalled, "Auto-save handler should not be called when no file path is set")
    }
}
