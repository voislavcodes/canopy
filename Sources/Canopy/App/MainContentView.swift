import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState
    @StateObject private var canvasState = CanvasState()

    /// Tracks the previously selected node so we can send allNotesOff on deselect.
    @State private var previousSelectedNodeID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(projectState: projectState, transportState: transportState)

            // Canvas fills all remaining space — bloom UI (including keyboard) lives inside it
            CanopyCanvasView(
                projectState: projectState,
                canvasState: canvasState,
                transportState: transportState
            )
        }
        .background(CanopyColors.canvasBackground)
        .onAppear {
            setupSpacebarHandler()
            syncTreeToEngine()
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            handleNodeSelectionChange()
        }
    }

    // MARK: - Audio Graph Sync

    /// Build full audio graph from the first tree. Used on initial load / project switch.
    func syncTreeToEngine() {
        guard let tree = projectState.project.trees.first else { return }
        AudioEngine.shared.buildGraph(from: tree)
        AudioEngine.shared.configureAllPatches(from: tree)
        AudioEngine.shared.loadAllSequences(from: tree)

        // Set focused node for beat polling — default to root if nothing selected
        if transportState.focusedNodeID == nil {
            transportState.focusedNodeID = tree.rootNode.id
        }
    }

    /// Add a single node to the live audio graph (incremental, no teardown).
    func addNodeToEngine(node: Node) {
        AudioEngine.shared.addNode(node)
        pushPatchToEngine(node.patch, nodeID: node.id)
        loadSequenceToEngine(node)
    }

    /// Remove a single node from the live audio graph.
    func removeNodeFromEngine(id: UUID) {
        AudioEngine.shared.removeNode(id)
    }

    // MARK: - Node Selection Change

    private func handleNodeSelectionChange() {
        // Send allNotesOff only to the PREVIOUSLY selected node (keyboard cleanup)
        if let prevID = previousSelectedNodeID {
            AudioEngine.shared.allNotesOff(nodeID: prevID)
        }

        if let node = projectState.selectedNode {
            // Push this node's patch for keyboard playing
            pushPatchToEngine(node.patch, nodeID: node.id)
            transportState.focusedNodeID = node.id
        }

        previousSelectedNodeID = projectState.selectedNodeID
    }

    private func pushPatchToEngine(_ patch: SoundPatch, nodeID: UUID) {
        if case .oscillator(let config) = patch.soundType {
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
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )
        AudioEngine.shared.setGlobalProbability(seq.globalProbability, nodeID: node.id)
    }

    // MARK: - Keyboard Shortcut

    private func setupSpacebarHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 && !isEditingTextField() {
                transportState.togglePlayback()
                return nil
            }
            return event
        }
    }

    private func isEditingTextField() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
