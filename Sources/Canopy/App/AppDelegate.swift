import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.canopy", category: "AppDelegate")

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: CanopyWindow!
    let projectState = ProjectState()
    let transportState = TransportState()

    /// Chromatic two-row mapping: home row = white keys, row above = black keys.
    private static let keyToSemitone: [String: Int] = [
        "a": 0,  "w": 1,  "s": 2,  "e": 3,  "d": 4,
        "f": 5,  "t": 6,  "g": 7,  "y": 8,  "h": 9,
        "u": 10, "j": 11, "k": 12, "o": 13, "l": 14,
        "p": 15,
    ]

    /// Scale-aware mapping: home row keys map to consecutive scale degrees.
    private static let keyToScaleDegree: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "g": 4,
        "h": 5, "j": 6, "k": 7, "l": 8,
    ]

    /// Track which character → MIDI note is currently held for correct noteOff.
    private var heldKeyNotes: [String: Int] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start audio engine
        AudioEngine.shared.start()

        // Sync transport BPM with project
        transportState.bpm = projectState.project.bpm

        let contentView = MainContentView(
            projectState: projectState,
            transportState: transportState
        )

        window = CanopyWindow(
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

        window.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        window.keyUpHandler = { [weak self] event in
            self?.handleKeyUp(event) ?? false
        }

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

    // MARK: - Keyboard Input

    /// Returns true if the event was consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let isEditing = isEditingTextField()
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Spacebar → transport toggle (always, unless editing text)
        if event.keyCode == 49 && !isEditing {
            transportState.togglePlayback()
            return true
        }

        // Everything below requires computer keyboard mode ON
        guard projectState.computerKeyboardEnabled,
              !isEditing,
              !chars.isEmpty,
              !event.isARepeat else {
            return false
        }

        // Octave control
        if chars == ";" {
            if projectState.keyboardOctave > 0 { projectState.keyboardOctave -= 1 }
            return true
        }
        if chars == "'" {
            if projectState.keyboardOctave < 7 { projectState.keyboardOctave += 1 }
            return true
        }

        // Note input
        if let nodeID = projectState.selectedNodeID {
            let midiNote: Int?

            if projectState.project.scaleAwareEnabled {
                // Scale-aware: home row keys → consecutive scale degrees
                if let degree = Self.keyToScaleDegree[chars] {
                    let key = resolvedKey()
                    let intervals = key.mode.intervals
                    let octaveShift = degree / intervals.count
                    let degreeInScale = degree % intervals.count
                    midiNote = (projectState.keyboardOctave + 1) * 12 + key.root.semitone + octaveShift * 12 + intervals[degreeInScale]
                } else {
                    midiNote = nil
                }
            } else {
                // Chromatic: two-row layout
                if let semitone = Self.keyToSemitone[chars] {
                    midiNote = (projectState.keyboardOctave + 1) * 12 + semitone
                } else {
                    midiNote = nil
                }
            }

            if let midiNote, midiNote >= 0, midiNote <= 127 {
                heldKeyNotes[chars] = midiNote
                projectState.computerKeyPressedNotes.insert(midiNote)
                AudioEngine.shared.noteOn(pitch: midiNote, velocity: 0.8, nodeID: nodeID)
                let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
                projectState.captureBuffer.noteOn(pitch: midiNote, velocity: 0.8, atBeat: beat)
                return true
            }
        }

        return false
    }

    /// Returns true if the event was consumed.
    private func handleKeyUp(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }

        if let midiNote = heldKeyNotes.removeValue(forKey: chars) {
            projectState.computerKeyPressedNotes.remove(midiNote)
            if let nodeID = projectState.selectedNodeID {
                AudioEngine.shared.noteOff(pitch: midiNote, nodeID: nodeID)
            }
            let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
            projectState.captureBuffer.noteOff(pitch: midiNote, atBeat: beat)
            return true
        }

        if chars == ";" || chars == "'" {
            return true
        }

        return false
    }

    private func resolvedKey() -> MusicalKey {
        guard let node = projectState.selectedNode else { return projectState.project.globalKey }
        if let override = node.scaleOverride { return override }
        if let tree = projectState.project.trees.first, let treeScale = tree.scale { return treeScale }
        return projectState.project.globalKey
    }

    private func isEditingTextField() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
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
