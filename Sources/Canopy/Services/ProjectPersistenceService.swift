import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.canopy", category: "ProjectPersistence")

/// Metadata about a saved project, used by the project browser.
struct ProjectInfo: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let modifiedAt: Date
    let presetColors: [PresetColor]
}

/// Wraps ProjectFileService with directory management, listing, and naming.
enum ProjectPersistenceService {
    /// Standard directory for Canopy projects.
    static var projectsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Canopy/Projects", isDirectory: true)
    }

    /// Creates the projects directory if it doesn't exist.
    static func ensureProjectsDirectory() {
        let url = projectsDirectory
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                logger.info("Created projects directory at \(url.path)")
            } catch {
                logger.error("Failed to create projects directory: \(error.localizedDescription)")
            }
        }
    }

    /// Lists all `.canopy` files in the projects directory, sorted by modification date (newest first).
    static func listProjects() -> [ProjectInfo] {
        let dir = projectsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let canopyFiles = contents.filter { $0.pathExtension == "canopy" }

        return canopyFiles.compactMap { url -> ProjectInfo? in
            guard let project = try? ProjectFileService.load(from: url) else { return nil }
            let colors = extractPresetColors(from: project)
            return ProjectInfo(
                id: project.id,
                url: url,
                name: project.name,
                modifiedAt: project.modifiedAt,
                presetColors: colors
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Creates a new project on disk with an auto-generated unique name.
    static func createNewProject() -> (CanopyProject, URL) {
        ensureProjectsDirectory()
        let name = nextAvailableName()
        var project = ProjectFactory.newProject()
        project.name = name
        let filename = "\(name).canopy"
        let url = projectsDirectory.appendingPathComponent(filename)
        do {
            try ProjectFileService.save(project, to: url)
            logger.info("Created new project: \(name)")
        } catch {
            logger.error("Failed to save new project: \(error.localizedDescription)")
        }
        return (project, url)
    }

    /// Deletes a project file.
    static func deleteProject(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.info("Deleted project at \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to delete project: \(error.localizedDescription)")
        }
    }

    /// Duplicates a project file, assigning a new ID and appending "Copy" to the name.
    static func duplicateProject(at url: URL) -> URL? {
        guard var project = try? ProjectFileService.load(from: url) else { return nil }
        project.id = UUID()
        project.name = "\(project.name) Copy"
        project.createdAt = Date()
        project.modifiedAt = Date()
        let filename = "\(project.name).canopy"
        let newURL = url.deletingLastPathComponent().appendingPathComponent(filename)
        do {
            try ProjectFileService.save(project, to: newURL)
            logger.info("Duplicated project to \(filename)")
            return newURL
        } catch {
            logger.error("Failed to duplicate project: \(error.localizedDescription)")
            return nil
        }
    }

    /// Renames a project on disk. Updates the project name inside the file and renames the file.
    static func renameProject(at url: URL, to newName: String) -> URL? {
        guard var project = try? ProjectFileService.load(from: url) else { return nil }
        project.name = newName
        project.modifiedAt = Date()
        let newURL = url.deletingLastPathComponent().appendingPathComponent("\(newName).canopy")
        do {
            try ProjectFileService.save(project, to: newURL)
            // Remove old file if name actually changed
            if url != newURL {
                try? FileManager.default.removeItem(at: url)
            }
            logger.info("Renamed project to \(newName)")
            return newURL
        } catch {
            logger.error("Failed to rename project: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reveals the project file in Finder.
    static func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    /// Generates the next available "Untitled", "Untitled 2", etc.
    static func nextAvailableName(in directory: URL? = nil) -> String {
        let dir = directory ?? projectsDirectory
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.map { $0.deletingPathExtension().lastPathComponent } ?? []

        if !existing.contains("Untitled") { return "Untitled" }
        var n = 2
        while existing.contains("Untitled \(n)") { n += 1 }
        return "Untitled \(n)"
    }

    /// Walks a project tree collecting PresetColors from nodes that have a presetID.
    static func extractPresetColors(from project: CanopyProject) -> [PresetColor] {
        var colors: [PresetColor] = []
        for tree in project.trees {
            collectPresetColors(from: tree.rootNode, into: &colors)
        }
        // Deduplicate while preserving order
        var seen = Set<PresetColor>()
        return colors.filter { seen.insert($0).inserted }
    }

    private static func collectPresetColors(from node: Node, into colors: inout [PresetColor]) {
        if let presetID = node.presetID, let preset = NodePreset.find(presetID) {
            colors.append(preset.color)
        }
        for child in node.children {
            collectPresetColors(from: child, into: &colors)
        }
    }
}
