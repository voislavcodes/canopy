import AVFoundation
import os

/// Manages the audio subgraph for an entire NodeTree.
/// Maps each tree Node to a NodeAudioUnit, connecting them all to the engine's main mixer.
final class TreeAudioGraph {
    private(set) var units: [UUID: NodeAudioUnit] = [:]
    private let logger = Logger(subsystem: "com.canopy", category: "TreeAudioGraph")

    // MARK: - Unified Tree Clock
    // One Int64 sample counter for the entire tree. Source nodes READ it,
    // MasterBusAU ADVANCES it — render order guarantees no races.
    let clockSamplePosition: UnsafeMutablePointer<Int64>
    let clockIsRunning: UnsafeMutablePointer<Bool>

    init() {
        clockSamplePosition = .allocate(capacity: 1)
        clockSamplePosition.initialize(to: 0)
        clockIsRunning = .allocate(capacity: 1)
        clockIsRunning.initialize(to: false)
    }

    deinit {
        clockSamplePosition.deinitialize(count: 1)
        clockSamplePosition.deallocate()
        clockIsRunning.deinitialize(count: 1)
        clockIsRunning.deallocate()
    }

    // MARK: - Full Graph Build/Teardown

    /// Build the full audio graph from a tree. Walks all nodes recursively,
    /// creates a NodeAudioUnit for each, and connects to the engine.
    func buildGraph(from tree: NodeTree, engine: AVAudioEngine, sampleRate: Double) {
        teardownGraph(engine: engine)
        buildNodeRecursive(tree.rootNode, engine: engine, sampleRate: sampleRate)
        logger.info("Built graph with \(self.units.count) node(s)")
    }

    /// Disconnect and detach all units from the engine.
    func teardownGraph(engine: AVAudioEngine) {
        for (_, unit) in units {
            engine.disconnectNodeOutput(unit.sourceNode)
            engine.detach(unit.sourceNode)
        }
        units.removeAll()
    }

    // MARK: - Incremental Add/Remove

    /// Attach a single new node to the live graph without touching existing nodes.
    func addUnit(for node: Node, engine: AVAudioEngine, sampleRate: Double) {
        guard units[node.id] == nil else { return }
        let isDrum: Bool
        if case .drumKit = node.patch.soundType { isDrum = true } else { isDrum = false }
        let isWest: Bool
        if case .westCoast = node.patch.soundType { isWest = true } else { isWest = false }
        let isFlow: Bool
        if case .flow = node.patch.soundType { isFlow = true } else { isFlow = false }
        let isTide: Bool
        if case .tide = node.patch.soundType { isTide = true } else { isTide = false }
        let unit = NodeAudioUnit(nodeID: node.id, sampleRate: sampleRate, isDrumKit: isDrum, isWestCoast: isWest, isFlow: isFlow, isTide: isTide,
                                 clockSamplePosition: clockSamplePosition, clockIsRunning: clockIsRunning)
        engine.attach(unit.sourceNode)
        // Connect directly to main mixer — same pattern as Phase 2.
        // AVAudioSourceNode uses the engine's native format when no format is specified.
        let mainMixer = engine.mainMixerNode
        engine.connect(unit.sourceNode, to: mainMixer, format: mainMixer.outputFormat(forBus: 0))
        units[node.id] = unit
        logger.info("Added audio unit for node \(node.id)")
    }

    /// Detach a single node from the live graph.
    func removeUnit(for nodeID: UUID, engine: AVAudioEngine) {
        guard let unit = units[nodeID] else { return }
        unit.allNotesOff()
        engine.disconnectNodeOutput(unit.sourceNode)
        engine.detach(unit.sourceNode)
        units.removeValue(forKey: nodeID)
        logger.info("Removed audio unit for node \(nodeID)")
    }

    // MARK: - Bulk Configuration

    /// Configure patches for all nodes from the tree data.
    func configureAllPatches(from tree: NodeTree) {
        configureNodePatchRecursive(tree.rootNode)
    }

    /// Load sequences for all nodes from the tree data.
    func loadAllSequences(from tree: NodeTree) {
        loadNodeSequenceRecursive(tree.rootNode)
    }

    // MARK: - Transport

    /// Start all sequencers simultaneously at the given BPM.
    func startAll(bpm: Double) {
        clockSamplePosition.pointee = 0
        clockIsRunning.pointee = true
        for (_, unit) in units {
            unit.startSequencer(bpm: bpm)
        }
    }

    /// Stop all sequencers and silence all notes.
    func stopAll() {
        clockIsRunning.pointee = false
        for (_, unit) in units {
            unit.stopSequencer()
        }
    }

    /// Update BPM on all running sequencers.
    func setAllBPM(_ bpm: Double) {
        for (_, unit) in units {
            unit.setSequencerBPM(bpm)
        }
    }

    // MARK: - Accessors

    func unit(for nodeID: UUID) -> NodeAudioUnit? {
        units[nodeID]
    }

    // MARK: - Private Helpers

    private func buildNodeRecursive(_ node: Node, engine: AVAudioEngine, sampleRate: Double) {
        addUnit(for: node, engine: engine, sampleRate: sampleRate)
        for child in node.children {
            buildNodeRecursive(child, engine: engine, sampleRate: sampleRate)
        }
    }

    private func configureNodePatchRecursive(_ node: Node) {
        guard let unit = units[node.id] else { return }
        switch node.patch.soundType {
        case .oscillator(let config):
            let waveformIndex = waveformToIndex(config.waveform)
            unit.configurePatch(
                waveform: waveformIndex, detune: config.detune,
                attack: node.patch.envelope.attack, decay: node.patch.envelope.decay,
                sustain: node.patch.envelope.sustain, release: node.patch.envelope.release,
                volume: node.patch.volume
            )
        case .drumKit(let kitConfig):
            // Configure each drum voice
            for (i, voiceConfig) in kitConfig.voices.enumerated() {
                unit.configureDrumVoice(index: i, config: voiceConfig)
            }
            // Set volume via setPatch (only volume field matters for drums)
            unit.configurePatch(waveform: 0, detune: 0,
                               attack: 0, decay: 0, sustain: 0, release: 0,
                               volume: node.patch.volume)
        case .westCoast(let config):
            unit.configureWestCoast(config)
        case .flow(let config):
            unit.configureFlow(config)
        case .tide(let config):
            unit.configureTide(config)
        default:
            break
        }
        unit.setPan(Float(node.patch.pan))
        let f = node.patch.filter
        unit.configureFilter(enabled: f.enabled, cutoff: f.cutoff, resonance: f.resonance)
        // Push per-node FX chain
        if !node.effects.isEmpty {
            let chain = EffectChain.build(from: node.effects)
            unit.setFXChain(chain)
        }
        for child in node.children {
            configureNodePatchRecursive(child)
        }
    }

    private func loadNodeSequenceRecursive(_ node: Node) {
        guard let unit = units[node.id] else { return }
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
        unit.loadSequence(
            events, lengthInBeats: seq.lengthInBeats,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )
        unit.setGlobalProbability(seq.globalProbability)

        // Send arp config if present (uses default 120 BPM; recalculated on transport start)
        if let arpConfig = seq.arpConfig {
            let sampleRate = AudioEngine.shared.sampleRate
            let bpm = 120.0
            let beatsPerSecond = bpm / 60.0
            let secondsPerStep = arpConfig.rate.beatsPerStep / beatsPerSecond
            let samplesPerStep = max(1, Int(secondsPerStep * sampleRate))
            unit.setArpConfig(active: true, samplesPerStep: samplesPerStep,
                              gateLength: arpConfig.gateLength, mode: arpConfig.mode)

            let pool = ArpNotePool.build(from: seq, config: arpConfig)
            unit.setArpPool(pitches: Array(pool.pitches.prefix(pool.count)),
                           velocities: Array(pool.velocities.prefix(pool.count)),
                           startBeats: Array(pool.startBeats.prefix(pool.count)),
                           endBeats: Array(pool.endBeats.prefix(pool.count)))
        }

        for child in node.children {
            loadNodeSequenceRecursive(child)
        }
    }

    private func waveformToIndex(_ wf: Waveform) -> Int {
        switch wf {
        case .sine: return 0
        case .triangle: return 1
        case .sawtooth: return 2
        case .square: return 3
        case .noise: return 4
        }
    }
}
