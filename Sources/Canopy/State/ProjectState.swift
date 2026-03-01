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
    @Published var selectedTreeID: UUID?
    @Published var selectedLFOID: UUID?
    @Published var currentFilePath: URL?
    @Published var isDirty: Bool = false

    /// Closure set by AppDelegate to perform file I/O — keeps ProjectState free of file system knowledge.
    var autoSaveHandler: ((CanopyProject, URL) -> Void)?
    private var autoSaveWork: DispatchWorkItem?

    // MARK: - Transient keyboard state (not persisted)

    /// Base octave for both on-screen and computer keyboard input.
    @Published var keyboardOctave: Int = 3
    /// MIDI notes currently held via computer keyboard — merged into visual keyboard state.
    @Published var computerKeyPressedNotes: Set<Int> = []
    /// When true, the computer keyboard acts as a MIDI piano input.
    @Published var computerKeyboardEnabled: Bool = true

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
        let sd = node.stepRate.beatsPerStep
        let maxBeats = 32.0 * sd  // 32 steps at node's rate

        // Compute target length from the buffer span
        let targetLength = PhraseDetector.spanLength(from: captureBuffer, maxBeats: maxBeats, stepRate: node.stepRate)
        guard targetLength > 0 else { return false }

        // Extract phrase fitted to the computed length
        let phrase = PhraseDetector.extractPhrase(from: captureBuffer, lengthInBeats: targetLength)
        guard !phrase.isEmpty else { return false }

        // Quantize to grid and scale
        let quantized = CaptureQuantizer.quantize(
            events: phrase,
            strength: captureQuantizeStrength,
            key: key,
            lengthInBeats: targetLength,
            stepRate: node.stepRate
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

        // Rebuild arp pool if this node has arp enabled
        if findNode(id: nodeID)?.sequence.arpConfig != nil {
            rebuildArpPool(for: nodeID)
        }

        return true
    }

    /// Resolve the musical key for a node (node override → tree scale → global key).
    private func resolveKeyForNode(_ node: Node) -> MusicalKey {
        if let override = node.scaleOverride { return override }
        if let tree = treeContainingNode(node.id)?.tree, let treeScale = tree.scale { return treeScale }
        return project.globalKey
    }

    // MARK: - Cached computations (invalidated on project mutation)

    private var _cachedAllNodes: [Node]?
    private var _cachedCycleLength: Double?

    init(project: CanopyProject = ProjectFactory.newProject()) {
        self.project = project
        self.selectedTreeID = project.trees.first?.id
    }

    // MARK: - Tree Selection & CRUD

    /// The currently selected tree, if any.
    var selectedTree: NodeTree? {
        guard let id = selectedTreeID else { return nil }
        return project.trees.first { $0.id == id }
    }

    /// Select a tree by ID. Auto-selects the tree's root node.
    func selectTree(_ id: UUID?) {
        selectedTreeID = id
        if let id, let tree = project.trees.first(where: { $0.id == id }) {
            selectedNodeID = tree.rootNode.id
        } else {
            selectedNodeID = nil
        }
    }

    /// Find the tree containing a given node ID.
    func treeContainingNode(_ nodeID: UUID) -> (index: Int, tree: NodeTree)? {
        for (i, tree) in project.trees.enumerated() {
            if findNodeRecursive(id: nodeID, in: tree.rootNode) != nil {
                return (i, tree)
            }
        }
        return nil
    }

    /// Index of the tree containing a node, for mutation via project.trees[i].
    private func treeIndexContaining(_ nodeID: UUID) -> Int? {
        treeContainingNode(nodeID)?.index
    }

    /// Add a new tree with a fresh seed node. Enforces max 8 trees.
    @discardableResult
    func addTree(name: String? = nil) -> NodeTree? {
        guard project.trees.count < 8 else { return nil }
        let treeName = name ?? "Tree \(project.trees.count + 1)"
        let seedNode = Node(
            name: "Seed",
            type: .seed,
            key: project.globalKey,
            sequence: NoteSequence(lengthInBeats: 4),
            patch: SoundPatch(
                name: "Sine Seed",
                soundType: .oscillator(OscillatorConfig(waveform: .sine))
            ),
            position: NodePosition(x: 0, y: 0)
        )
        let tree = NodeTree(name: treeName, rootNode: seedNode)
        project.trees.append(tree)
        markDirty()
        return tree
    }

    /// Remove a tree by ID. Enforces min 1 tree. Selects adjacent after removal.
    func removeTree(id: UUID) {
        guard project.trees.count > 1 else { return }
        guard let idx = project.trees.firstIndex(where: { $0.id == id }) else { return }
        project.trees.remove(at: idx)
        // Select adjacent tree
        let newIdx = min(idx, project.trees.count - 1)
        selectTree(project.trees[newIdx].id)
        markDirty()
    }

    /// Rename a tree.
    func renameTree(id: UUID, name: String) {
        guard let idx = project.trees.firstIndex(where: { $0.id == id }) else { return }
        project.trees[idx].name = name
        markDirty()
    }

    /// Deep-copy a tree with new UUIDs. Enforces max 8 trees.
    @discardableResult
    func duplicateTree(id: UUID) -> NodeTree? {
        guard project.trees.count < 8,
              let source = project.trees.first(where: { $0.id == id }) else { return nil }
        let newTree = NodeTree(
            name: source.name + " copy",
            rootNode: deepCopyNode(source.rootNode),
            transition: source.transition,
            scale: source.scale
        )
        project.trees.append(newTree)
        markDirty()
        return newTree
    }

    /// Recursively copy a node subtree with fresh UUIDs.
    private func deepCopyNode(_ node: Node) -> Node {
        var copy = node
        copy.id = UUID()
        copy.children = node.children.map { deepCopyNode($0) }
        return copy
    }

    /// All nodes for the selected tree (for canvas rendering).
    /// Falls back to first tree if no tree is selected.
    func allNodesForSelectedTree() -> [Node] {
        guard let tree = selectedTree ?? project.trees.first else { return [] }
        var result: [Node] = []
        collectNodes(from: tree.rootNode, into: &result)
        return result
    }

    /// Flattened list of all nodes in a specific tree.
    func nodesForTree(_ treeID: UUID) -> [Node] {
        guard let tree = project.trees.first(where: { $0.id == treeID }) else { return [] }
        var result: [Node] = []
        collectNodes(from: tree.rootNode, into: &result)
        return result
    }

    /// Select a node and also select the tree containing it.
    func selectNodeInTree(_ nodeID: UUID) {
        if let (_, tree) = treeContainingNode(nodeID) {
            selectedTreeID = tree.id
        }
        selectedNodeID = nodeID
    }

    /// Cycle length for the selected tree (falls back to first tree).
    /// Uses 96 PPQN ticks to handle mixed step rates correctly.
    func cycleLengthForSelectedTree() -> Double {
        let nodes = allNodesForSelectedTree()
        guard !nodes.isEmpty else { return 1 }
        let ticksPerBeat = 96.0
        let tickCounts = nodes.map { max(1, Int(round($0.sequence.lengthInBeats * ticksPerBeat))) }
        let lcmTicks = tickCounts.reduce(1) { lcm($0, $1) }
        return Double(lcmTicks) / ticksPerBeat
    }

    // MARK: - Dirty Tracking & Auto-Save

    /// Mark the project as dirty and schedule a debounced auto-save (2s).
    /// Guards redundant assignments to avoid extra @Published notifications.
    func markDirty() {
        if !isDirty { isDirty = true }
        scheduleAutoSave()
    }

    /// Perform an immediate save, cancelling any pending debounce.
    func performAutoSave() {
        autoSaveWork?.cancel()
        autoSaveWork = nil
        guard let url = currentFilePath else { return }
        project.modifiedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        autoSaveHandler?(project, url)
        isDirty = false
    }

    private func scheduleAutoSave() {
        autoSaveWork?.cancel()
        guard currentFilePath != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.performAutoSave()
        }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// The currently selected node, if any.
    var selectedNode: Node? {
        guard let id = selectedNodeID else { return nil }
        return findNode(id: id)
    }

    func selectNode(_ id: UUID?) {
        selectedNodeID = id
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
                markDirty()
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

        // Recompute layout for the tree containing the parent
        if let treeIdx = treeIndexContaining(parentID) {
            recomputeLayout(root: &project.trees[treeIdx].rootNode, x: 0, y: 0, depth: 0)
        }

        markDirty()
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
                pitchRange: preset.defaultPitchRange,
                arpConfig: preset.defaultArpConfig
            ),
            patch: preset.defaultPatch,
            position: parentPos,
            presetID: preset.id
        )

        updateNode(id: parentID) { parent in
            parent.children.append(newNode)
        }

        if let treeIdx = treeIndexContaining(parentID) {
            recomputeLayout(root: &project.trees[treeIdx].rootNode, x: 0, y: 0, depth: 0)
        }

        markDirty()
        return newNode
    }

    /// Remove a node by ID. Cannot remove any tree's root node.
    func removeNode(id: UUID) {
        guard let treeIdx = treeIndexContaining(id) else { return }
        let rootID = project.trees[treeIdx].rootNode.id
        guard id != rootID else { return }

        removeNodeRecursive(id: id, from: &project.trees[treeIdx].rootNode)
        recomputeLayout(root: &project.trees[treeIdx].rootNode, x: 0, y: 0, depth: 0)
        markDirty()
    }

    // MARK: - Module Swapping

    /// Swap the sound engine on a node. Rebuilds the audio subgraph with full
    /// patch, sequence, FX, and sequencer configuration — matching the project-load path.
    func swapEngine(nodeID: UUID, to soundType: SoundType) {
        AudioEngine.shared.muteAndRemoveNode(nodeID)
        updateNode(id: nodeID) { node in
            node.patch.soundType = soundType
        }
        if let node = findNode(id: nodeID) {
            AudioEngine.shared.addNode(node)
            AudioEngine.shared.configureSingleNodePatch(node)
            AudioEngine.shared.loadSingleNodeSequence(node, bpm: project.bpm)
            if AudioEngine.shared.isClockRunning {
                AudioEngine.shared.startNodeSequencer(nodeID: nodeID, bpm: project.bpm)
            }
        }
        markDirty()
    }

    /// Swap the sequencer UI type (pitched grid vs drum grid vs orbit).
    func swapSequencer(nodeID: UUID, to type: SequencerType) {
        updateNode(id: nodeID) { node in
            node.sequencerType = type
            if type == .orbit {
                // Ensure orbit config exists
                if node.orbitConfig == nil {
                    node.orbitConfig = OrbitConfig()
                }
            }
        }
        // Send orbit sequencer toggle to audio thread
        if type == .orbit {
            if let node = findNode(id: nodeID), let orbitConfig = node.orbitConfig {
                AudioEngine.shared.configureOrbit(orbitConfig, nodeID: nodeID)
            }
            AudioEngine.shared.setUseOrbitSequencer(true, nodeID: nodeID)
        } else {
            AudioEngine.shared.setUseOrbitSequencer(false, nodeID: nodeID)
        }
        markDirty()
    }

    /// Swap the input mode (keyboard vs pad grid).
    func swapInput(nodeID: UUID, to mode: InputMode) {
        updateNode(id: nodeID) { $0.inputMode = mode }
        markDirty()
    }

    // MARK: - Arp Pool

    /// Rebuild and send arp pool data to the audio engine for a node.
    /// Call after any edit that changes the note pool (toggle, fill, capture, mode/octave change).
    func rebuildArpPool(for nodeID: UUID) {
        guard let node = findNode(id: nodeID),
              let arpConfig = node.sequence.arpConfig else { return }

        let sampleRate = AudioEngine.shared.sampleRate
        guard sampleRate > 0 else { return }

        // Calculate samples per arp step
        let bpm = project.bpm
        let beatsPerSecond = bpm / 60.0
        let secondsPerStep = arpConfig.rate.beatsPerStep / beatsPerSecond
        let samplesPerStep = max(1, Int(secondsPerStep * sampleRate))

        // Send config
        AudioEngine.shared.setArpConfig(
            active: true,
            samplesPerStep: samplesPerStep,
            gateLength: arpConfig.gateLength,
            mode: arpConfig.mode,
            nodeID: nodeID
        )

        // Build and send pool
        let pool = ArpNotePool.build(from: node.sequence, config: arpConfig)
        AudioEngine.shared.setArpPool(
            pitches: Array(pool.pitches.prefix(pool.count)),
            velocities: Array(pool.velocities.prefix(pool.count)),
            startBeats: Array(pool.startBeats.prefix(pool.count)),
            endBeats: Array(pool.endBeats.prefix(pool.count)),
            nodeID: nodeID
        )
    }

    /// Disable arp on a node's audio engine sequencer.
    func disableArp(for nodeID: UUID) {
        AudioEngine.shared.setArpConfig(
            active: false, samplesPerStep: 1, gateLength: 0.5, mode: .up, nodeID: nodeID
        )
    }

    /// Compute the LCM of all nodes' sequence lengths (the natural polyrhythmic cycle).
    /// Uses 96 PPQN ticks to handle mixed step rates correctly.
    func cycleLengthInBeats() -> Double {
        if let cached = _cachedCycleLength {
            return cached
        }
        let nodes = allNodes()
        guard !nodes.isEmpty else { return 1 }
        let ticksPerBeat = 96.0
        let tickCounts = nodes.map { max(1, Int(round($0.sequence.lengthInBeats * ticksPerBeat))) }
        let lcmTicks = tickCounts.reduce(1) { lcm($0, $1) }
        let result = Double(lcmTicks) / ticksPerBeat
        _cachedCycleLength = result
        return result
    }

    // MARK: - Node FX Chain

    /// Add an effect to a node's chain.
    @discardableResult
    func addNodeEffect(nodeID: UUID, type: EffectType) -> Effect {
        let effect = Effect(type: type)
        updateNode(id: nodeID) { node in
            if node.effects.count < EffectChain.maxSlots {
                node.effects.append(effect)
            }
        }
        syncNodeFXToEngine(nodeID: nodeID)
        return effect
    }

    /// Remove an effect from a node's chain.
    func removeNodeEffect(nodeID: UUID, effectID: UUID) {
        updateNode(id: nodeID) { node in
            node.effects.removeAll { $0.id == effectID }
        }
        syncNodeFXToEngine(nodeID: nodeID)
    }

    /// Update an effect's parameters on a node.
    func updateNodeEffect(nodeID: UUID, effectID: UUID, transform: (inout Effect) -> Void) {
        updateNode(id: nodeID) { node in
            if let idx = node.effects.firstIndex(where: { $0.id == effectID }) {
                transform(&node.effects[idx])
            }
        }
        syncNodeFXToEngine(nodeID: nodeID)
    }

    /// Reorder effects on a node (move from sourceIndex to destinationIndex).
    func reorderNodeEffects(nodeID: UUID, from source: IndexSet, to destination: Int) {
        updateNode(id: nodeID) { node in
            node.effects.move(fromOffsets: source, toOffset: destination)
        }
        syncNodeFXToEngine(nodeID: nodeID)
    }

    /// Toggle bypass on a node effect.
    func toggleNodeEffectBypass(nodeID: UUID, effectID: UUID) {
        updateNode(id: nodeID) { node in
            if let idx = node.effects.firstIndex(where: { $0.id == effectID }) {
                node.effects[idx].bypassed.toggle()
            }
        }
        syncNodeFXToEngine(nodeID: nodeID)
    }

    /// Push a node's effect chain to the audio engine.
    func syncNodeFXToEngine(nodeID: UUID) {
        guard let node = findNode(id: nodeID) else { return }
        AudioEngine.shared.configureNodeFXChain(effects: node.effects, nodeID: nodeID)
        // Ensure BPM reaches tempo-synced effects (e.g. DRIFT sync mode) after chain rebuild
        AudioEngine.shared.setNodeFXChainBPM(project.bpm, nodeID: nodeID)
    }

    // MARK: - Master Bus FX

    /// Add an effect to the master bus chain.
    @discardableResult
    func addMasterEffect(type: EffectType) -> Effect {
        let effect = Effect(type: type)
        if project.masterBus.effects.count < EffectChain.maxSlots {
            project.masterBus.effects.append(effect)
        }
        markDirty()
        syncMasterFXToEngine()
        return effect
    }

    /// Remove an effect from the master bus chain.
    func removeMasterEffect(effectID: UUID) {
        project.masterBus.effects.removeAll { $0.id == effectID }
        markDirty()
        syncMasterFXToEngine()
    }

    /// Update a master bus effect's parameters.
    func updateMasterEffect(effectID: UUID, transform: (inout Effect) -> Void) {
        if let idx = project.masterBus.effects.firstIndex(where: { $0.id == effectID }) {
            transform(&project.masterBus.effects[idx])
            markDirty()
            syncMasterFXToEngine()
        }
    }

    /// Reorder effects on the master bus.
    func reorderMasterEffects(from source: IndexSet, to destination: Int) {
        project.masterBus.effects.move(fromOffsets: source, toOffset: destination)
        markDirty()
        syncMasterFXToEngine()
    }

    /// Toggle bypass on a master bus effect.
    func toggleMasterEffectBypass(effectID: UUID) {
        if let idx = project.masterBus.effects.firstIndex(where: { $0.id == effectID }) {
            project.masterBus.effects[idx].bypassed.toggle()
            markDirty()
            syncMasterFXToEngine()
        }
    }

    /// Set master bus volume (0.0–2.0, linear; 2.0 = +6dB).
    func setMasterVolume(_ volume: Double) {
        project.masterBus.volume = max(0, min(2, volume))
        markDirty()
        AudioEngine.shared.configureMasterVolume(Float(volume))
    }

    /// Configure Shore limiter.
    func configureShore(enabled: Bool, ceiling: Double) {
        project.masterBus.shore.enabled = enabled
        project.masterBus.shore.ceiling = ceiling
        markDirty()
        AudioEngine.shared.configureShore(enabled: enabled, ceiling: ceiling)
    }

    /// Push master bus FX chain to the audio engine.
    func syncMasterFXToEngine() {
        AudioEngine.shared.configureMasterFXChain(effects: project.masterBus.effects)
        // Ensure BPM reaches tempo-synced effects after chain rebuild
        AudioEngine.shared.setMasterBusBPM(project.bpm)
    }

    /// Push master bus state (volume, shore, fx chain) to the audio engine.
    func syncMasterBusToEngine() {
        AudioEngine.shared.configureMasterVolume(Float(project.masterBus.volume))
        AudioEngine.shared.configureShore(
            enabled: project.masterBus.shore.enabled,
            ceiling: project.masterBus.shore.ceiling
        )
        syncMasterFXToEngine()
    }

    // MARK: - Mute / Solo

    /// Toggle mute state on a node and sync to audio engine.
    func toggleMute(nodeID: UUID) {
        updateNode(id: nodeID) { $0.isMuted.toggle() }
        syncMuteSoloToEngine()
    }

    /// Toggle solo state on a node and sync to audio engine.
    func toggleSolo(nodeID: UUID) {
        updateNode(id: nodeID) { $0.isSolo.toggle() }
        syncMuteSoloToEngine()
    }

    /// Exclusive solo: solo only the target node, un-solo all others in the tree.
    func exclusiveSolo(nodeID: UUID) {
        let nodes = allNodesForSelectedTree()
        for node in nodes {
            updateNode(id: node.id) { $0.isSolo = ($0.id == nodeID) }
        }
        syncMuteSoloToEngine()
    }

    /// Resolve effective mute for all nodes in the selected tree and push to audio engine.
    /// Solo logic: if any node is soloed, only soloed nodes play.
    /// Mute overrides solo: if a node is both soloed and muted, it's silent.
    func syncMuteSoloToEngine() {
        let nodes = allNodesForSelectedTree()
        let anySoloed = nodes.contains { $0.isSolo }

        for node in nodes {
            let effectiveMute: Bool
            if anySoloed {
                effectiveMute = node.isMuted || !node.isSolo
            } else {
                effectiveMute = node.isMuted
            }
            AudioEngine.shared.setNodeMuted(effectiveMute, nodeID: node.id)
        }
    }

    // MARK: - LFO / Modulation

    /// Add a new LFO with auto-generated name and color.
    @discardableResult
    func addLFO() -> LFODefinition {
        let index = project.lfos.count + 1
        let colorIndex = (project.lfos.count) % 8
        let lfo = LFODefinition(name: "LFO \(index)", colorIndex: colorIndex)
        project.lfos.append(lfo)
        markDirty()
        syncModulationToEngine()
        return lfo
    }

    /// Remove an LFO and all its routings.
    func removeLFO(id: UUID) {
        project.lfos.removeAll { $0.id == id }
        project.modulationRoutings.removeAll { $0.lfoID == id }
        if selectedLFOID == id { selectedLFOID = nil }
        markDirty()
        syncModulationToEngine()
    }

    /// Update an LFO in-place.
    func updateLFO(id: UUID, transform: (inout LFODefinition) -> Void) {
        if let idx = project.lfos.firstIndex(where: { $0.id == id }) {
            transform(&project.lfos[idx])
            markDirty()
            syncModulationToEngine()
        }
    }

    /// Add a modulation routing from an LFO to a node parameter.
    @discardableResult
    func addModulationRouting(lfoID: UUID, nodeID: UUID, parameter: ModulationParameter, depth: Double = 0.5) -> ModulationRouting {
        let routing = ModulationRouting(lfoID: lfoID, nodeID: nodeID, parameter: parameter, depth: depth)
        project.modulationRoutings.append(routing)
        markDirty()
        syncModulationToEngine()
        return routing
    }

    /// Remove a modulation routing.
    func removeModulationRouting(id: UUID) {
        project.modulationRoutings.removeAll { $0.id == id }
        markDirty()
        syncModulationToEngine()
    }

    /// Update a routing's depth.
    func updateModulationRouting(id: UUID, depth: Double) {
        if let idx = project.modulationRoutings.firstIndex(where: { $0.id == id }) {
            project.modulationRoutings[idx].depth = depth
            markDirty()
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
