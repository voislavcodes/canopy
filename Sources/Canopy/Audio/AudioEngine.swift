import AVFoundation
import os

/// Central audio engine singleton. Manages the AVAudioEngine and delegates
/// per-node audio to TreeAudioGraph.
///
/// Public API is called from the main thread. Each node's render callback
/// runs on the audio thread and is lock-free.
final class AudioEngine {
    static let shared = AudioEngine()

    private let logger = Logger(subsystem: "com.canopy", category: "AudioEngine")

    let engine = AVAudioEngine()
    let graph = TreeAudioGraph()

    private(set) var sampleRate: Double = 0

    private init() {}

    // MARK: - Engine Lifecycle

    /// Start the audio engine. Call once at app launch.
    func start() {
        guard !engine.isRunning else { return }

        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        self.sampleRate = hwFormat.sampleRate

        do {
            try engine.start()
            logger.info("Audio engine started at \(self.sampleRate) Hz")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Stop the audio engine.
    func stop() {
        engine.stop()
        logger.info("Audio engine stopped")
    }

    // MARK: - Graph Management

    /// Build the full audio graph from a tree. Used on initial load / project switch.
    func buildGraph(from tree: NodeTree) {
        guard sampleRate > 0 else { return }
        graph.buildGraph(from: tree, engine: engine, sampleRate: sampleRate)
    }

    /// Tear down the entire audio graph.
    func teardownGraph() {
        graph.teardownGraph(engine: engine)
    }

    /// Add a single node to the live graph (glitch-free during playback).
    func addNode(_ node: Node) {
        guard sampleRate > 0 else { return }
        graph.addUnit(for: node, engine: engine, sampleRate: sampleRate)
    }

    /// Remove a single node from the live graph.
    func removeNode(_ nodeID: UUID) {
        graph.removeUnit(for: nodeID, engine: engine)
    }

    // MARK: - Per-Node Commands (main thread)

    /// Send a note-on command to a specific node.
    func noteOn(pitch: Int, velocity: Double = 0.8, nodeID: UUID) {
        graph.unit(for: nodeID)?.noteOn(pitch: pitch, velocity: velocity)
    }

    /// Send a note-off command to a specific node.
    func noteOff(pitch: Int, nodeID: UUID) {
        graph.unit(for: nodeID)?.noteOff(pitch: pitch)
    }

    /// Release all sounding notes on a specific node.
    func allNotesOff(nodeID: UUID) {
        graph.unit(for: nodeID)?.allNotesOff()
    }

    /// Update the sound patch on a specific node.
    func configurePatch(waveform: Int, detune: Double, attack: Double, decay: Double, sustain: Double, release: Double, volume: Double, nodeID: UUID) {
        graph.unit(for: nodeID)?.configurePatch(
            waveform: waveform, detune: detune,
            attack: attack, decay: decay, sustain: sustain, release: release,
            volume: volume
        )
    }

    /// Load a note sequence for a specific node.
    func loadSequence(_ events: [SequencerEvent], lengthInBeats: Double, nodeID: UUID,
                      direction: PlaybackDirection = .forward,
                      mutationAmount: Double = 0, mutationRange: Int = 0,
                      scaleRootSemitone: Int = 0, scaleIntervals: [Int] = [],
                      accumulatorConfig: AccumulatorConfig? = nil) {
        graph.unit(for: nodeID)?.loadSequence(
            events, lengthInBeats: lengthInBeats,
            direction: direction,
            mutationAmount: mutationAmount, mutationRange: mutationRange,
            scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals,
            accumulatorConfig: accumulatorConfig)
    }

    /// Set global probability on a specific node's sequencer.
    func setGlobalProbability(_ probability: Double, nodeID: UUID) {
        graph.unit(for: nodeID)?.setGlobalProbability(probability)
    }

    /// Set mutation parameters on a specific node's sequencer.
    func setMutation(amount: Double, range: Int, rootSemitone: Int, intervals: [Int], nodeID: UUID) {
        graph.unit(for: nodeID)?.setMutation(amount: amount, range: range, rootSemitone: rootSemitone, intervals: intervals)
    }

    /// Reset mutation on a specific node's sequencer.
    func resetMutation(nodeID: UUID) {
        graph.unit(for: nodeID)?.resetMutation()
    }

    /// Freeze mutation on a specific node's sequencer.
    func freezeMutation(nodeID: UUID) {
        graph.unit(for: nodeID)?.freezeMutation()
    }

    /// Set volume on a specific node's mixer.
    func setNodeVolume(_ volume: Float, nodeID: UUID) {
        graph.unit(for: nodeID)?.setVolume(volume)
    }

    /// Set pan on a specific node's mixer.
    func setNodePan(_ pan: Float, nodeID: UUID) {
        graph.unit(for: nodeID)?.setPan(pan)
    }

    // MARK: - Transport (all nodes)

    /// Start all sequencers simultaneously at the given BPM.
    func startAllSequencers(bpm: Double) {
        graph.startAll(bpm: bpm)
    }

    /// Stop all sequencers and silence all notes.
    func stopAllSequencers() {
        graph.stopAll()
    }

    /// Update BPM on all running sequencers.
    func setAllSequencersBPM(_ bpm: Double) {
        graph.setAllBPM(bpm)
    }

    /// Configure patches for all nodes from tree data.
    func configureAllPatches(from tree: NodeTree) {
        graph.configureAllPatches(from: tree)
    }

    /// Load sequences for all nodes from tree data.
    func loadAllSequences(from tree: NodeTree) {
        graph.loadAllSequences(from: tree)
    }

    // MARK: - Polling

    /// Get the current beat position for a specific node.
    func currentBeat(for nodeID: UUID) -> Double {
        graph.unit(for: nodeID)?.currentBeat ?? 0
    }

    /// Check if a specific node's sequencer is playing.
    func isPlaying(for nodeID: UUID) -> Bool {
        graph.unit(for: nodeID)?.isPlaying ?? false
    }
}
