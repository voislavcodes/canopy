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

    /// Fade a node to silence then remove it (click-free).
    func muteAndRemoveNode(_ nodeID: UUID) {
        graph.muteAndRemoveUnit(for: nodeID, engine: engine)
    }

    /// Fade multiple nodes to silence in parallel then remove all (click-free).
    func muteAndRemoveNodes(_ nodeIDs: [UUID]) {
        graph.muteAndRemoveUnits(for: nodeIDs, engine: engine)
    }

    /// Tear down the entire audio graph with a fade-out (click-free).
    func teardownGraphWithFade() {
        graph.teardownGraphWithFade(engine: engine)
    }

    /// Crossfade swap: build new tree alongside old, start new, fade+remove old.
    /// Fallback path — use stageNextTree + activateStagedTree for zero-gap transitions.
    func crossfadeSwap(to tree: NodeTree, bpm: Double) {
        guard sampleRate > 0 else { return }
        graph.crossfadeSwap(to: tree, engine: engine, sampleRate: sampleRate, bpm: bpm)
    }

    // MARK: - Pre-staging

    /// Pre-build the next tree's graph while the current tree plays.
    /// Moves slow engine.attach/connect out of the transition path.
    /// The completion block runs on the main thread after staging finishes.
    ///
    /// - Parameter muteGraph: When true, briefly mutes the master bus to mask
    ///   any AVAudioEngine graph-mutation click. Set to false when staging during
    ///   a transition overlap to avoid disrupting the crossfade.
    func stageNextTree(_ tree: NodeTree, bpm: Double, currentCycleLengthInBeats: Double = 0,
                       muteGraph: Bool = true, completion: (() -> Void)? = nil) {
        guard sampleRate > 0 else { return }
        if muteGraph {
            masterBusAU?.beginGraphMute()
        }
        let sr = sampleRate
        let eng = engine
        let g = graph
        // Delay graph mutation so the audio thread has time to fade out
        // (when muting) or to avoid blocking the main thread.
        let delay = muteGraph ? 0.035 : 0.0
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                g.stageNextTree(tree, engine: eng, sampleRate: sr, bpm: bpm,
                                currentCycleLengthInBeats: currentCycleLengthInBeats)
                completion?()
            }
        } else {
            g.stageNextTree(tree, engine: eng, sampleRate: sr, bpm: bpm,
                            currentCycleLengthInBeats: currentCycleLengthInBeats)
            completion?()
        }
    }

    /// Activate the pre-staged tree. Lightweight — just start commands + fade old.
    func activateStagedTree(bpm: Double) {
        graph.activateStagedTree(engine: engine, bpm: bpm)
    }

    /// Remove pre-staged units without activating them.
    func clearStagedTree() {
        graph.clearStagedTree(engine: engine)
    }

    /// The tree ID currently pre-staged for the next transition, if any.
    var stagedTreeID: UUID? {
        graph.stagedTreeID
    }

    // MARK: - Forest Timeline

    /// Set region bounds on active (non-staged) units.
    func setActiveRegionBounds(start: Int64, end: Int64) {
        graph.setActiveRegionBounds(start: start, end: end)
    }

    /// Change only the region end on active units (lock-to-tree: no beat discontinuity).
    func setActiveRegionEnd(_ end: Int64) {
        graph.setActiveRegionEnd(end)
    }

    /// Arm staged units for auto-start at the given region bounds.
    func armStagedUnits(regionStart: Int64, regionEnd: Int64, bpm: Double) {
        graph.armStagedUnits(regionStart: regionStart, regionEnd: regionEnd, bpm: bpm)
    }

    /// Promote staged units to active tracking (timeline mode).
    func promoteStagedToActive() {
        graph.promoteStagedToActive()
    }

    /// Drain units for the given node IDs (schedule cleanup after release tails).
    func drainUnits(for nodeIDs: [UUID]) {
        graph.drainUnits(for: nodeIDs, engine: engine)
    }

    /// Configure the full sound patch for a single node (all sound types, pan, filter, FX).
    func configureSingleNodePatch(_ node: Node) {
        graph.configureSingleNodePatch(node)
    }

    /// Load the note sequence for a single node (notes, arp, orbit, spore seq).
    func loadSingleNodeSequence(_ node: Node, bpm: Double) {
        graph.loadSingleNodeSequence(node, bpm: bpm)
    }

    /// Start a single node's sequencer without resetting the global clock.
    func startNodeSequencer(nodeID: UUID, bpm: Double) {
        graph.startUnit(for: nodeID, bpm: bpm)
    }

    /// Whether the unified tree clock is currently running.
    var isClockRunning: Bool {
        graph.clockIsRunning.pointee
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
                      scaleRootSemitone: Int = 0, scaleIntervals: [Int] = []) {
        graph.unit(for: nodeID)?.loadSequence(
            events, lengthInBeats: lengthInBeats,
            direction: direction,
            mutationAmount: mutationAmount, mutationRange: mutationRange,
            scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)
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

    /// Set muted state on a specific node (smoothed to avoid clicks).
    func setNodeMuted(_ muted: Bool, nodeID: UUID) {
        graph.unit(for: nodeID)?.setMuted(muted)
    }

    /// Set tree-level volume multiplier on specific nodes.
    func setTreeVolume(_ volume: Float, nodeIDs: [UUID]) {
        for nodeID in nodeIDs {
            graph.unit(for: nodeID)?.setTreeVolume(volume)
        }
    }

    /// Set tree-level pan offset on specific nodes.
    func setTreePan(_ pan: Float, nodeIDs: [UUID]) {
        for nodeID in nodeIDs {
            graph.unit(for: nodeID)?.setTreePan(pan)
        }
    }

    /// Poll level meters for a specific node.
    func nodeMeterLevels(nodeID: UUID) -> (rmsL: Float, rmsR: Float, peakL: Float, peakR: Float) {
        guard let unit = graph.unit(for: nodeID) else { return (0, 0, 0, 0) }
        return (unit.meterRmsL, unit.meterRmsR, unit.meterPeakL, unit.meterPeakR)
    }

    /// Poll master bus level meters.
    func masterMeterLevels() -> (rmsL: Float, rmsR: Float, peakL: Float, peakR: Float) {
        guard let master = masterBusAU else { return (0, 0, 0, 0) }
        return (master.meterRmsL, master.meterRmsR, master.meterPeakL, master.meterPeakR)
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



    /// Configure SPORE parameters on a specific node.
    func configureSpore(_ config: SporeConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSpore(config)
    }

    /// Configure FUSE parameters on a specific node.
    func configureFuse(_ config: FuseConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureFuse(config)
    }

    /// Configure SCHMYNTH parameters on a specific node.
    func configureSchmynth(_ config: SchmynthConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSchmynth(config)
    }

    /// Configure a single VOLT drum kit slot on a specific node.
    func configureVoltSlot(index: Int, _ config: VoltConfig, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureVoltSlot(index: index, config)
    }

    /// Push SPORE imprint harmonic amplitudes to a specific node.
    func configureSporeImprint(_ amplitudes: [Float]?, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSporeImprint(amplitudes)
    }

    /// Configure SPORE sequencer parameters on a specific node.
    func configureSporeSeq(_ config: SporeSeqConfig, key: MusicalKey, nodeID: UUID) {
        graph.unit(for: nodeID)?.configureSporeSeq(config, key: key)
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

    /// Set BPM on the master bus (for tempo-synced effects like DRIFT).
    func setMasterBusBPM(_ bpm: Double) {
        masterBusAU?.masterBPM = bpm
    }

    /// Set BPM on a specific node's FX chain via its sequencer command path.
    /// Note: BPM is normally propagated via sequencerStart/sequencerSetBPM commands,
    /// but this provides an explicit path for project load scenarios.
    func setNodeFXChainBPM(_ bpm: Double, nodeID: UUID) {
        // The FX chain gets BPM via the sequencerSetBPM command handler in the render block.
        // On project load, we issue a BPM set so the chain has the right value before playback.
        graph.unit(for: nodeID)?.commandBuffer.push(.sequencerSetBPM(bpm))
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
    func startAllSequencers(bpm: Double, resetClock: Bool = true) {
        graph.startAll(bpm: bpm, resetClock: resetClock)
    }

    /// Stop all sequencers and silence all notes (instant — may click).
    func stopAllSequencers() {
        graph.stopAll()
    }

    /// Fade all units to silence then stop. Click-free.
    func stopAllSequencersWithFade() {
        graph.stopAllWithFade()
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
    func loadAllSequences(from tree: NodeTree, bpm: Double = 120.0) {
        graph.loadAllSequences(from: tree, bpm: bpm)
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
