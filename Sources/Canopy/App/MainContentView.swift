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
            case .focus:
                FocusView(projectState: projectState, transportState: transportState)
            case .meadow:
                MeadowView(projectState: projectState, canvasState: canvasState, transportState: transportState)
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
        }
        .onChange(of: projectState.project.trees.count) { _ in
            DispatchQueue.main.async {
                syncForestAdvanceToState()
            }
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            DispatchQueue.main.async { handleNodeSelectionChange() }
        }
        .onChange(of: projectState.selectedTreeID) { _ in
            DispatchQueue.main.async { handleTreeSelectionChange() }
        }
        .onReceive(transportState.$isPlaying.removeDuplicates().dropFirst()) { isPlaying in
            DispatchQueue.main.async {
                if isPlaying {
                    handlePlaybackStart()
                } else {
                    handlePlaybackStop()
                }
            }
        }
        .onChange(of: viewModeManager.mode) { _ in
            DispatchQueue.main.async { handleViewModeChange() }
        }
        .onChange(of: forestPlayback.isLockedToTree) { _ in
            DispatchQueue.main.async { syncForestAdvanceToState() }
        }
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

        // Apply persisted mute/solo states to audio engine
        projectState.syncMuteSoloToEngine()
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

        // Full reset in forest with 2+ trees: dismiss bloom, select tree[0]
        let trees = projectState.project.trees
        if viewModeManager.isForest && trees.count >= 2 {
            projectState.selectedNodeID = nil
            projectState.selectedTreeID = trees.first?.id
        }

        // Tear down and rebuild so the graph is ready for a clean start.
        syncTreeToEngine()

        // Rapid stop→play: if play was pressed before this handler ran,
        // the rebuild killed the sequencers that startPlayback() started.
        // Restart them on the fresh graph.
        if transportState.isPlaying {
            AudioEngine.shared.startAllSequencers(bpm: transportState.bpm)
        }
    }

    /// Called when view mode changes (forest ↔ focus ↔ meadow).
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
        } else if !viewModeManager.isForest && !viewModeManager.isMeadow {
            forestPlayback.activeTreeID = nil
            forestPlayback.nextTreeID = nil
            forestPlayback.timeline = nil
            AudioEngine.shared.clearStagedTree()
            // Reset region end so active sequencers don't auto-stop at the
            // old forest boundary. Without this, switching to Focus near a
            // region boundary kills playback permanently.
            AudioEngine.shared.setActiveRegionEnd(Int64.max)
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

        // Use current clock position as base — timeline may be (re)started
        // mid-playback after an unlock or view mode change.
        let baseSample = AudioEngine.shared.graph.clockSamplePosition.pointee

        // Region 1: current tree — let it play one more full cycle from now.
        // Only set the region END so running sequencers aren't disrupted.
        let cycle1 = forestPlayback.computeCycleLength(tree: activeTree)
        let len1 = Int64(cycle1 * 60.0 * sampleRate / bpm)
        let treeStart = AudioEngine.shared.graph.treeStartClockSample
        let elapsed = max(0, baseSample - treeStart)
        let positionInCycle = len1 > 0 ? elapsed % len1 : 0
        let remaining = positionInCycle == 0 ? len1 : (len1 - positionInCycle)
        let regionEnd = baseSample + remaining
        timeline.appendRegion(TimelineRegion(
            treeID: activeTree.id,
            startSample: baseSample, endSample: regionEnd,
            lengthInBeats: cycle1
        ))

        // Only constrain the end — don't touch the start so playing sequencers
        // keep running uninterrupted.
        AudioEngine.shared.setActiveRegionEnd(regionEnd)

        // Region 2: next tree (pre-stage + arm)
        forestPlayback.computeNextTree(trees: trees)
        if let nextID = forestPlayback.nextTreeID,
           let nextTree = trees.first(where: { $0.id == nextID }) {
            let cycle2 = forestPlayback.computeCycleLength(tree: nextTree)
            let len2 = Int64(cycle2 * 60.0 * sampleRate / bpm)
            timeline.appendRegion(TimelineRegion(
                treeID: nextTree.id,
                startSample: regionEnd, endSample: regionEnd + len2,
                lengthInBeats: cycle2
            ))
            AudioEngine.shared.stageNextTree(nextTree, bpm: bpm, muteGraph: false) {
                AudioEngine.shared.armStagedUnits(regionStart: regionEnd, regionEnd: regionEnd + len2, bpm: bpm)
            }
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

        // Note: Do NOT re-sync master bus, node FX, or modulation here.
        // Per-node FX chains are already configured during stageNextTree() → configureNodePatchRecursive().
        // Master bus and modulation are project-level state that persists across tree transitions.
        // Rebuilding the master FX chain here would destroy accumulated reverb/delay state and cause clicks.

        // 3. Update UI state
        forestPlayback.activeTreeID = newTreeID
        projectState.selectedTreeID = newTreeID
        forestPlayback.computeNextTree(trees: projectState.project.trees)

        // 4. Prune old timeline regions
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
        // Defer state mutations out of view body to avoid "Publishing changes from
        // within view updates" warnings.
        if let currentRegion = timeline.regionForSample(currentSample),
           currentRegion.treeID != lastDetectedTreeID {
            let oldTreeID = lastDetectedTreeID
            let newTreeID = currentRegion.treeID
            DispatchQueue.main.async {
                lastDetectedTreeID = newTreeID
                hasStaged = false
                onRegionTransition(newTreeID, oldTreeID)
            }
        }

        // 2. Pre-stage next tree if approaching end of current region (2 sec ahead)
        if !hasStaged {
            let margin = Int64(2.0 * AudioEngine.shared.sampleRate)
            if let currentRegion = timeline.regionForSample(currentSample) {
                let endOfRegion = currentRegion.endSample
                if currentSample > endOfRegion - margin {
                    stageNextRegion(afterBoundary: endOfRegion)
                    DispatchQueue.main.async {
                        hasStaged = true
                    }
                }
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

        AudioEngine.shared.stageNextTree(nextTree, bpm: bpm, muteGraph: false) {
            AudioEngine.shared.armStagedUnits(regionStart: boundary, regionEnd: boundary + regionLen, bpm: bpm)
        }
    }
}
