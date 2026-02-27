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
            // Forest timeline polling (hidden, runs during forest timeline playback)
            ForestTimelinePoller(
                projectState: projectState,
                transportState: transportState,
                forestPlayback: forestPlayback,
                onRegionTransition: { newTreeID, oldTreeID in
                    handleTimelineRegionTransition(newTreeID: newTreeID, oldTreeID: oldTreeID)
                }
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
        .onChange(of: forestPlayback.isLockedToTree) { _ in
            syncForestAdvanceToState()
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
        forestPlayback.isLockedToTree = false
        forestPlayback.timeline = nil
        AudioEngine.shared.clearStagedTree()
    }

    /// Called when view mode changes (forest ↔ treeDetail ↔ focus).
    private func handleViewModeChange() {
        // Entering tree detail during playback → lock to that tree (it loops until user exits)
        if viewModeManager.isTreeDetail && transportState.isPlaying
            && projectState.project.trees.count >= 2 {
            forestPlayback.isLockedToTree = true
        }
        if viewModeManager.isForest, projectState.project.trees.count >= 2 {
            // Entering forest with 2+ trees → start playback if not already playing
            if !transportState.isPlaying {
                transportState.startPlayback()
            }
        }
        syncForestAdvanceToState()
    }

    /// Single source of truth: activate or deactivate forest advance based on current state.
    /// Called when trees.count changes, view mode changes, playback starts, or lock changes.
    private func syncForestAdvanceToState() {
        let trees = projectState.project.trees

        // If a node is selected in forest during playback, auto-lock
        // (covers the 1→2 tree creation race where trees.count fires before node selection)
        if viewModeManager.isForest && transportState.isPlaying
            && trees.count >= 2 && projectState.selectedNodeID != nil {
            forestPlayback.isLockedToTree = true
        }

        let shouldAdvance = transportState.isPlaying
            && viewModeManager.isForest
            && trees.count >= 2
            && !forestPlayback.isLockedToTree

        if shouldAdvance {
            forestPlayback.activeTreeID = projectState.selectedTreeID ?? trees.first?.id
            if forestPlayback.timeline == nil {
                startForestPlayback()
            }
        } else if forestPlayback.isLockedToTree && transportState.isPlaying {
            // Locked: keep activeTreeID set, clear next/staging so no advance occurs.
            // Extend region end to Int64.max so locked tree loops forever.
            forestPlayback.activeTreeID = projectState.selectedTreeID ?? trees.first?.id
            forestPlayback.nextTreeID = nil
            forestPlayback.timeline = nil
            AudioEngine.shared.clearStagedTree()
            AudioEngine.shared.setActiveRegionEnd(Int64.max)
        } else if !transportState.isPlaying {
            forestPlayback.activeTreeID = nil
            forestPlayback.nextTreeID = nil
            forestPlayback.isLockedToTree = false
            forestPlayback.timeline = nil
            AudioEngine.shared.clearStagedTree()
        } else if !viewModeManager.isForest {
            forestPlayback.activeTreeID = nil
            forestPlayback.nextTreeID = nil
            forestPlayback.timeline = nil
            AudioEngine.shared.clearStagedTree()
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

            // Node selected during forest playback → lock to this tree (user is interacting)
            if viewModeManager.isForest && transportState.isPlaying
                && projectState.project.trees.count >= 2 {
                forestPlayback.isLockedToTree = true
            }

            // Update focus target if already in focus mode
            if case .focus = viewModeManager.mode {
                viewModeManager.enterFocus(nodeID: node.id)
            }
        } else {
            // Node deselected
            if case .focus = viewModeManager.mode {
                viewModeManager.exitFocus()
            }

            // Node deselected → unlock so forest advance resumes
            if forestPlayback.isLockedToTree {
                forestPlayback.isLockedToTree = false
            }

            // Node deselected in tree detail → return to forest
            if viewModeManager.isTreeDetail {
                let treeCount = projectState.project.trees.count
                if treeCount >= 2 {
                    // Multi-tree → return to forest, advance resumes (lock already cleared above)
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        viewModeManager.exitTreeDetail()
                    }
                } else if treeCount == 1, singleTreeHasContent() {
                    // Single tree with content → forest so "new" node appears
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        viewModeManager.exitTreeDetail()
                    }
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

    // MARK: - Forest Timeline Playback

    /// Create the forest timeline and start forest playback with region-gated sequencers.
    /// Called when shouldAdvance becomes true and no timeline exists.
    private func startForestPlayback() {
        let trees = projectState.project.trees
        guard trees.count >= 2 else { return }

        let activeTree: NodeTree
        if let activeID = forestPlayback.activeTreeID,
           let tree = trees.first(where: { $0.id == activeID }) {
            activeTree = tree
        } else if let tree = projectState.selectedTree ?? trees.first {
            activeTree = tree
        } else { return }

        let sampleRate = AudioEngine.shared.sampleRate
        let bpm = transportState.bpm
        guard sampleRate > 0 else { return }

        let timeline = ForestTimeline()

        // Region 1: current tree
        let cycle1 = forestPlayback.computeCycleLength(tree: activeTree)
        let len1 = Int64(cycle1 * 60.0 * sampleRate / bpm)
        timeline.appendRegion(TimelineRegion(
            treeID: activeTree.id,
            startSample: 0, endSample: len1,
            lengthInBeats: cycle1
        ))

        // Set region bounds on active tree's units (already started by TransportState)
        AudioEngine.shared.setActiveRegionBounds(start: 0, end: len1)

        // Region 2: next tree (pre-stage + arm)
        forestPlayback.computeNextTree(trees: trees)
        if let nextID = forestPlayback.nextTreeID,
           let nextTree = trees.first(where: { $0.id == nextID }) {
            let cycle2 = forestPlayback.computeCycleLength(tree: nextTree)
            let len2 = Int64(cycle2 * 60.0 * sampleRate / bpm)
            timeline.appendRegion(TimelineRegion(
                treeID: nextTree.id,
                startSample: len1, endSample: len1 + len2,
                lengthInBeats: cycle2
            ))
            AudioEngine.shared.stageNextTree(nextTree, bpm: bpm)
            AudioEngine.shared.armStagedUnits(regionStart: len1, regionEnd: len1 + len2)
        }

        forestPlayback.timeline = timeline
    }

    /// Handle a region transition detected by the timeline poller.
    /// The audio thread has already auto-started the new tree's sequencers and
    /// auto-stopped the old tree's sequencers via region gating.
    private func handleTimelineRegionTransition(newTreeID: UUID, oldTreeID: UUID?) {
        // Track that we've synced this tree so handleTreeSelectionChange doesn't double-rebuild
        lastSyncedTreeID = newTreeID

        // 1. Promote staged units → active (so BPM/transport commands reach them)
        AudioEngine.shared.promoteStagedToActive()

        // 2. Drain old tree's units (already auto-stopped, schedule cleanup)
        if let oldID = oldTreeID,
           let oldTree = projectState.project.trees.first(where: { $0.id == oldID }) {
            var nodes: [Node] = []
            collectNodes(from: oldTree.rootNode, into: &nodes)
            AudioEngine.shared.drainUnits(for: nodes.map { $0.id })
        }

        // 3. Sync FX, modulation, master bus for new tree
        if let newTree = projectState.project.trees.first(where: { $0.id == newTreeID }) {
            var nodes: [Node] = []
            collectNodes(from: newTree.rootNode, into: &nodes)
            for node in nodes {
                if !node.effects.isEmpty {
                    projectState.syncNodeFXToEngine(nodeID: node.id)
                }
            }
        }
        projectState.syncModulationToEngine()
        projectState.syncMasterBusToEngine()

        // 4. Update UI state
        forestPlayback.activeTreeID = newTreeID
        projectState.selectedTreeID = newTreeID
        forestPlayback.computeNextTree(trees: projectState.project.trees)

        // 5. Prune old timeline regions
        let currentSample = AudioEngine.shared.graph.clockSamplePosition.pointee
        forestPlayback.timeline?.pruneRegionsBefore(currentSample)
    }

    // MARK: - Private Helpers

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}

// MARK: - ForestTimelinePoller

/// Hidden TimelineView that polls the continuous forest clock and detects
/// region transitions. The audio thread handles transitions sample-accurately
/// via region gating — this poller only updates UI state and pre-stages
/// upcoming trees.
private struct ForestTimelinePoller: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @ObservedObject var forestPlayback: ForestPlaybackState
    let onRegionTransition: (_ newTreeID: UUID, _ oldTreeID: UUID?) -> Void

    @State private var lastDetectedTreeID: UUID?
    @State private var hasStaged: Bool = false

    var body: some View {
        if transportState.isPlaying && forestPlayback.timeline != nil {
            TimelineView(.animation) { _ in
                let _ = pollTimeline()
                Color.clear
            }
        }
    }

    private func pollTimeline() {
        guard let timeline = forestPlayback.timeline else { return }
        let currentSample = AudioEngine.shared.graph.clockSamplePosition.pointee

        // 1. Detect if we've entered a new region → update UI + trigger transition handling
        if let currentRegion = timeline.regionForSample(currentSample),
           currentRegion.treeID != lastDetectedTreeID {
            let oldTreeID = lastDetectedTreeID
            lastDetectedTreeID = currentRegion.treeID
            hasStaged = false
            onRegionTransition(currentRegion.treeID, oldTreeID)
        }

        // 2. Pre-stage next tree if approaching boundary (2 sec ahead)
        if !hasStaged {
            let margin = Int64(2.0 * AudioEngine.shared.sampleRate)
            if let nextBoundary = timeline.nextBoundaryAfter(currentSample),
               currentSample > nextBoundary - margin {
                stageNextRegion(afterBoundary: nextBoundary)
                hasStaged = true
            }
        }
    }

    /// Compute the next tree, append a timeline region, and arm the staged units.
    private func stageNextRegion(afterBoundary boundary: Int64) {
        let trees = projectState.project.trees
        guard trees.count >= 2,
              let nextID = forestPlayback.nextTreeID,
              nextID != AudioEngine.shared.stagedTreeID,
              let nextTree = trees.first(where: { $0.id == nextID }),
              let timeline = forestPlayback.timeline else { return }

        let cycleLength = forestPlayback.computeCycleLength(tree: nextTree)
        let sampleRate = AudioEngine.shared.sampleRate
        let bpm = transportState.bpm
        guard sampleRate > 0 else { return }
        let regionLen = Int64(cycleLength * 60.0 * sampleRate / bpm)

        timeline.appendRegion(TimelineRegion(
            treeID: nextTree.id,
            startSample: boundary,
            endSample: boundary + regionLen,
            lengthInBeats: cycleLength
        ))

        AudioEngine.shared.stageNextTree(nextTree, bpm: bpm)
        AudioEngine.shared.armStagedUnits(regionStart: boundary, regionEnd: boundary + regionLen)
    }
}
