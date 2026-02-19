import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @StateObject private var canvasState = CanvasState()
    @StateObject private var bloomState = BloomState()

    /// Tracks the previously selected node so we can send allNotesOff on deselect.
    @State private var previousSelectedNodeID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(projectState: projectState, transportState: transportState)

            // Canvas fills all remaining space — bloom UI (including keyboard) lives inside it
            CanopyCanvasView(
                projectState: projectState,
                canvasState: canvasState,
                bloomState: bloomState,
                transportState: transportState
            )

            ModulatorStripView(projectState: projectState)
        }
        .background(CanopyColors.canvasBackground)
        .onAppear {
            syncTreeToEngine()
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            handleNodeSelectionChange()
        }
        .onChange(of: transportState.isPlaying) { isPlaying in
            if !isPlaying {
                projectState.resetFreeRunningClock()
            }
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

        // Push LFO modulation routings to audio engine
        projectState.syncModulationToEngine()
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
        // Exit focus mode when switching nodes
        bloomState.focusedPanel = nil

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
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )
        AudioEngine.shared.setGlobalProbability(seq.globalProbability, nodeID: node.id)
    }

}
