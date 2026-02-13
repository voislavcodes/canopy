import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let projectState = ProjectState()
    let transportState = TransportState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start audio engine
        AudioEngine.shared.start()

        // Sync transport BPM with project
        transportState.bpm = projectState.project.bpm

        let contentView = MainContentView(
            projectState: projectState,
            transportState: transportState
        )

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Canopy"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.06, alpha: 1)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("CanopyMainWindow")

        setupMenuBar()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioEngine.shared.stop()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Canopy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Canopy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New", action: #selector(newProject), keyEquivalent: "n"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Open...", action: #selector(openProject), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Save", action: #selector(saveProject), keyEquivalent: "s"))
        fileMenu.addItem(NSMenuItem(title: "Save As...", action: #selector(saveProjectAs), keyEquivalent: "S"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (standard)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Audio Graph

    private func rebuildAudioGraph() {
        guard let tree = projectState.project.trees.first else { return }
        AudioEngine.shared.buildGraph(from: tree)
        AudioEngine.shared.configureAllPatches(from: tree)
        AudioEngine.shared.loadAllSequences(from: tree)
    }

    // MARK: - File Actions

    @objc private func newProject() {
        transportState.stopPlayback()
        AudioEngine.shared.teardownGraph()
        projectState.project = ProjectFactory.newProject()
        projectState.selectedNodeID = nil
        projectState.currentFilePath = nil
        projectState.isDirty = false
        transportState.bpm = projectState.project.bpm
        rebuildAudioGraph()
    }

    @objc private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "canopy")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                self.transportState.stopPlayback()
                AudioEngine.shared.teardownGraph()
                let project = try ProjectFileService.load(from: url)
                self.projectState.project = project
                self.projectState.selectedNodeID = nil
                self.projectState.currentFilePath = url
                self.projectState.isDirty = false
                self.transportState.bpm = project.bpm
                self.rebuildAudioGraph()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func saveProject() {
        if let url = projectState.currentFilePath {
            do {
                try ProjectFileService.save(projectState.project, to: url)
                projectState.isDirty = false
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        } else {
            saveProjectAs()
        }
    }

    @objc private func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "canopy")!]
        panel.nameFieldStringValue = "\(projectState.project.name).canopy"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try ProjectFileService.save(self.projectState.project, to: url)
                self.projectState.currentFilePath = url
                self.projectState.isDirty = false
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}
