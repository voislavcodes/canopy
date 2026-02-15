import Foundation
import Combine

class ProjectState: ObservableObject {
    @Published var project: CanopyProject {
        didSet {
            _cachedAllNodes = nil
            _cachedCycleLength = nil
        }
    }
    @Published var selectedNodeID: UUID?
    @Published var selectedLFOID: UUID?
    @Published var currentFilePath: URL?
    @Published var isDirty: Bool = false

    // MARK: - Transient keyboard state (not persisted)

    /// Base octave for both on-screen and computer keyboard input.
    @Published var keyboardOctave: Int = 3
    /// MIDI notes currently held via computer keyboard — merged into visual keyboard state.
    @Published var computerKeyPressedNotes: Set<Int> = []
    /// When true, the computer keyboard acts as a MIDI piano input.
    @Published var computerKeyboardEnabled: Bool = false

    // MARK: - MIDI Capture state (not persisted)

    /// Always-listening circular buffer that records keyboard note events.
    let captureBuffer = MIDICaptureBuffer()
    /// Quantize strength for capture (0.0 = raw, 1.0 = snap to grid).
    @Published var captureQuantizeStrength: Double = 0.75
    /// How captured notes are written into the sequence.
    @Published var captureMode: CaptureMode = .replace
    /// Wall-clock reference for free-running beat calculation.
    private var freeRunningBeatRef: Date = Date()

    /// Compute current beat position from wall-clock time (avoids audio engine loop wrapping).
    func currentCaptureBeat(bpm: Double) -> Double {
        let elapsed = Date().timeIntervalSince(freeRunningBeatRef)
        return elapsed * bpm / 60.0
    }

    /// Reset the free-running clock reference (called when transport stops).
    func resetFreeRunningClock() {
        freeRunningBeatRef = Date()
    }

    /// Capture the current buffer contents into the focused node's sequence.
    /// Adjusts the sequence length to fit the performance (up to 32 steps / 8 beats).
    /// Returns false if buffer is empty or no node is selected.
    func capturePerformance() -> Bool {
        guard !captureBuffer.isEmpty,
              let nodeID = selectedNodeID,
              let node = findNode(id: nodeID) else {
            return false
        }

        let key = resolveKeyForNode(node)
        let sd = NoteSequence.stepDuration
        let maxBeats = 32.0 * sd  // 8 beats = 32 steps

        // Compute target length from the buffer span
        let targetLength = PhraseDetector.spanLength(from: captureBuffer, maxBeats: maxBeats)
        guard targetLength > 0 else { return false }

        // Extract phrase fitted to the computed length
        let phrase = PhraseDetector.extractPhrase(from: captureBuffer, lengthInBeats: targetLength)
        guard !phrase.isEmpty else { return false }

        // Quantize to grid and scale
        let quantized = CaptureQuantizer.quantize(
            events: phrase,
            strength: captureQuantizeStrength,
            key: key,
            lengthInBeats: targetLength
        )
        guard !quantized.isEmpty else { return false }

        // Write to node — update both notes and sequence length
        updateNode(id: nodeID) { node in
            node.sequence.lengthInBeats = targetLength
            switch self.captureMode {
            case .replace:
                node.sequence.notes = quantized
            case .merge:
                node.sequence.notes.append(contentsOf: quantized)
            }
        }

        captureBuffer.clear()
        return true
    }

    /// Resolve the musical key for a node (node override → tree scale → global key).
    private func resolveKeyForNode(_ node: Node) -> MusicalKey {
        if let override = node.scaleOverride { return override }
        if let tree = project.trees.first, let treeScale = tree.scale { return treeScale }
        return project.globalKey
    }

    // MARK: - Cached computations (invalidated on project mutation)

    private var _cachedAllNodes: [Node]?
    private var _cachedCycleLength: Double?

    init(project: CanopyProject = ProjectFactory.newProject()) {
        self.project = project
    }

    /// The currently selected node, if any.
    var selectedNode: Node? {
        guard let id = selectedNodeID else { return nil }
        return findNode(id: id)
    }

    func selectNode(_ id: UUID?) {
        selectedNodeID = id
        if project.trees.count > 0 {
            recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        }
    }

    func findNode(id: UUID) -> Node? {
        for tree in project.trees {
            if let found = findNodeRecursive(id: id, in: tree.rootNode) {
                return found
            }
        }
        return nil
    }

    /// Update a node in-place using a transform closure. Marks project as dirty.
    func updateNode(id: UUID, transform: (inout Node) -> Void) {
        for i in 0..<project.trees.count {
            if updateNodeRecursive(id: id, in: &project.trees[i].rootNode, transform: transform) {
                isDirty = true
                return
            }
        }
    }

    func allNodes() -> [Node] {
        if let cached = _cachedAllNodes {
            return cached
        }
        var result: [Node] = []
        for tree in project.trees {
            collectNodes(from: tree.rootNode, into: &result)
        }
        _cachedAllNodes = result
        return result
    }

    // MARK: - Tree Mutations

    /// Add a child node to the given parent. Returns the new node.
    @discardableResult
    func addChildNode(to parentID: UUID, type: NodeType = .melodic) -> Node {
        let name: String
        switch type {
        case .melodic: name = "Melody"
        case .harmonic: name = "Harmony"
        case .rhythmic: name = "Rhythm"
        case .seed: name = "Seed"
        case .effect: name = "Effect"
        case .group: name = "Group"
        }

        // Start at parent's position so SwiftUI can animate from parent → final
        let parentPos = findNode(id: parentID)?.position ?? NodePosition()

        let newNode = Node(
            name: name,
            type: type,
            sequence: NoteSequence(lengthInBeats: 2),
            patch: SoundPatch(
                name: "Default",
                soundType: .oscillator(OscillatorConfig(waveform: .sine))
            ),
            position: parentPos
        )

        updateNode(id: parentID) { parent in
            parent.children.append(newNode)
        }

        // Recompute layout for the entire tree
        if project.trees.count > 0 {
            recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        }

        isDirty = true
        return newNode
    }

    /// Add a child node using a preset for name, type, patch, sequence, and color.
    @discardableResult
    func addChildNode(to parentID: UUID, preset: NodePreset) -> Node {
        let parentPos = findNode(id: parentID)?.position ?? NodePosition()

        let newNode = Node(
            name: preset.name,
            type: preset.nodeType,
            sequence: NoteSequence(
                lengthInBeats: preset.defaultLengthInBeats,
                pitchRange: preset.defaultPitchRange
            ),
            patch: preset.defaultPatch,
            position: parentPos,
            presetID: preset.id
        )

        updateNode(id: parentID) { parent in
            parent.children.append(newNode)
        }

        if project.trees.count > 0 {
            recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        }

        isDirty = true
        return newNode
    }

    /// Remove a node by ID. Cannot remove the root node.
    func removeNode(id: UUID) {
        guard project.trees.count > 0 else { return }
        let rootID = project.trees[0].rootNode.id
        guard id != rootID else { return }

        removeNodeRecursive(id: id, from: &project.trees[0].rootNode)
        recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        isDirty = true
    }

    // MARK: - Module Swapping

    /// Swap the sound engine on a node. Rebuilds the audio subgraph.
    func swapEngine(nodeID: UUID, to soundType: SoundType) {
        AudioEngine.shared.removeNode(nodeID)
        updateNode(id: nodeID) { node in
            node.patch.soundType = soundType
        }
        if let node = findNode(id: nodeID) {
            AudioEngine.shared.addNode(node)
        }
        isDirty = true
    }

    /// Swap the sequencer UI type (pitched grid vs drum grid).
    func swapSequencer(nodeID: UUID, to type: SequencerType) {
        updateNode(id: nodeID) { $0.sequencerType = type }
        isDirty = true
    }

    /// Swap the input mode (keyboard vs pad grid).
    func swapInput(nodeID: UUID, to mode: InputMode) {
        updateNode(id: nodeID) { $0.inputMode = mode }
        isDirty = true
    }

    /// Compute the LCM of all nodes' sequence lengths (the natural polyrhythmic cycle).
    /// Works in step counts to handle fractional beat lengths correctly.
    func cycleLengthInBeats() -> Double {
        if let cached = _cachedCycleLength {
            return cached
        }
        let nodes = allNodes()
        guard !nodes.isEmpty else { return 1 }
        let sd = NoteSequence.stepDuration
        let stepCounts = nodes.map { max(1, Int(round($0.sequence.lengthInBeats / sd))) }
        let lcmSteps = stepCounts.reduce(1) { lcm($0, $1) }
        let result = Double(lcmSteps) * sd
        _cachedCycleLength = result
        return result
    }

    // MARK: - LFO / Modulation

    /// Add a new LFO with auto-generated name and color.
    @discardableResult
    func addLFO() -> LFODefinition {
        let index = project.lfos.count + 1
        let colorIndex = (project.lfos.count) % 8
        let lfo = LFODefinition(name: "LFO \(index)", colorIndex: colorIndex)
        project.lfos.append(lfo)
        isDirty = true
        syncModulationToEngine()
        return lfo
    }

    /// Remove an LFO and all its routings.
    func removeLFO(id: UUID) {
        project.lfos.removeAll { $0.id == id }
        project.modulationRoutings.removeAll { $0.lfoID == id }
        if selectedLFOID == id { selectedLFOID = nil }
        isDirty = true
        syncModulationToEngine()
    }

    /// Update an LFO in-place.
    func updateLFO(id: UUID, transform: (inout LFODefinition) -> Void) {
        if let idx = project.lfos.firstIndex(where: { $0.id == id }) {
            transform(&project.lfos[idx])
            isDirty = true
            syncModulationToEngine()
        }
    }

    /// Add a modulation routing from an LFO to a node parameter.
    @discardableResult
    func addModulationRouting(lfoID: UUID, nodeID: UUID, parameter: ModulationParameter, depth: Double = 0.5) -> ModulationRouting {
        let routing = ModulationRouting(lfoID: lfoID, nodeID: nodeID, parameter: parameter, depth: depth)
        project.modulationRoutings.append(routing)
        isDirty = true
        syncModulationToEngine()
        return routing
    }

    /// Remove a modulation routing.
    func removeModulationRouting(id: UUID) {
        project.modulationRoutings.removeAll { $0.id == id }
        isDirty = true
        syncModulationToEngine()
    }

    /// Update a routing's depth.
    func updateModulationRouting(id: UUID, depth: Double) {
        if let idx = project.modulationRoutings.firstIndex(where: { $0.id == id }) {
            project.modulationRoutings[idx].depth = depth
            isDirty = true
            syncModulationToEngine()
        }
    }

    /// Push all LFO routings to the audio engine.
    func syncModulationToEngine() {
        AudioEngine.shared.syncModulationRoutings(
            lfos: project.lfos,
            routings: project.modulationRoutings
        )
    }

    /// All routings for a specific LFO.
    func routings(for lfoID: UUID) -> [ModulationRouting] {
        project.modulationRoutings.filter { $0.lfoID == lfoID }
    }

    /// All routings for a specific node and parameter.
    func routings(for nodeID: UUID, parameter: ModulationParameter) -> [ModulationRouting] {
        project.modulationRoutings.filter { $0.nodeID == nodeID && $0.parameter == parameter }
    }

    // MARK: - Layout

    /// Spacing constants for tree layout.
    private static let verticalSpacing: Double = 160
    private static let minHorizontalSpacing: Double = 140
    private static let selectedNodeClearance: Double = 600

    /// Compute the horizontal width needed to lay out a node's subtree.
    private func subtreeWidth(of node: Node) -> Double {
        if node.children.isEmpty {
            return node.id == selectedNodeID ? Self.selectedNodeClearance : 0
        }
        let childSlots = node.children.map { max(Self.minHorizontalSpacing, subtreeWidth(of: $0)) }
        let total = childSlots.reduce(0, +)
        return node.id == selectedNodeID ? max(total, Self.selectedNodeClearance) : total
    }

    /// Recursively position nodes in a fan layout.
    /// Root is at (x, y). Children fan out above (negative Y).
    private func recomputeLayout(root: inout Node, x: Double, y: Double, depth: Int) {
        root.position = NodePosition(x: x, y: y)

        let childCount = root.children.count
        guard childCount > 0 else { return }

        let slotWidths = root.children.map { max(Self.minHorizontalSpacing, subtreeWidth(of: $0)) }
        let totalWidth = slotWidths.reduce(0, +)
        let childY = y - Self.verticalSpacing

        var currentX = x - totalWidth / 2
        for i in 0..<childCount {
            let childCenterX = currentX + slotWidths[i] / 2
            recomputeLayout(root: &root.children[i], x: childCenterX, y: childY, depth: depth + 1)
            currentX += slotWidths[i]
        }
    }

    // MARK: - Private Helpers

    private func findNodeRecursive(id: UUID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNodeRecursive(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    private func updateNodeRecursive(id: UUID, in node: inout Node, transform: (inout Node) -> Void) -> Bool {
        if node.id == id {
            transform(&node)
            return true
        }
        for i in 0..<node.children.count {
            if updateNodeRecursive(id: id, in: &node.children[i], transform: transform) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func removeNodeRecursive(id: UUID, from node: inout Node) -> Bool {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            node.children.remove(at: index)
            return true
        }
        for i in 0..<node.children.count {
            if removeNodeRecursive(id: id, from: &node.children[i]) {
                return true
            }
        }
        return false
    }

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}

// MARK: - Math Helpers

private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = abs(a)
    var b = abs(b)
    while b != 0 {
        let t = b
        b = a % b
        a = t
    }
    return a
}

private func lcm(_ a: Int, _ b: Int) -> Int {
    guard a != 0 && b != 0 else { return 1 }
    return abs(a * b) / gcd(a, b)
}
