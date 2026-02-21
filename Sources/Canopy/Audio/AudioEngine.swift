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

    /// Master bus AU — inserted between mainMixerNode and outputNode.
    private(set) var masterBusAU: MasterBusAU?
    private var masterBusAVUnit: AVAudioUnit?

    private init() {}

    // MARK: - Engine Lifecycle

    /// Start the audio engine. Call once at app launch.
    func start() {
        guard !engine.isRunning else { return }

        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        self.sampleRate = hwFormat.sampleRate

        // Insert master bus AU synchronously before starting the engine.
        // attach/connect require the engine to be stopped.
        if masterBusAU == nil {
            insertMasterBus()
        }

        do {
            try engine.start()
            logger.info("Audio engine started at \(self.sampleRate) Hz")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Insert the MasterBusAU between mainMixerNode and outputNode.
    /// Must be called while the engine is NOT running.
    private func insertMasterBus() {
        MasterBusAU.register()

        let desc = MasterBusAU.masterBusDescription

        // Instantiate synchronously on a background queue to avoid potential
        // main-thread deadlock with the completion handler.
        var instantiatedUnit: AVAudioUnit?
        let semaphore = DispatchSemaphore(value: 0)

        // AVAudioUnit.instantiate callback fires on an arbitrary queue (not main),
        // so blocking the main thread with a semaphore is safe here.
        AVAudioUnit.instantiate(with: desc, options: .loadInProcess) { avUnit, error in
            if let error = error {
                Logger(subsystem: "com.canopy", category: "AudioEngine")
                    .error("Failed to instantiate MasterBusAU: \(error.localizedDescription)")
            }
            instantiatedUnit = avUnit
            semaphore.signal()
        }
        semaphore.wait()

        guard let avUnit = instantiatedUnit else {
            logger.error("MasterBusAU instantiation returned nil")
            return
        }

        engine.attach(avUnit)

        let mainMixer = engine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)

        // Disconnect default mainMixer → outputNode connection
        engine.disconnectNodeOutput(mainMixer)

        // Insert: mainMixer → masterBusAU → outputNode
        engine.connect(mainMixer, to: avUnit, format: format)
        engine.connect(avUnit, to: engine.outputNode, format: format)

        masterBusAVUnit = avUnit
        masterBusAU = avUnit.auAudioUnit as? MasterBusAU
        masterBusAU?.setClockPointers(samplePosition: graph.clockSamplePosition,
                                       isRunning: graph.clockIsRunning)
        logger.info("Master bus AU inserted into audio graph")
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

    /// Set arp config on a specific node's sequencer.
    func setArpConfig(active: Bool, samplesPerStep: Int, gateLength: Double, mode: ArpMode, nodeID: UUID) {
        graph.unit(for: nodeID)?.setArpConfig(active: active, samplesPerStep: samplesPerStep,
                                               gateLength: gateLength, mode: mode)
    }

    /// Set arp pool data on a specific node's sequencer.
    func setArpPool(pitches: [Int], velocities: [Double], startBeats: [Double], endBeats: [Double], nodeID: UUID) {
        graph.unit(for: nodeID)?.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)
    }

    /// Configure a single drum voice on a specific node.
    func configureDrumVoice(index: Int, config: DrumVoiceConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureDrumVoice(index: index, config: config)
    }

    /// Configure West Coast parameters on a specific node.
    func configureWestCoast(_ config: WestCoastConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureWestCoast(config)
    }

    /// Configure FLOW parameters on a specific node.
    func configureFlow(_ config: FlowConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureFlow(config)
    }

    /// Configure TIDE parameters on a specific node.
    func configureTide(_ config: TideConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureTide(config)
    }

    /// Configure SWARM parameters on a specific node.
    func configureSwarm(_ config: SwarmConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSwarm(config)
    }

    /// Configure all QUAKE voice parameters on a specific node.
    func configureQuake(_ config: QuakeConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureQuake(config)
    }

    /// Configure a single QUAKE voice slot on a specific node.
    func configureQuakeVoice(index: Int, mass: Double, surface: Double,
                              force: Double, sustain: Double, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureQuakeVoice(index: index, mass: mass, surface: surface,
                                                      force: force, sustain: sustain)
    }

    /// Configure ORBIT sequencer parameters on a specific node.
    func configureOrbit(_ config: OrbitConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureOrbit(config)
    }

    /// Toggle orbit vs standard sequencer on a specific node.
    func setUseOrbitSequencer(_ useOrbit: Bool, nodeID: UUID) {
        graph.unit(for: nodeID)?.setUseOrbitSequencer(useOrbit)
    }

    // MARK: - Imprint

    /// Push FLOW imprint harmonic amplitudes to a specific node.
    func configureFlowImprint(_ amplitudes: [Float]?, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureFlowImprint(amplitudes)
    }

    /// Push TIDE imprint frames to a specific node.
    func configureTideImprint(_ frames: [TideFrame]?, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureTideImprint(frames)
    }

    /// Push SWARM imprint positions and amplitudes to a specific node.
    func configureSwarmImprint(positions: [Float]?, amplitudes: [Float]?, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSwarmImprint(positions: positions, amplitudes: amplitudes)
    }

    /// Update the filter on a specific node.
    func configureFilter(enabled: Bool, cutoff: Double, resonance: Double, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureFilter(enabled: enabled, cutoff: cutoff, resonance: resonance)
    }

    // MARK: - FX Chain

    /// Set the effect chain on a specific node.
    func configureNodeFXChain(effects: [Effect], nodeID: UUID) {
        let chain = EffectChain.build(from: effects)
        graph.unit(for: nodeID)?.setFXChain(chain)
    }

    /// Set the master bus effect chain.
    func configureMasterFXChain(effects: [Effect]) {
        let chain = EffectChain.build(from: effects)
        masterBusAU?.swapFXChain(chain)
    }

    /// Set the master bus volume.
    func configureMasterVolume(_ volume: Float) {
        masterBusAU?.masterVolume = volume
    }

    /// Configure Shore limiter.
    func configureShore(enabled: Bool, ceiling: Double) {
        masterBusAU?.shoreEnabled = enabled
        // Convert dBFS to linear
        let linear = Float(pow(10.0, ceiling / 20.0))
        masterBusAU?.shoreCeiling = min(1.0, linear)
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

    // MARK: - LFO Modulation

    /// Configure a single LFO slot on a specific node's audio unit.
    func configureLFOSlot(_ slotIndex: Int, enabled: Bool, waveform: Int,
                           rateHz: Double, initialPhase: Double, depth: Double,
                           parameter: Int, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureLFOSlot(
            slotIndex, enabled: enabled, waveform: waveform,
            rateHz: rateHz, initialPhase: initialPhase, depth: depth, parameter: parameter
        )
    }

    /// Set the number of active LFO slots on a specific node.
    func setLFOSlotCount(_ count: Int, nodeID: UUID) {
        graph.unit(for: nodeID)?.setLFOSlotCount(count)
    }

    /// Push all LFO modulation routings to the audio graph.
    /// Groups routings by node, resolves LFO definitions, and configures slots.
    /// Max 4 slots per node (extra routings are ignored).
    func syncModulationRoutings(lfos: [LFODefinition], routings: [ModulationRouting]) {
        // Build LFO lookup
        var lfoMap: [UUID: LFODefinition] = [:]
        for lfo in lfos {
            lfoMap[lfo.id] = lfo
        }

        // Group routings by node
        var routingsByNode: [UUID: [ModulationRouting]] = [:]
        for routing in routings {
            routingsByNode[routing.nodeID, default: []].append(routing)
        }

        // Track which nodes have routings so we can clear others
        var nodesWithRoutings: Set<UUID> = []

        for (nodeID, nodeRoutings) in routingsByNode {
            nodesWithRoutings.insert(nodeID)
            let capped = Array(nodeRoutings.prefix(LFOBank.maxSlots))

            for (slotIndex, routing) in capped.enumerated() {
                if let lfo = lfoMap[routing.lfoID] {
                    configureLFOSlot(
                        slotIndex,
                        enabled: lfo.enabled,
                        waveform: lfoWaveformToInt(lfo.waveform),
                        rateHz: lfo.rateHz,
                        initialPhase: lfo.phase,
                        depth: routing.depth,
                        parameter: modulationParameterToInt(routing.parameter),
                        nodeID: nodeID
                    )
                }
            }
            setLFOSlotCount(capped.count, nodeID: nodeID)
        }

        // Clear LFO slots on nodes that no longer have routings
        for (nodeID, _) in graph.units {
            if !nodesWithRoutings.contains(nodeID) {
                setLFOSlotCount(0, nodeID: nodeID)
            }
        }
    }

    private func lfoWaveformToInt(_ wf: LFOWaveform) -> Int {
        switch wf {
        case .sine: return 0
        case .triangle: return 1
        case .sawtooth: return 2
        case .square: return 3
        case .sampleAndHold: return 4
        }
    }

    private func modulationParameterToInt(_ param: ModulationParameter) -> Int {
        switch param {
        case .volume: return 0
        case .pan: return 1
        case .filterCutoff: return 2
        case .filterResonance: return 3
        }
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
