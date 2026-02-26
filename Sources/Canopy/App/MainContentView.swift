import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @StateObject private var canvasState = CanvasState()
    @StateObject private var bloomState = BloomState()
    @StateObject private var viewModeManager = ViewModeManager()
    @StateObject private var forestPlayback = ForestPlaybackState()

    /// Tracks the previously selected node so we can send allNotesOff on deselect.
    @State private var previousSelectedNodeID: UUID?
    /// Tracks the last tree ID we synced audio for, to skip redundant rebuilds.
    @State private var lastSyncedTreeID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(
                projectState: projectState,
                transportState: transportState,
                forestPlayback: forestPlayback
            )

            switch viewModeManager.mode {
            case .forest:
                ForestCanvasView(
                    projectState: projectState,
                    canvasState: canvasState,
                    bloomState: bloomState,
                    viewModeManager: viewModeManager,
                    transportState: transportState,
                    forestPlayback: forestPlayback
                )
            case .treeDetail:
                CanopyCanvasView(
                    projectState: projectState,
                    canvasState: canvasState,
                    bloomState: bloomState,
                    viewModeManager: viewModeManager,
                    transportState: transportState
                )
            case .focus:
                FocusView(projectState: projectState, transportState: transportState)
            }

            BottomLaneView(projectState: projectState)
        }
        .environmentObject(viewModeManager)
        .background(CanopyColors.canvasBackground)
        .overlay {
            // Forest playback advance polling (hidden, runs during multi-tree playback)
            ForestAdvancePoller(
                projectState: projectState,
                transportState: transportState,
                forestPlayback: forestPlayback,
                onTreeAdvance: { newTree in performTreeSwap(to: newTree) }
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
        }
        .onAppear {
            syncTreeToEngine()
            syncViewModeToTreeCount()
        }
        .onChange(of: projectState.project.trees.count) { _ in
            syncViewModeToTreeCount()
            syncForestAdvanceToState()
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            handleNodeSelectionChange()
        }
        .onChange(of: projectState.selectedTreeID) { _ in
            handleTreeSelectionChange()
        }
        .onChange(of: transportState.isPlaying) { isPlaying in
            if isPlaying {
                handlePlaybackStart()
            } else {
                handlePlaybackStop()
            }
        }
        .onChange(of: viewModeManager.mode) { _ in
            handleViewModeChange()
        }
    }

    // MARK: - View Mode Sync

    /// With 1 empty tree: auto-enter treeDetail (so user can start creating).
    /// With 1 tree that has content: stay in current mode (forest shows "new" node).
    /// With 2+ trees: forest mode is natural. Don't force-switch if already in focus/treeDetail.
    private func syncViewModeToTreeCount() {
        let count = projectState.project.trees.count
        if count <= 1 {
            // Single tree — only auto-enter treeDetail if tree is empty
            if case .focus = viewModeManager.mode { return }
            if case .forest = viewModeManager.mode, singleTreeHasContent() { return }
            if let treeID = projectState.selectedTreeID ?? projectState.project.trees.first?.id {
                viewModeManager.enterTreeDetail(treeID: treeID)
            }
        } else if viewModeManager.isTreeDetail {
            // Grew from 1→2 trees while in treeDetail — stay there (don't yank the user away)
        }
    }

    /// Check if the first (only) tree has any musical content.
    private func singleTreeHasContent() -> Bool {
        guard let tree = projectState.project.trees.first else { return false }
        return !tree.rootNode.sequence.notes.isEmpty || !tree.rootNode.children.isEmpty
    }

    // MARK: - Audio Graph Sync

    /// Build full audio graph from the selected tree. Used on initial load / project switch.
    func syncTreeToEngine() {
        guard let tree = projectState.selectedTree ?? projectState.project.trees.first else { return }

        // Ensure selectedTreeID is set
        if projectState.selectedTreeID == nil {
            projectState.selectedTreeID = tree.id
        }
        lastSyncedTreeID = tree.id

        AudioEngine.shared.buildGraph(from: tree)
        AudioEngine.shared.configureAllPatches(from: tree)
        AudioEngine.shared.loadAllSequences(from: tree, bpm: transportState.bpm)

        // Set focused node for beat polling — default to root if nothing selected
        if transportState.focusedNodeID == nil {
            transportState.focusedNodeID = tree.rootNode.id
        }

        // Push LFO modulation routings to audio engine
        projectState.syncModulationToEngine()

        // Push master bus state to audio engine
        projectState.syncMasterBusToEngine()

        // Push per-node FX chains to audio engine
        let nodes = projectState.allNodesForSelectedTree()
        for node in nodes {
            if !node.effects.isEmpty {
                projectState.syncNodeFXToEngine(nodeID: node.id)
            }
        }
    }

    /// Add a single node to the live audio graph (incremental, no teardown).
    func addNodeToEngine(node: Node) {
        AudioEngine.shared.addNode(node)
        pushPatchToEngine(node.patch, nodeID: node.id)
        loadSequenceToEngine(node)
    }

    /// Remove a single node from the live audio graph (click-free).
    func removeNodeFromEngine(id: UUID) {
        AudioEngine.shared.muteAndRemoveNode(id)
    }

    // MARK: - Tree Selection Change

    private func handleTreeSelectionChange() {
        guard let newID = projectState.selectedTreeID else { return }
        // Skip if we already have the audio graph for this tree
        guard newID != lastSyncedTreeID else { return }
        lastSyncedTreeID = newID

        let wasPlaying = transportState.isPlaying

        // Seamless swap: fade out old sequencers, rebuild, restart if was playing.
        // Never stop transport — playback should be continuous.
        if wasPlaying {
            AudioEngine.shared.stopAllSequencersWithFade()
        }

        AudioEngine.shared.teardownGraph()
        guard let tree = projectState.selectedTree else { return }
        AudioEngine.shared.buildGraph(from: tree)
        AudioEngine.shared.configureAllPatches(from: tree)
        AudioEngine.shared.loadAllSequences(from: tree, bpm: transportState.bpm)

        // Push per-node FX chains
        var nodes: [Node] = []
        collectNodes(from: tree.rootNode, into: &nodes)
        for node in nodes {
            if !node.effects.isEmpty {
                projectState.syncNodeFXToEngine(nodeID: node.id)
            }
        }

        // Push modulation and master bus
        projectState.syncModulationToEngine()
        projectState.syncMasterBusToEngine()

        // Update focused node
        transportState.focusedNodeID = tree.rootNode.id

        // Restart sequencers if playback was active
        if wasPlaying {
            AudioEngine.shared.startAllSequencers(bpm: transportState.bpm)
        }
    }

    // MARK: - Playback State Management

    private func handlePlaybackStart() {
        syncForestAdvanceToState()
    }

    private func handlePlaybackStop() {
        projectState.resetFreeRunningClock()
        forestPlayback.activeTreeID = nil
        forestPlayback.nextTreeID = nil
    }

    /// Called when view mode changes (forest ↔ treeDetail ↔ focus).
    private func handleViewModeChange() {
        if viewModeManager.isForest, projectState.project.trees.count >= 2 {
            // Entering forest with 2+ trees → start playback if not already playing
            if !transportState.isPlaying {
                transportState.startPlayback()
            }
        }
        syncForestAdvanceToState()
    }

    /// Single source of truth: activate or deactivate forest advance based on current state.
    /// Called when trees.count changes, view mode changes, or playback starts.
    private func syncForestAdvanceToState() {
        let trees = projectState.project.trees
        let shouldAdvance = transportState.isPlaying
            && viewModeManager.isForest
            && trees.count >= 2

        if shouldAdvance {
            forestPlayback.activeTreeID = projectState.selectedTreeID ?? trees.first?.id
            forestPlayback.computeNextTree(trees: trees)
        } else if !transportState.isPlaying {
            // Only clear if not playing. If playing in tree detail, keep IDs nil
            // so poller doesn't run, but don't clear if we might re-enter forest.
            forestPlayback.activeTreeID = nil
            forestPlayback.nextTreeID = nil
        } else if !viewModeManager.isForest {
            forestPlayback.activeTreeID = nil
            forestPlayback.nextTreeID = nil
        }
    }

    // MARK: - Node Selection Change

    private func handleNodeSelectionChange() {
        // Release held keyboard notes on the PREVIOUSLY selected node.
        // Only when the sequencer is stopped — during playback the sequencer
        // manages its own voices and allNotesOff would cause a click/gap.
        if let prevID = previousSelectedNodeID, !AudioEngine.shared.isClockRunning {
            AudioEngine.shared.allNotesOff(nodeID: prevID)
        }

        if let node = projectState.selectedNode {
            // Push this node's patch for keyboard playing
            pushPatchToEngine(node.patch, nodeID: node.id)
            transportState.focusedNodeID = node.id

            // Update focus target if already in focus mode
            if case .focus = viewModeManager.mode {
                viewModeManager.enterFocus(nodeID: node.id)
            }
        } else {
            // Node deselected
            if case .focus = viewModeManager.mode {
                viewModeManager.exitFocus()
            }

            // Single tree with content + node deselected → show forest so "new" node appears
            if viewModeManager.isTreeDetail,
               projectState.project.trees.count == 1,
               singleTreeHasContent() {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    viewModeManager.exitTreeDetail()
                }
            }
        }

        previousSelectedNodeID = projectState.selectedNodeID
    }

    private func pushPatchToEngine(_ patch: SoundPatch, nodeID: UUID) {
        switch patch.soundType {
        case .oscillator(let config):
            let waveformIndex: Int
            switch config.waveform {
            case .sine: waveformIndex = 0
            case .triangle: waveformIndex = 1
            case .sawtooth: waveformIndex = 2
            case .square: waveformIndex = 3
            case .noise: waveformIndex = 4
            }
            AudioEngine.shared.configurePatch(
                waveform: waveformIndex,
                detune: config.detune,
                attack: patch.envelope.attack,
                decay: patch.envelope.decay,
                sustain: patch.envelope.sustain,
                release: patch.envelope.release,
                volume: patch.volume,
                nodeID: nodeID
            )
        case .drumKit(let kitConfig):
            for (i, voiceConfig) in kitConfig.voices.enumerated() {
                AudioEngine.shared.configureDrumVoice(index: i, config: voiceConfig, nodeID: nodeID)
            }
            AudioEngine.shared.configurePatch(
                waveform: 0, detune: 0,
                attack: 0, decay: 0, sustain: 0, release: 0,
                volume: patch.volume,
                nodeID: nodeID
            )
        case .westCoast(let config):
            AudioEngine.shared.configureWestCoast(config, nodeID: nodeID)
        case .flow(let config):
            AudioEngine.shared.configureFlow(config, nodeID: nodeID)
        case .tide(let config):
            AudioEngine.shared.configureTide(config, nodeID: nodeID)
        case .swarm(let config):
            AudioEngine.shared.configureSwarm(config, nodeID: nodeID)
        default:
            break
        }
        AudioEngine.shared.setNodePan(Float(patch.pan), nodeID: nodeID)
    }

    private func loadSequenceToEngine(_ node: Node) {
        let seq = node.sequence
        let events = seq.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration,
                probability: event.probability,
                ratchetCount: event.ratchetCount
            )
        }
        let key = node.scaleOverride ?? node.key
        let mutation = seq.mutation
        AudioEngine.shared.loadSequence(
            events, lengthInBeats: seq.lengthInBeats, nodeID: node.id,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals
        )
        AudioEngine.shared.setGlobalProbability(seq.globalProbability, nodeID: node.id)
    }

    // MARK: - Tree Swap (for forest playback advance)

    private func performTreeSwap(to tree: NodeTree) {
        // Track that we've synced this tree so handleTreeSelectionChange doesn't double-rebuild
        lastSyncedTreeID = tree.id

        // Crossfade swap: builds new graph alongside old, starts new sequencers,
        // fades out old units, then detaches them. Zero-gap, click-free.
        AudioEngine.shared.crossfadeSwap(to: tree, bpm: transportState.bpm)

        // Push per-node FX chains for new tree
        var nodes: [Node] = []
        collectNodes(from: tree.rootNode, into: &nodes)
        for node in nodes {
            if !node.effects.isEmpty {
                projectState.syncNodeFXToEngine(nodeID: node.id)
            }
        }
        projectState.syncModulationToEngine()
        projectState.syncMasterBusToEngine()

        // Update selected tree to match the playing tree (highlights in forest UI)
        projectState.selectedTreeID = tree.id
    }

    // MARK: - Private Helpers

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}

// MARK: - ForestAdvancePoller

/// Hidden TimelineView that polls the audio clock and triggers tree advances
/// when a cycle completes during multi-tree sequential playback.
private struct ForestAdvancePoller: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @ObservedObject var forestPlayback: ForestPlaybackState
    let onTreeAdvance: (NodeTree) -> Void

    var body: some View {
        if transportState.isPlaying && projectState.project.trees.count >= 2 && forestPlayback.activeTreeID != nil {
            TimelineView(.animation) { timeline in
                let _ = checkAdvance()
                Color.clear
            }
        }
    }

    private func checkAdvance() {
        let clockSamples = AudioEngine.shared.graph.clockSamplePosition.pointee
        let sampleRate = AudioEngine.shared.sampleRate
        guard sampleRate > 0 else { return }

        // Compute cycle length for the active tree
        let trees = projectState.project.trees
        guard let activeID = forestPlayback.activeTreeID,
              let activeTree = trees.first(where: { $0.id == activeID }) else { return }

        let cycleLength = computeCycleLength(tree: activeTree)

        if let newTree = forestPlayback.checkAndAdvance(
            clockSamples: clockSamples,
            sampleRate: sampleRate,
            bpm: transportState.bpm,
            cycleLengthInBeats: cycleLength,
            trees: trees
        ) {
            onTreeAdvance(newTree)
        }
    }

    private func computeCycleLength(tree: NodeTree) -> Double {
        var nodes: [Node] = []
        collectNodes(from: tree.rootNode, into: &nodes)
        guard !nodes.isEmpty else { return 1 }
        let sd = NoteSequence.stepDuration
        let stepCounts = nodes.map { max(1, Int(round($0.sequence.lengthInBeats / sd))) }
        let lcmSteps = stepCounts.reduce(1) { lcm($0, $1) }
        return Double(lcmSteps) * sd
    }

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }

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
}
