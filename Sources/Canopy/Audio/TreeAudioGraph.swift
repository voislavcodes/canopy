import AVFoundation
import os

/// Manages the audio subgraph for an entire NodeTree.
/// Maps each tree Node to a NodeAudioUnit, connecting them all to the engine's main mixer.
final class TreeAudioGraph {
    private(set) var units: [UUID: NodeAudioUnit] = [:]
    private let logger = Logger(subsystem: "com.canopy", category: "TreeAudioGraph")

    /// IDs of pre-staged units (attached, configured, loaded — but sequencer NOT started).
    /// These live in `units` alongside active units but produce silence until activated.
    private(set) var stagedIDs: Set<UUID> = []

    /// The tree ID that has been pre-staged for the next transition, if any.
    private(set) var stagedTreeID: UUID?

    // MARK: - Unified Tree Clock
    // One Int64 sample counter for the entire tree. Source nodes READ it,
    // MasterBusAU ADVANCES it — render order guarantees no races.
    let clockSamplePosition: UnsafeMutablePointer<Int64>
    let clockIsRunning: UnsafeMutablePointer<Bool>

    /// The global clock sample at which the current tree started playing.
    /// Used to compute relative position for forest advance polling.
    private(set) var treeStartClockSample: Int64 = 0

    /// Samples elapsed since the current tree started (monotonic-safe).
    var clockSamplesSinceTreeStart: Int64 {
        clockSamplePosition.pointee - treeStartClockSample
    }

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

    /// Crossfade swap: build new tree's graph alongside old one, activate new
    /// at current sample, deactivate old immediately.
    /// Fallback path when no pre-staged tree is available.
    func crossfadeSwap(to tree: NodeTree, engine: AVAudioEngine, sampleRate: Double, bpm: Double) {
        // 1. Capture old unit IDs
        let oldIDs = Array(units.keys)

        // 2. Build new units alongside old ones (new tree has fresh UUIDs).
        //    Old units keep playing at full volume during this.
        buildNodeRecursive(tree.rootNode, engine: engine, sampleRate: sampleRate)
        logger.info("Crossfade swap: built \(self.units.count - oldIDs.count) new unit(s)")

        // 3. Configure patches and load sequences for new nodes
        configureNodePatchRecursive(tree.rootNode)
        loadNodeSequenceRecursive(tree.rootNode, bpm: bpm)

        // 4. Set immediate transition timestamps
        let newIDs = Set(units.keys).subtracting(oldIDs)
        let currentClock = clockSamplePosition.pointee
        treeStartClockSample = currentClock
        clockIsRunning.pointee = true

        // Deactivate old units at current sample
        for id in oldIDs {
            units[id]?.setDeactivateAtSample(currentClock)
        }

        // Activate new units at current sample
        for id in newIDs {
            units[id]?.setClockStartOffset(currentClock)
            units[id]?.setActivation(atSample: currentClock, bpm: bpm)
        }

        // 5. Remove old units from tracking, keep connected until fade completes
        let drainingUnits = oldIDs.compactMap { units.removeValue(forKey: $0) }

        // 6. Deferred cleanup after fade completes
        scheduleDrainingCleanup(drainingUnits, engine: engine)
    }

    /// Fade all units to silence, then tear down. Click-free.
    func teardownGraphWithFade(engine: AVAudioEngine) {
        for (_, unit) in units {
            unit.requestFadeOut()
        }
        // Multi-buffer fade takes ~185ms. Poll with generous timeout.
        for _ in 0..<60 {
            if units.values.allSatisfy({ $0.isFadedOut }) { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        for (_, unit) in units {
            engine.disconnectNodeOutput(unit.sourceNode)
            engine.detach(unit.sourceNode)
        }
        units.removeAll()
    }

    // MARK: - Pre-staging for Zero-Gap Transitions

    /// Pre-build the next tree's audio graph while the current tree is still playing.
    /// Units are attached, connected, configured, and loaded — but NOT started.
    /// They output silence (no active voices, sequencer dormant) until activated.
    /// This moves the slow engine.attach/connect work out of the transition path.
    func stageNextTree(_ tree: NodeTree, engine: AVAudioEngine, sampleRate: Double, bpm: Double,
                        currentCycleLengthInBeats: Double = 0) {
        clearStagedTree(engine: engine)

        let beforeIDs = Set(units.keys)

        // Build units (the slow part — engine.attach + engine.connect)
        buildNodeRecursive(tree.rootNode, engine: engine, sampleRate: sampleRate)

        // Configure patches and load sequences. These push commands to each unit's
        // ring buffer; the render callbacks drain them while outputting silence
        // (sequencer not started → no voices active → zeros).
        configureNodePatchRecursive(tree.rootNode)
        loadNodeSequenceRecursive(tree.rootNode, bpm: bpm)

        stagedIDs = Set(units.keys).subtracting(beforeIDs)
        stagedTreeID = tree.id

        // Set sample-precise dual timestamps: deactivate old units and activate new
        // units at the exact LCM boundary sample. The audio thread executes both at
        // the precise sample — main-thread latency is irrelevant.
        if currentCycleLengthInBeats > 0 && !beforeIDs.isEmpty && bpm > 0 {
            let samplesPerBeat = 60.0 * sampleRate / bpm
            let localSamplesElapsed = clockSamplePosition.pointee - treeStartClockSample
            let localBeatsElapsed = Double(localSamplesElapsed) / samplesPerBeat
            let currentCycleNum = max(0, Int(localBeatsElapsed / currentCycleLengthInBeats))
            let nextBoundaryBeats = Double(currentCycleNum + 1) * currentCycleLengthInBeats
            let stopSampleLocal = Int64(nextBoundaryBeats * samplesPerBeat)
            let transitionGlobalSample = treeStartClockSample + stopSampleLocal

            // Old units: deactivate at boundary (global time)
            for id in beforeIDs {
                units[id]?.setDeactivateAtSample(transitionGlobalSample)
            }

            // New units: activate at boundary, clock offset so baseSample=0 at transition
            for id in stagedIDs {
                units[id]?.setClockStartOffset(transitionGlobalSample)
                units[id]?.setActivation(atSample: transitionGlobalSample, bpm: bpm)
            }
        }

        logger.info("Staged \(self.stagedIDs.count) unit(s) for tree \(tree.id)")
    }

    /// Activate the pre-staged tree. Pure bookkeeping — no ring buffer commands.
    /// The audio thread already handles activation/deactivation via sample-precise
    /// timestamps set during stageNextTree(). This can be 0–500ms late with zero
    /// audible consequence.
    func activateStagedTree(engine: AVAudioEngine, bpm: Double) {
        guard !stagedIDs.isEmpty else { return }

        let oldIDs = Set(units.keys).subtracting(stagedIDs)

        // Update tree start for polling (use the offset from staged units)
        if let firstID = stagedIDs.first, let unit = units[firstID] {
            treeStartClockSample = unit.clockStartOffset
        }

        // Remove old units from tracking (transport/BPM ops won't touch them)
        // but keep them connected to engine until fade/release tails complete.
        let drainingUnits = oldIDs.compactMap { units.removeValue(forKey: $0) }

        // Safety net: if the audio thread hasn't deactivated yet (e.g. the poller
        // ran before the render callback processed the deactivation timestamp),
        // explicitly stop the sequencer and request fade-out now. This is idempotent
        // if the audio thread already handled it.
        for unit in drainingUnits {
            unit.stopSequencerSoft()
            unit.requestFadeOut()
        }

        // Clear staging state (staged units are now the active ones)
        stagedIDs.removeAll()
        stagedTreeID = nil

        // Deferred cleanup: wait for release tails then detach
        scheduleDrainingCleanup(drainingUnits, engine: engine)
    }

    /// Remove pre-staged units without activating them.
    func clearStagedTree(engine: AVAudioEngine) {
        for id in stagedIDs {
            if let unit = units[id] {
                engine.disconnectNodeOutput(unit.sourceNode)
                engine.detach(unit.sourceNode)
            }
            units.removeValue(forKey: id)
        }
        stagedIDs.removeAll()
        stagedTreeID = nil

        // Clear any pending deactivation on current units
        for (_, unit) in units {
            unit.setDeactivateAtSample(0)
        }
    }

    /// Schedule deferred cleanup for old units whose voices are ringing out.
    /// Units stay connected to the engine producing release tail audio.
    /// After a generous timeout, apply an anti-click fade and detach.
    private func scheduleDrainingCleanup(_ drainingUnits: [NodeAudioUnit], engine: AVAudioEngine) {
        guard !drainingUnits.isEmpty else { return }
        // Fade was requested either by the audio thread (deactivation timestamp)
        // or by the safety net in activateStagedTree(). Multi-buffer fade takes ~185ms.
        // Wait 300ms then poll for completion before detaching.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            // Wait for multi-buffer fade to complete
            for _ in 0..<50 {
                if drainingUnits.allSatisfy({ $0.isFadedOut }) { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            // Disconnect and detach (safe from any non-audio thread)
            for unit in drainingUnits {
                engine.disconnectNodeOutput(unit.sourceNode)
                engine.detach(unit.sourceNode)
            }
        }
    }

    // MARK: - Incremental Add/Remove

    /// Attach a single new node to the live graph without touching existing nodes.
    func addUnit(for node: Node, engine: AVAudioEngine, sampleRate: Double) {
        guard units[node.id] == nil else { return }
        // Warn on unimplemented sound types — they fall through to oscillator
        if case .sampler = node.patch.soundType {
            logger.warning("Sampler sound type is not yet implemented — node \(node.id) will use oscillator fallback")
        } else if case .auv3 = node.patch.soundType {
            logger.warning("AUv3 sound type is not yet implemented — node \(node.id) will use oscillator fallback")
        }
        let isDrum: Bool
        if case .drumKit = node.patch.soundType { isDrum = true } else { isDrum = false }
        let isWest: Bool
        if case .westCoast = node.patch.soundType { isWest = true } else { isWest = false }
        let isFlow: Bool
        if case .flow = node.patch.soundType { isFlow = true } else { isFlow = false }
        let isTide: Bool
        if case .tide = node.patch.soundType { isTide = true } else { isTide = false }
        let isSwarm: Bool
        if case .swarm = node.patch.soundType { isSwarm = true } else { isSwarm = false }
        let isQuake: Bool
        if case .quake = node.patch.soundType { isQuake = true } else { isQuake = false }
        let isSpore: Bool
        if case .spore = node.patch.soundType { isSpore = true } else { isSpore = false }
        let isFuse: Bool
        if case .fuse = node.patch.soundType { isFuse = true } else { isFuse = false }
        let isVolt: Bool
        if case .volt = node.patch.soundType { isVolt = true } else { isVolt = false }
        let isSchmynth: Bool
        if case .schmynth = node.patch.soundType { isSchmynth = true } else { isSchmynth = false }
        let unit = NodeAudioUnit(nodeID: node.id, sampleRate: sampleRate, isDrumKit: isDrum, isWestCoast: isWest, isFlow: isFlow, isTide: isTide, isSwarm: isSwarm, isQuake: isQuake, isSpore: isSpore, isFuse: isFuse, isVolt: isVolt, isSchmynth: isSchmynth,
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

    /// Fade multiple nodes to silence in parallel, then detach all. Click-free.
    func muteAndRemoveUnits(for nodeIDs: [UUID], engine: AVAudioEngine) {
        for id in nodeIDs {
            units[id]?.requestFadeOut()
        }
        for _ in 0..<30 {
            if nodeIDs.allSatisfy({ units[$0]?.isFadedOut ?? true }) { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        for id in nodeIDs {
            guard let unit = units[id] else { continue }
            engine.disconnectNodeOutput(unit.sourceNode)
            engine.detach(unit.sourceNode)
            units.removeValue(forKey: id)
        }
    }

    /// Fade a node to silence over one audio buffer, then detach it.
    /// The render callback applies a linear ramp to zero and sets a flag
    /// when done. We poll briefly then disconnect — click-free removal.
    func muteAndRemoveUnit(for nodeID: UUID, engine: AVAudioEngine) {
        guard let unit = units[nodeID] else { return }
        unit.requestFadeOut()
        // Wait for the render callback to complete the fade (typically < 12ms).
        // Poll in 1ms increments with a hard cap to avoid hanging.
        for _ in 0..<30 {
            if unit.isFadedOut { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        engine.disconnectNodeOutput(unit.sourceNode)
        engine.detach(unit.sourceNode)
        units.removeValue(forKey: nodeID)
        logger.info("Faded and removed audio unit for node \(nodeID)")
    }

    // MARK: - Bulk Configuration

    /// Configure patches for all nodes from the tree data.
    func configureAllPatches(from tree: NodeTree) {
        configureNodePatchRecursive(tree.rootNode)
    }

    /// Load sequences for all nodes from the tree data.
    func loadAllSequences(from tree: NodeTree, bpm: Double = 120.0) {
        loadNodeSequenceRecursive(tree.rootNode, bpm: bpm)
    }

    // MARK: - Transport

    /// Start all active sequencers simultaneously at the given BPM.
    /// Excludes pre-staged units (they start only via activateStagedTree).
    /// Pass resetClock: false during forest timeline mode to keep the continuous clock.
    func startAll(bpm: Double, resetClock: Bool = true) {
        // Reset fade state from any previous stopAllWithFade()
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.resetFade()
        }
        if resetClock {
            clockSamplePosition.pointee = 0
            treeStartClockSample = 0
        }
        clockIsRunning.pointee = true
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.setClockStartOffset(0)
            unit.setDeactivateAtSample(0)
            unit.startSequencer(bpm: bpm)
        }
    }

    /// Start a single node's sequencer without resetting the global clock.
    func startUnit(for nodeID: UUID, bpm: Double) {
        units[nodeID]?.startSequencer(bpm: bpm)
    }

    /// Stop all active sequencers and silence all notes (instant — may click).
    func stopAll() {
        clockIsRunning.pointee = false
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.stopSequencer()
        }
    }

    /// Fade all active units to silence, then stop sequencers. Click-free.
    /// Units stay in faded state (outputting zeros) until the next startAll().
    func stopAllWithFade() {
        // Request fade-out on every active unit (not staged)
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.requestFadeOut()
        }
        // Wait for all to finish (typically < 12ms)
        for _ in 0..<30 {
            let allDone = units.filter({ !stagedIDs.contains($0.key) }).values.allSatisfy { $0.isFadedOut }
            if allDone { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        // Now safe to stop — output is already zero.
        // Do NOT resetFade() here — leave units outputting zeros so the
        // .sequencerStop command can process without any audible transient.
        // Fade is reset in startAll() before the next playback begins.
        clockIsRunning.pointee = false
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.stopSequencer()
        }
    }

    /// Update BPM on all running sequencers (excludes staged).
    func setAllBPM(_ bpm: Double) {
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.setSequencerBPM(bpm)
        }
    }

    // MARK: - Forest Timeline Region Methods

    /// Set region bounds on active (non-staged) units.
    func setActiveRegionBounds(start: Int64, end: Int64) {
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.setSequencerRegion(start: start, end: end)
        }
    }

    /// Change only the region end on active (non-staged) units.
    /// Used by lock-to-tree to extend without changing regionStart (avoids beat discontinuity).
    func setActiveRegionEnd(_ end: Int64) {
        for (id, unit) in units where !stagedIDs.contains(id) {
            unit.setSequencerRegionEnd(end)
        }
    }

    /// Set region bounds on staged units and arm them for auto-start.
    /// This REPLACES activateStagedTree() in forest timeline mode.
    /// Sequencers auto-start when the clock reaches regionStart — no
    /// startSequencer() call, no clock reset, no needsClockSync race.
    func armStagedUnits(regionStart: Int64, regionEnd: Int64) {
        for id in stagedIDs {
            guard let unit = units[id] else { continue }
            unit.setSequencerRegion(start: regionStart, end: regionEnd)
            unit.armSequencer()
        }
    }

    /// Promote staged units to active (for timeline mode).
    /// Called by main thread after detecting the audio thread has entered the region.
    /// Does NOT start/stop anything — just moves units from staged → active tracking
    /// so that setAllBPM() and other transport commands reach them.
    func promoteStagedToActive() {
        stagedIDs.removeAll()
        stagedTreeID = nil
    }

    /// Move units for a specific tree to draining state.
    /// They stay connected for release tails, then get cleaned up.
    func drainUnits(for nodeIDs: [UUID], engine: AVAudioEngine) {
        let drainingUnits = nodeIDs.compactMap { units.removeValue(forKey: $0) }
        for unit in drainingUnits { unit.stopSequencerSoft() }
        scheduleDrainingCleanup(drainingUnits, engine: engine)
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

    /// Configure the sound patch for a single node (no recursion).
    func configureSingleNodePatch(_ node: Node) {
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
            for (i, voiceConfig) in kitConfig.voices.enumerated() {
                unit.configureDrumVoice(index: i, config: voiceConfig)
            }
            unit.configurePatch(waveform: 0, detune: 0,
                               attack: 0, decay: 0, sustain: 0, release: 0,
                               volume: node.patch.volume)
        case .westCoast(let config):
            unit.configureWestCoast(config)
        case .flow(let config):
            unit.configureFlow(config)
            if config.spectralSource == .imprint, let imprint = config.imprint {
                unit.configureFlowImprint(imprint.harmonicAmplitudes)
            }
        case .tide(let config):
            unit.configureTide(config)
            if let imprint = config.imprint {
                let frames = SpectralImprint.tideFrames(from: imprint.spectralFrames)
                unit.configureTideImprint(frames)
            }
        case .swarm(let config):
            unit.configureSwarm(config)
            if config.triggerSource == .imprint, let imprint = config.imprint {
                unit.configureSwarmImprint(positions: imprint.peakRatios, amplitudes: imprint.peakAmplitudes)
            }
        case .quake(let config):
            unit.configureQuake(config)
            unit.configurePatch(waveform: 0, detune: 0,
                               attack: 0, decay: 0, sustain: 0, release: 0,
                               volume: config.volume)
        case .spore(let config):
            unit.configureSpore(config)
            if config.spectralSource == .imprint, let imprint = config.imprint {
                unit.configureSporeImprint(imprint.harmonicAmplitudes)
            }
        case .fuse(let config):
            unit.configureFuse(config)
        case .volt(let kit):
            for i in 0..<kit.voices.count {
                unit.configureVoltSlot(index: i, kit.voices[i])
            }
        case .schmynth(let config):
            unit.configureSchmynth(config)
        default:
            break
        }
        unit.setPan(Float(node.patch.pan))
        let f = node.patch.filter
        unit.configureFilter(enabled: f.enabled, cutoff: f.cutoff, resonance: f.resonance)
        if !node.effects.isEmpty {
            let chain = EffectChain.build(from: node.effects)
            unit.setFXChain(chain)
        }
    }

    private func configureNodePatchRecursive(_ node: Node) {
        configureSingleNodePatch(node)
        for child in node.children {
            configureNodePatchRecursive(child)
        }
    }

    /// Load the note sequence for a single node (no recursion).
    func loadSingleNodeSequence(_ node: Node, bpm: Double) {
        guard let unit = units[node.id] else { return }
        let seq = node.sequence
        let key = node.scaleOverride ?? node.key

        // Apply all sequence transforms (octave, fifth, invert, bloom, etc.)
        let events = SequenceTransforms.transformedEvents(from: seq, key: key, stepRate: node.stepRate)

        let mutation = seq.mutation
        unit.loadSequence(
            events, lengthInBeats: seq.lengthInBeats,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals
        )
        unit.setGlobalProbability(seq.globalProbability)

        if let arpConfig = seq.arpConfig {
            let sampleRate = AudioEngine.shared.sampleRate
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

        if node.sequencerType == .orbit {
            let orbitConfig = node.orbitConfig ?? OrbitConfig()
            unit.configureOrbit(orbitConfig)
            unit.setUseOrbitSequencer(true)
        }

        if let sporeSeq = node.sporeSeqConfig {
            unit.configureSporeSeq(sporeSeq, key: node.scaleOverride ?? node.key)
        }
    }

    private func loadNodeSequenceRecursive(_ node: Node, bpm: Double) {
        loadSingleNodeSequence(node, bpm: bpm)
        for child in node.children {
            loadNodeSequenceRecursive(child, bpm: bpm)
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
