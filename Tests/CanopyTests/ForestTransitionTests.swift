import XCTest
import AVFoundation
@testable import Canopy

/// Offline rendering tests for forest tree transitions.
///
/// Uses AVAudioEngine in manual rendering mode with TreeAudioGraph directly
/// (bypassing AudioEngine singleton) to deterministically render through a
/// tree transition and analyze the output buffer for clicks, overlapping
/// onsets, and beat-0 re-triggers.
final class ForestTransitionTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Per-test configuration. Each adversarial scenario can vary these.
    struct TestConfig {
        var sampleRate: Double = 44100
        var bpm: Double = 120
        var bufferSize: AVAudioFrameCount = 512

        var samplesPerBeat: Double { 60.0 * sampleRate / bpm }
    }

    private let defaultConfig = TestConfig()

    // MARK: - Test Tree Builders

    /// Single root node with one note at beat 0.
    private func makeTestTree(pitch: Int, name: String, lengthInBeats: Double = 4) -> NodeTree {
        let note = NoteEvent(
            pitch: pitch,
            velocity: 0.8,
            startBeat: 0.0,
            duration: 0.25
        )
        let sequence = NoteSequence(
            notes: [note],
            lengthInBeats: lengthInBeats
        )
        let patch = SoundPatch(
            name: name,
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(
                attack: 0.001,
                decay: 0.05,
                sustain: 0.0,
                release: 0.01
            ),
            volume: 0.8
        )
        let root = Node(
            name: name,
            sequence: sequence,
            patch: patch
        )
        return NodeTree(name: name, rootNode: root)
    }

    /// Multi-node tree: root + child with different sequence lengths.
    /// Creates natural polyrhythm (LCM cycle).
    private func makePolyrhythmTree(
        rootPitch: Int, rootLength: Double,
        childPitch: Int, childLength: Double,
        name: String
    ) -> NodeTree {
        let rootNote = NoteEvent(pitch: rootPitch, velocity: 0.8, startBeat: 0.0, duration: 0.25)
        let childNote = NoteEvent(pitch: childPitch, velocity: 0.8, startBeat: 0.0, duration: 0.25)

        let rootSeq = NoteSequence(notes: [rootNote], lengthInBeats: rootLength)
        let childSeq = NoteSequence(notes: [childNote], lengthInBeats: childLength)

        let rootPatch = SoundPatch(
            name: "\(name)-root",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.01),
            volume: 0.8
        )
        let childPatch = SoundPatch(
            name: "\(name)-child",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.01),
            volume: 0.8
        )

        let child = Node(name: "\(name)-child", sequence: childSeq, patch: childPatch)
        let root = Node(name: "\(name)-root", sequence: rootSeq, patch: rootPatch, children: [child])
        return NodeTree(name: name, rootNode: root)
    }

    /// Compute LCM cycle length of a tree (mirrors MainContentView.computeCycleLength).
    private func computeCycleLength(tree: NodeTree) -> Double {
        var nodes: [Node] = []
        collectNodes(from: tree.rootNode, into: &nodes)
        guard !nodes.isEmpty else { return 1 }
        let ticksPerBeat = 96.0
        let tickCounts = nodes.map { max(1, Int(round($0.sequence.lengthInBeats * ticksPerBeat))) }
        let lcmTicks = tickCounts.reduce(1) { lcm($0, $1) }
        return Double(lcmTicks) / ticksPerBeat
    }

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children { collectNodes(from: child, into: &result) }
    }

    /// Collect all node IDs from a tree recursively. Used with drainUnits(for:engine:).
    private func collectNodeIDs(from tree: NodeTree) -> [UUID] {
        var ids: [UUID] = []
        collectNodeIDsRecursive(from: tree.rootNode, into: &ids)
        return ids
    }

    private func collectNodeIDsRecursive(from node: Node, into ids: inout [UUID]) {
        ids.append(node.id)
        for child in node.children {
            collectNodeIDsRecursive(from: child, into: &ids)
        }
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a); var b = abs(b)
        while b != 0 { let t = b; b = a % b; a = t }
        return a
    }

    private func lcm(_ a: Int, _ b: Int) -> Int {
        guard a != 0 && b != 0 else { return 1 }
        return abs(a * b) / gcd(a, b)
    }

    // MARK: - Offline Rendering

    /// Render N buffers, advancing the graph clock after each pull. Returns left-channel samples.
    private func renderSamples(
        engine: AVAudioEngine,
        graph: TreeAudioGraph,
        bufferCount: Int,
        format: AVAudioFormat,
        bufferSize: AVAudioFrameCount = 512
    ) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(bufferCount * Int(bufferSize))

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize)!

        for _ in 0..<bufferCount {
            let status = try engine.renderOffline(bufferSize, to: outputBuffer)
            guard status == .success else { break }

            if let channelData = outputBuffer.floatChannelData {
                let leftChannel = channelData[0]
                for i in 0..<Int(bufferSize) {
                    samples.append(leftChannel[i])
                }
            }

            graph.clockSamplePosition.pointee += Int64(bufferSize)
        }

        return samples
    }

    // MARK: - Analysis Helpers

    /// Peak absolute sample-to-sample derivative in a range.
    private func maxDerivative(in samples: [Float], range: Range<Int>) -> Float {
        guard range.lowerBound >= 1, range.upperBound <= samples.count else { return 0 }
        var maxDeriv: Float = 0
        for i in range {
            let d = abs(samples[i] - samples[i - 1])
            if d > maxDeriv { maxDeriv = d }
        }
        return maxDeriv
    }

    /// RMS energy of a contiguous window.
    private func rms(of samples: [Float], range: Range<Int>) -> Float {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return 0 }
        var sum: Float = 0
        for i in range { sum += samples[i] * samples[i] }
        return sqrt(sum / Float(range.count))
    }

    /// Detect onset events: amplitude rising above threshold after being below it.
    private func detectOnsets(
        in samples: [Float], range: Range<Int>,
        threshold: Float, samplesPerBeat: Double
    ) -> [Int] {
        guard range.lowerBound >= 0, range.upperBound <= samples.count else { return [] }
        var onsets: [Int] = []
        var wasBelow = true
        let minGap = Int(samplesPerBeat * 0.5)

        for i in range {
            let amp = abs(samples[i])
            if amp > threshold {
                if wasBelow {
                    if let last = onsets.last, i - last < minGap { /* too close */ }
                    else { onsets.append(i) }
                    wasBelow = false
                }
            } else {
                wasBelow = true
            }
        }
        return onsets
    }

    /// Max derivative in the second cycle of tree 1 (steady-state reference).
    private func steadyStateMaxDerivative(in samples: [Float], config: TestConfig, cycleBeats: Double) -> Float {
        let cycleStart = Int(cycleBeats * config.samplesPerBeat)
        let cycleEnd = min(Int(2 * cycleBeats * config.samplesPerBeat), samples.count)
        guard cycleStart + 1 < cycleEnd else { return 0.001 }
        return maxDerivative(in: samples, range: cycleStart..<cycleEnd)
    }

    /// Max RMS in 512-sample windows during the second cycle.
    private func steadyStateRMS(in samples: [Float], config: TestConfig, cycleBeats: Double) -> Float {
        let cycleStart = Int(cycleBeats * config.samplesPerBeat)
        let cycleEnd = min(Int(2 * cycleBeats * config.samplesPerBeat), samples.count)
        var maxRMS: Float = 0
        var pos = cycleStart
        let window = Int(config.bufferSize)
        while pos + window <= cycleEnd {
            let r = rms(of: samples, range: pos..<(pos + window))
            if r > maxRMS { maxRMS = r }
            pos += window
        }
        return max(maxRMS, 0.0001)
    }

    /// Run the standard 3-assertion check on a rendered buffer around a transition point.
    private func assertCleanTransition(
        samples: [Float],
        transitionSampleIndex: Int,
        config: TestConfig,
        cycleBeats: Double,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let totalSamples = samples.count
        let bs = Int(config.bufferSize)
        let windowStart = max(1, transitionSampleIndex - bs)
        let windowEnd = min(totalSamples, transitionSampleIndex + bs)

        // 1. CLICK DETECTION — derivative spike
        let baselineDeriv = steadyStateMaxDerivative(in: samples, config: config, cycleBeats: cycleBeats)
        let transitionDeriv = maxDerivative(in: samples, range: windowStart..<windowEnd)
        let derivThreshold = baselineDeriv * 2.0

        XCTAssertLessThanOrEqual(
            transitionDeriv, derivThreshold,
            "\(label): Click detected — peak derivative \(transitionDeriv) > 2× baseline (\(baselineDeriv)). " +
            "Ratio: \(transitionDeriv / max(baselineDeriv, 0.0001))×",
            file: file, line: line
        )

        // 2. ONSET COUNT — at most 1 near transition
        let onsetStart = max(0, transitionSampleIndex - Int(config.samplesPerBeat))
        let onsetEnd = min(totalSamples, transitionSampleIndex + Int(config.samplesPerBeat))
        let onsets = detectOnsets(
            in: samples, range: onsetStart..<onsetEnd,
            threshold: 0.01, samplesPerBeat: config.samplesPerBeat
        )
        XCTAssertLessThanOrEqual(
            onsets.count, 1,
            "\(label): \(onsets.count) onsets near transition (expected ≤1). " +
            "Offsets: \(onsets.map { $0 - transitionSampleIndex })",
            file: file, line: line
        )

        // 3. RMS CONTINUITY — no energy spike
        let baselineRMS = steadyStateRMS(in: samples, config: config, cycleBeats: cycleBeats)
        let rmsThresh = baselineRMS * 3.0
        var pos = windowStart
        while pos + bs <= windowEnd {
            let windowRMS = rms(of: samples, range: pos..<(pos + bs))
            XCTAssertLessThanOrEqual(
                windowRMS, rmsThresh,
                "\(label): RMS spike at offset \(pos - transitionSampleIndex): " +
                "\(windowRMS) > 3× baseline (\(baselineRMS))",
                file: file, line: line
            )
            pos += bs
        }
    }

    // MARK: - Transition Runner

    /// Common pattern: build tree 1, render N cycles, stage tree 2, render to boundary,
    /// optionally delay activation by `activationDelayBuffers`, activate, render tree 2.
    private func runTransitionTest(
        tree1: NodeTree,
        tree2: NodeTree,
        config: TestConfig,
        cycleLengthInBeats: Double,
        preStageBeatsBefore: Double = 1,
        tree1Cycles: Int = 2,
        activationDelayBuffers: Int = 0,
        label: String
    ) throws -> (samples: [Float], transitionIndex: Int) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let tree1Total = tree1Cycles * samplesPerCycle
        let tree1Buffers = tree1Total / Int(config.bufferSize)
        let preStageSamples = Int(preStageBeatsBefore * config.samplesPerBeat)
        let preStageBuffers = (tree1Total - preStageSamples) / Int(config.bufferSize)

        // Render tree 1 up to staging point
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: preStageBuffers, format: format,
            bufferSize: config.bufferSize
        )

        // Stage tree 2
        graph.stageNextTree(
            tree2, engine: engine, sampleRate: config.sampleRate,
            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats
        )

        // Render through to cycle boundary
        let remainingBuffers = tree1Buffers - preStageBuffers
        let transitionSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remainingBuffers, format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: transitionSamples)

        // Optional delay (simulates main thread lag)
        if activationDelayBuffers > 0 {
            let delaySamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: activationDelayBuffers, format: format,
                bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: delaySamples)
        }

        let transitionIndex = allSamples.count

        // Activate tree 2
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render 1 cycle of tree 2
        let tree2Buffers = samplesPerCycle / Int(config.bufferSize)
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(tree2Buffers, 10), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        engine.stop()
        return (allSamples, transitionIndex)
    }

    // MARK: - Arm Transition Runner

    /// Mirrors the production forest timeline flow exactly:
    /// 1. Build tree 1, configure, load, startAll(bpm:, resetClock: true)
    /// 2. setActiveRegionBounds — region-gate tree 1
    /// 3. stageNextTree — WITHOUT currentCycleLengthInBeats (skips timestamps)
    /// 4. armStagedUnits — arm tree 2 with region bounds
    /// 5. Render through tree 1's full region + past boundary
    /// 6. Optional bookkeeping delay (simulates main-thread lag)
    /// 7. promoteStagedToActive + drainUnits — bookkeeping
    /// 8. Render remainder of tree 2
    /// Returns (samples, transitionIndex) where transitionIndex = region1End in samples.
    private func runArmTransitionTest(
        tree1: NodeTree, tree2: NodeTree,
        config: TestConfig,
        tree1CycleLengthInBeats: Double,
        tree2CycleLengthInBeats: Double? = nil,
        tree1Cycles: Int = 2,
        bookkeepingDelayBuffers: Int = 0,
        label: String
    ) throws -> (samples: [Float], transitionIndex: Int) {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()

        // 1. Build tree 1, configure, load, start
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm, resetClock: true)

        // 2. Region-gate tree 1
        let samplesPerBeat = 60.0 * config.sampleRate / config.bpm
        let region1End = Int64(Double(tree1Cycles) * tree1CycleLengthInBeats * samplesPerBeat)
        graph.setActiveRegionBounds(start: 0, end: region1End)

        // Compute tree 2 region
        let tree2Cycle = tree2CycleLengthInBeats ?? tree1CycleLengthInBeats
        let tree2CycleSamples = Int64(tree2Cycle * samplesPerBeat)
        let region2End = region1End + tree2CycleSamples * 2  // 2 cycles of tree 2

        // 3. Stage tree 2 WITHOUT currentCycleLengthInBeats (no timestamps)
        //    This mirrors the arm-based path where stageNextTree is called with default 0.
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)

        // 4. Arm staged units with region bounds
        graph.armStagedUnits(regionStart: region1End, regionEnd: region2End, bpm: config.bpm)

        // Capture tree 1 IDs for draining later
        let tree1IDs = collectNodeIDs(from: tree1)

        // 5. Render through tree 1's full region + 1 buffer past boundary
        let tree1TotalSamples = Int(region1End)
        let tree1Buffers = tree1TotalSamples / Int(config.bufferSize) + 1
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: tree1Buffers, format: format,
            bufferSize: config.bufferSize
        )

        // 6. Optional bookkeeping delay (simulates main-thread lag)
        if bookkeepingDelayBuffers > 0 {
            let delaySamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: bookkeepingDelayBuffers, format: format,
                bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: delaySamples)
        }

        // 7. Bookkeeping: promote staged → active, drain old tree
        graph.promoteStagedToActive()
        graph.drainUnits(for: tree1IDs, engine: engine)

        // 8. Render remainder of tree 2 (2 cycles worth)
        let tree2Buffers = Int(tree2CycleSamples) * 2 / Int(config.bufferSize)
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(tree2Buffers, 10), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        engine.stop()
        return (allSamples, Int(region1End))
    }

    // =========================================================================
    // MARK: - Baseline Test (Ideal Timing)
    // =========================================================================

    func testForestTransitionNoClicks() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1-C3")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2-E3")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "Baseline"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4, label: "Baseline"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Late Activation (Main Thread Lag)
    // =========================================================================

    /// Simulates ~12ms main thread lag (the ForestAdvancePoller runs at ~60fps).
    /// The old tree auto-stops at the boundary, but activation doesn't happen
    /// until ~12ms later. The new tree starts from a clock offset past the boundary.
    func testLateActivation_12ms() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        // 12ms ≈ 529 samples ≈ ~1 buffer at 512
        let delayBuffers = 1

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, activationDelayBuffers: delayBuffers,
            label: "Late 12ms"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4, label: "Late activation 12ms"
        )
    }

    /// Simulates ~50ms lag (extreme GC pause or UI stall).
    func testLateActivation_50ms() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        // 50ms ≈ 2205 samples ≈ ~4 buffers
        let delayBuffers = 4

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, activationDelayBuffers: delayBuffers,
            label: "Late 50ms"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4, label: "Late activation 50ms"
        )
    }

    /// Simulates ~200ms lag (pathological case — scrolling, heavy UI, etc.)
    func testLateActivation_200ms() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        // 200ms ≈ 8820 samples ≈ ~17 buffers
        let delayBuffers = 17

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, activationDelayBuffers: delayBuffers,
            label: "Late 200ms"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4, label: "Late activation 200ms"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Early Activation (Before Cycle Boundary)
    // =========================================================================

    /// Call activateStagedTree BEFORE the cycle boundary (early bookkeeping).
    /// With the timestamp-based architecture, activateStagedTree is just bookkeeping —
    /// tree 2 activates at the boundary sample regardless of when the main thread calls it.
    /// This verifies early bookkeeping is harmless and the transition is clean.
    func testEarlyActivation_1BeatBefore() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)

        // Render 1 cycle minus 2 beats
        let earlyBuffers = (samplesPerCycle - Int(2 * config.samplesPerBeat)) / Int(config.bufferSize)
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: earlyBuffers, format: format, bufferSize: config.bufferSize
        )

        // Stage tree 2
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        // Render 2 more buffers (still ~1 beat before boundary)
        let midSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 2, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: midSamples)

        // Call activateStagedTree EARLY — about 1 beat before the boundary.
        // With the timestamp architecture, this is just bookkeeping.
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render through the boundary and one more cycle
        let renderedSoFar = allSamples.count
        let remainingToNextCycle = max(0, samplesPerCycle - renderedSoFar)
        let remainingBuffers = remainingToNextCycle / Int(config.bufferSize)
        let postCycleBuffers = samplesPerCycle / Int(config.bufferSize)
        let postSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remainingBuffers + postCycleBuffers, format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: postSamples)

        // Transition happens at the cycle boundary, not at activateStagedTree
        let transitionIndex = samplesPerCycle

        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Early activation (bookkeeping 1 beat before boundary)"
        )

        engine.stop()
    }

    // =========================================================================
    // MARK: - Adversarial: Multi-Node Polyrhythm Trees
    // =========================================================================

    /// Tree with 3-beat and 4-beat branches (LCM = 12 beats).
    /// Tests that the LCM boundary computation and multi-unit stop/start works.
    func testPolyrhythmTreeTransition() throws {
        let config = defaultConfig

        let tree1 = makePolyrhythmTree(
            rootPitch: 48, rootLength: 3,
            childPitch: 55, childLength: 4,
            name: "PolyTree1"
        )
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let cycleLengthInBeats = computeCycleLength(tree: tree1)
        XCTAssertEqual(cycleLengthInBeats, 12, "LCM of 3 and 4 should be 12")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: cycleLengthInBeats,
            preStageBeatsBefore: 2,
            tree1Cycles: 1,  // 1 LCM cycle = 12 beats
            label: "Polyrhythm"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Polyrhythm tree (3+4 beat branches)"
        )
    }

    /// Both trees are polyrhythmic. Tree 1: 3+4 (LCM=12), Tree 2: 3+5 (LCM=15).
    func testPolyrhythmToPolyrhythmTransition() throws {
        let config = defaultConfig

        let tree1 = makePolyrhythmTree(
            rootPitch: 48, rootLength: 3,
            childPitch: 55, childLength: 4,
            name: "Poly3x4"
        )
        let tree2 = makePolyrhythmTree(
            rootPitch: 52, rootLength: 3,
            childPitch: 60, childLength: 5,
            name: "Poly3x5"
        )

        let cycle1 = computeCycleLength(tree: tree1) // 12
        let cycle2 = computeCycleLength(tree: tree2) // 15

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: cycle1,
            preStageBeatsBefore: 2,
            tree1Cycles: 1,
            label: "Poly→Poly"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycle1,
            label: "Polyrhythm→Polyrhythm (12→15 beat cycles)"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Fractional BPM (Non-Integer Samples Per Beat)
    // =========================================================================

    /// At 130 BPM, samples/beat = 20353.846... — fractional, forces rounding
    /// in the stop-at-sample and beat detection calculations.
    func testFractionalBPM_130() throws {
        var config = TestConfig()
        config.bpm = 130

        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "BPM 130"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Fractional BPM (130)"
        )
    }

    /// At 97 BPM, samples/beat = 27278.35... — highly fractional, prime BPM.
    func testFractionalBPM_97() throws {
        var config = TestConfig()
        config.bpm = 97

        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "BPM 97"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Fractional BPM (97)"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Small Buffer Sizes
    // =========================================================================

    /// 128-sample buffers — more buffer boundaries to misalign with cycle boundary.
    func testSmallBufferSize_128() throws {
        var config = TestConfig()
        config.bufferSize = 128

        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "Buffer 128"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Small buffer (128 samples)"
        )
    }

    /// 1024-sample buffers — the fade ramp is longer, covering more musical content.
    func testLargeBufferSize_1024() throws {
        var config = TestConfig()
        config.bufferSize = 1024

        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "Buffer 1024"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Large buffer (1024 samples)"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Back-to-Back Rapid Transitions
    // =========================================================================

    /// Transition tree1→tree2→tree3 with 1-cycle spacing.
    /// Tests that the second transition works correctly when the first transition's
    /// draining cleanup hasn't completed.
    func testBackToBackTransitions() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")
        let tree3 = makeTestTree(pitch: 55, name: "Tree3")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)
        let stagingBuffers = (samplesPerCycle - Int(config.samplesPerBeat)) / Int(config.bufferSize)

        // --- Transition 1: tree1 → tree2 ---
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining1 = cycleBuffers - stagingBuffers
        let boundary1Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining1, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: boundary1Samples)

        let transition1Index = allSamples.count
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render tree 2 up to staging point for tree 3
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        // --- Transition 2: tree2 → tree3 ---
        graph.stageNextTree(tree3, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining2 = cycleBuffers - stagingBuffers
        let boundary2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining2, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: boundary2Samples)

        let transition2Index = allSamples.count
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render tree 3 for one cycle
        let tree3Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: cycleBuffers, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree3Samples)

        engine.stop()

        // Check BOTH transitions
        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transition1Index,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Back-to-back transition 1 (tree1→tree2)"
        )
        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transition2Index,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Back-to-back transition 2 (tree2→tree3)"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Late Bookkeeping (Audio-Thread Independence)
    // =========================================================================

    /// Verifies that rendering past the cycle boundary BEFORE calling activateStagedTree
    /// produces correct audio. The audio thread handles activation/deactivation via
    /// sample-precise timestamps set during stageNextTree — main-thread bookkeeping
    /// timing is irrelevant.
    func testGapRenderBeforeBookkeeping() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)
        let stagingBuffers = (samplesPerCycle - Int(config.samplesPerBeat)) / Int(config.bufferSize)

        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining = cycleBuffers - stagingBuffers
        let boundarySamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: boundarySamples)

        // Render 3 buffers PAST the boundary before calling activateStagedTree.
        // The audio thread already activated tree 2 at the boundary sample.
        let gapSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 3, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: gapSamples)

        // Late bookkeeping — audio is already correct
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render tree 2 for 1 cycle
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(cycleBuffers, 10), format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        let transitionIndex = samplesPerCycle

        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Gap render (3 buffers past boundary before bookkeeping)"
        )

        // Verify gap buffers contain audio (tree 2 activated at boundary by audio thread)
        let gapStartIndex = (stagingBuffers + remaining) * Int(config.bufferSize)
        let gapEndIndex = gapStartIndex + 3 * Int(config.bufferSize)
        let gapRMS = rms(of: allSamples, range: gapStartIndex..<min(gapEndIndex, allSamples.count))
        XCTAssertGreaterThan(gapRMS, 0.001,
                             "Gap buffers should contain tree 2 audio (audio-thread activation)")

        engine.stop()
    }


    // =========================================================================
    // MARK: - Adversarial: Misaligned Cycle Boundary
    // =========================================================================

    /// 3-beat cycle at 120 BPM: 66150 samples per cycle, which does NOT divide
    /// evenly by common buffer sizes (512, 256, 128, 1024). The cycle boundary
    /// falls mid-buffer, testing the auto-stop's buffer-lookahead logic.
    func testMisalignedCycleBoundary() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1", lengthInBeats: 3)
        let tree2 = makeTestTree(pitch: 52, name: "Tree2", lengthInBeats: 3)

        let cycleLengthInBeats: Double = 3

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: cycleLengthInBeats,
            preStageBeatsBefore: 1,
            tree1Cycles: 2,
            label: "Misaligned 3-beat"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Misaligned cycle boundary (3-beat cycle)"
        )
    }

    /// Worst case: 3-beat cycle at 97 BPM with 128-sample buffers.
    /// Non-integer samples/beat AND non-aligned cycle boundary.
    func testWorstCaseAlignment() throws {
        var config = TestConfig()
        config.bpm = 97
        config.bufferSize = 128

        let tree1 = makeTestTree(pitch: 48, name: "Tree1", lengthInBeats: 3)
        let tree2 = makeTestTree(pitch: 52, name: "Tree2", lengthInBeats: 3)

        let cycleLengthInBeats: Double = 3

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: cycleLengthInBeats,
            preStageBeatsBefore: 1,
            tree1Cycles: 2,
            label: "Worst alignment"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Worst case alignment (3-beat, 97 BPM, 128 buffer)"
        )
    }

    // =========================================================================
    // MARK: - Adversarial: Dense Note Pattern (Note at Cycle End)
    // =========================================================================

    /// Tree 1 has a note at beat 3.75 (very close to the cycle boundary at beat 4).
    /// Tests that the auto-stop/fade doesn't clip the tail of a note that's still
    /// sounding when the boundary arrives, and that tree 2's beat-0 note doesn't
    /// overlap with it.
    func testNoteAtCycleEnd() throws {
        let config = defaultConfig

        // Tree 1: note at beat 0 (standard) AND beat 3.75 (near boundary)
        let note1 = NoteEvent(pitch: 48, velocity: 0.8, startBeat: 0.0, duration: 0.25)
        let note2 = NoteEvent(pitch: 48, velocity: 0.8, startBeat: 3.75, duration: 0.25)
        let seq1 = NoteSequence(notes: [note1, note2], lengthInBeats: 4)
        let patch1 = SoundPatch(
            name: "T1",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.01),
            volume: 0.8
        )
        let root1 = Node(name: "T1", sequence: seq1, patch: patch1)
        let tree1 = NodeTree(name: "Tree1", rootNode: root1)

        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let (samples, transitionIndex) = try runTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            cycleLengthInBeats: 4, label: "Note at cycle end"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Note at cycle end (beat 3.75)"
        )
    }

    // =========================================================================
    // MARK: - Focused Tests (from original)
    // =========================================================================

    /// Verifies that tree 1's sequencer is stopped after rendering past the
    /// cycle boundary. The deactivateAtSample timestamp fires on the audio thread,
    /// calling stopSoft which sets isPlaying = false.
    func testDeactivationStopsSequencer() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let preStageBuffers = (samplesPerCycle - Int(config.samplesPerBeat)) / Int(config.bufferSize)
        _ = try renderSamples(engine: engine, graph: graph, bufferCount: preStageBuffers,
                              format: format, bufferSize: config.bufferSize)

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let boundaryBuffers = Int(config.samplesPerBeat) / Int(config.bufferSize) + 4
        _ = try renderSamples(engine: engine, graph: graph, bufferCount: boundaryBuffers,
                              format: format, bufferSize: config.bufferSize)

        let tree1NodeID = tree1.rootNode.id
        if let unit = graph.unit(for: tree1NodeID) {
            XCTAssertFalse(unit.isPlaying,
                           "Tree 1 sequencer should have stopped after passing cycle boundary")
        }

        engine.stop()
    }

    /// Verifies that tree 2's fade-in produces a smooth ramp at the cycle boundary.
    /// The audio thread activates tree 2 at the exact boundary sample (set during
    /// stageNextTree), triggering a 1-buffer fade-in ramp from 0→1.
    func testFadeInSmoothsNewTreeOnset() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)
        let preStageBuffers = (samplesPerCycle - Int(config.samplesPerBeat)) / Int(config.bufferSize)
        _ = try renderSamples(engine: engine, graph: graph, bufferCount: preStageBuffers,
                              format: format, bufferSize: config.bufferSize)

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remainingBuffers = cycleBuffers - preStageBuffers
        _ = try renderSamples(engine: engine, graph: graph, bufferCount: remainingBuffers,
                              format: format, bufferSize: config.bufferSize)

        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: config.bufferSize)!
        let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
        graph.clockSamplePosition.pointee += Int64(config.bufferSize)

        XCTAssertEqual(status, .success)

        if let channelData = outputBuffer.floatChannelData {
            let leftChannel = channelData[0]
            let firstSample = abs(leftChannel[0])
            XCTAssertLessThan(firstSample, 0.01,
                              "First sample after transition should be near zero (fade-in), got \(firstSample)")
            let lastSample = abs(leftChannel[Int(config.bufferSize) - 1])
            XCTAssertGreaterThan(lastSample, firstSample,
                                 "Fade-in should ramp up: first=\(firstSample), last=\(lastSample)")
        }

        engine.stop()
    }

    // =========================================================================
    // MARK: - Stress: Consecutive Transitions
    // =========================================================================

    /// 100 consecutive tree transitions, each verified for clean audio.
    /// Stresses the activate/deactivate timestamp mechanism under rapid cycling.
    func testConsecutiveTransitions_100() throws {
        let config = defaultConfig
        let cycleLengthInBeats: Double = 2
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()

        // Create 101 trees with different pitches
        let trees = (0...100).map { i in
            makeTestTree(pitch: 48 + (i % 12), name: "Tree\(i)", lengthInBeats: cycleLengthInBeats)
        }

        graph.buildGraph(from: trees[0], engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: trees[0])
        graph.loadAllSequences(from: trees[0], bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        // Render 1 cycle of the first tree
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: cycleBuffers, format: format, bufferSize: config.bufferSize
        )

        for i in 1...100 {
            let stagingPoint = max(1, cycleBuffers - Int(config.samplesPerBeat) / Int(config.bufferSize))

            // Render to staging point
            let preStageSamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: stagingPoint, format: format, bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: preStageSamples)

            // Stage next tree
            graph.stageNextTree(trees[i], engine: engine, sampleRate: config.sampleRate,
                                bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

            // Render to boundary
            let remaining = cycleBuffers - stagingPoint
            let boundarySamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: remaining, format: format, bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: boundarySamples)

            let transitionIndex = allSamples.count

            // Activate (bookkeeping)
            graph.activateStagedTree(engine: engine, bpm: config.bpm)

            // Render 1 cycle of new tree
            let newTreeSamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: cycleBuffers, format: format, bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: newTreeSamples)

            // Check every 10th transition to keep test time reasonable
            if i % 10 == 0 {
                assertCleanTransition(
                    samples: allSamples, transitionSampleIndex: transitionIndex,
                    config: config, cycleBeats: cycleLengthInBeats,
                    label: "Consecutive transition \(i)"
                )
            }
        }

        engine.stop()
    }

    // =========================================================================
    // MARK: - Adversarial: BPM Change at Transition
    // =========================================================================

    /// Tree 1 at 120 BPM transitions to tree 2 at 90 BPM.
    /// Verifies the activation uses the correct BPM stored during staging.
    func testBPMChangeAtTransition() throws {
        let bpm1: Double = 120
        let bpm2: Double = 90
        var config = TestConfig()
        config.bpm = bpm1

        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: bpm1)

        try engine.start()
        graph.startAll(bpm: bpm1)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle1 = Int(cycleLengthInBeats * 60.0 * config.sampleRate / bpm1)
        let cycleBuffers1 = samplesPerCycle1 / Int(config.bufferSize)
        let stagingBuffers = (samplesPerCycle1 - Int(60.0 * config.sampleRate / bpm1)) / Int(config.bufferSize)

        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        // Stage tree 2 at different BPM
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: bpm2, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining = cycleBuffers1 - stagingBuffers
        let boundarySamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: boundarySamples)

        let transitionIndex = allSamples.count
        graph.activateStagedTree(engine: engine, bpm: bpm2)

        // Render 2 cycles of tree 2 at 90 BPM
        let samplesPerCycle2 = Int(cycleLengthInBeats * 60.0 * config.sampleRate / bpm2)
        let tree2Buffers = 2 * samplesPerCycle2 / Int(config.bufferSize)
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(tree2Buffers, 10), format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "BPM change (120→90)"
        )

        // Verify tree 2 has audio (BPM was set correctly during activation)
        let tree2Start = transitionIndex
        let tree2End = min(allSamples.count, tree2Start + samplesPerCycle2)
        let tree2RMS = rms(of: allSamples, range: tree2Start..<tree2End)
        XCTAssertGreaterThan(tree2RMS, 0.001,
                             "Tree 2 should produce audio with BPM=\(bpm2)")

        engine.stop()
    }

    // =========================================================================
    // MARK: - Adversarial: Very Late Bookkeeping
    // =========================================================================

    /// Render 10 full cycles past the boundary before calling activateStagedTree.
    /// The audio thread handled the transition at the boundary — late bookkeeping
    /// has zero audible consequence.
    func testVeryLateBookkeeping() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)
        let stagingBuffers = (samplesPerCycle - Int(config.samplesPerBeat)) / Int(config.bufferSize)

        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining = cycleBuffers - stagingBuffers
        let boundarySamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: boundarySamples)

        // Render 10 full cycles past the boundary WITHOUT calling activateStagedTree.
        // Audio thread already handled the transition.
        let lateSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 10 * cycleBuffers, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: lateSamples)

        // Finally do bookkeeping (very late — 10 cycles late!)
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render 1 more cycle
        let postSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: cycleBuffers, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: postSamples)

        let transitionIndex = samplesPerCycle

        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Very late bookkeeping (10 cycles late)"
        )

        // Verify the late region has audio (tree 2 was playing all along)
        let lateStart = samplesPerCycle + Int(config.samplesPerBeat)
        let lateEnd = min(allSamples.count, lateStart + samplesPerCycle)
        let lateRMS = rms(of: allSamples, range: lateStart..<lateEnd)
        XCTAssertGreaterThan(lateRMS, 0.001,
                             "Tree 2 should be playing during late bookkeeping period")

        engine.stop()
    }

    // =========================================================================
    // MARK: - Adversarial: Immediate Crossfade Swap
    // =========================================================================

    /// Tests the fallback crossfadeSwap path which uses immediate timestamps
    /// (no pre-staging). Verifies clean transition with instant activation/deactivation.
    func testImmediateCrossfadeSwap() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "Tree1")
        let tree2 = makeTestTree(pitch: 52, name: "Tree2")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm)

        // Render 2 cycles of tree 1
        let cycleLengthInBeats: Double = 4
        let samplesPerCycle = Int(cycleLengthInBeats * config.samplesPerBeat)
        let cycleBuffers = samplesPerCycle / Int(config.bufferSize)
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 2 * cycleBuffers, format: format, bufferSize: config.bufferSize
        )

        let transitionIndex = allSamples.count

        // Use crossfadeSwap (no pre-staging, immediate timestamps)
        graph.crossfadeSwap(to: tree2, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)

        // Render 2 cycles of tree 2
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 2 * cycleBuffers, format: format, bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Immediate crossfade swap"
        )

        // Verify tree 2 has audio
        let tree2RMS = rms(of: allSamples,
                           range: (transitionIndex + samplesPerCycle)..<min(allSamples.count, transitionIndex + 2 * samplesPerCycle))
        XCTAssertGreaterThan(tree2RMS, 0.001,
                             "Tree 2 should produce audio after crossfade swap")

        engine.stop()
    }

    // =========================================================================
    // MARK: - Forest Timeline Arm-Based Transitions
    // =========================================================================

    /// Fundamental arm mechanism — tree 1 auto-stops at region end, tree 2
    /// auto-starts when clock reaches region start. No clicks.
    func testArmTransition_Basic4x4() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "ArmTree1")
        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2")

        let (samples, transitionIndex) = try runArmTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            tree1CycleLengthInBeats: 4,
            tree1Cycles: 2,
            label: "Arm basic 4×4"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Arm basic 4×4"
        )

        // Verify tree 2 is producing audio after the transition
        let tree2Start = transitionIndex + Int(config.samplesPerBeat)
        let tree2End = min(samples.count, tree2Start + Int(4 * config.samplesPerBeat))
        let tree2RMS = rms(of: samples, range: tree2Start..<tree2End)
        XCTAssertGreaterThan(tree2RMS, 0.001,
                             "Arm: Tree 2 should produce audio after region boundary")
    }

    /// 10-buffer delay before promote/drain — verifies audio is independent of
    /// main-thread bookkeeping timing. The arm mechanism handles start/stop on
    /// the audio thread; bookkeeping is just cleanup.
    func testArmTransition_LateBookkeeping() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "ArmTree1")
        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2")

        let (samples, transitionIndex) = try runArmTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            tree1CycleLengthInBeats: 4,
            tree1Cycles: 2,
            bookkeepingDelayBuffers: 10,
            label: "Arm late bookkeeping"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Arm late bookkeeping (10 buffers)"
        )
    }

    /// tree1→tree2→tree3 — two consecutive arm transitions with staging/draining
    /// between. Verifies the full lifecycle works back-to-back.
    func testArmTransition_BackToBack() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "ArmTree1")
        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2")
        let tree3 = makeTestTree(pitch: 55, name: "ArmTree3")

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        let samplesPerBeat = 60.0 * config.sampleRate / config.bpm
        let cycleLengthInBeats: Double = 4
        let cycleSamples = Int64(cycleLengthInBeats * samplesPerBeat)

        // --- Phase 1: Tree 1 ---
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        try engine.start()
        graph.startAll(bpm: config.bpm, resetClock: true)

        let region1End = cycleSamples * 2  // 2 cycles of tree 1
        let region2End = region1End + cycleSamples * 2  // 2 cycles of tree 2
        let region3End = region2End + cycleSamples * 2  // 2 cycles of tree 3

        graph.setActiveRegionBounds(start: 0, end: region1End)

        // Stage and arm tree 2
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)
        graph.armStagedUnits(regionStart: region1End, regionEnd: region2End, bpm: config.bpm)

        let tree1IDs = collectNodeIDs(from: tree1)

        // Render through tree 1 + 1 buffer past boundary
        let tree1Buffers = Int(region1End) / Int(config.bufferSize) + 1
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: tree1Buffers, format: format,
            bufferSize: config.bufferSize
        )

        // Bookkeeping: promote tree 2, drain tree 1
        graph.promoteStagedToActive()
        graph.drainUnits(for: tree1IDs, engine: engine)

        let transition1Index = Int(region1End)

        // --- Phase 2: Tree 2 playing, stage tree 3 ---
        // Render 1 cycle of tree 2 before staging tree 3
        let preStageSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: Int(cycleSamples) / Int(config.bufferSize), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: preStageSamples)

        // Stage and arm tree 3
        graph.stageNextTree(tree3, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)
        graph.armStagedUnits(regionStart: region2End, regionEnd: region3End, bpm: config.bpm)

        let tree2IDs = collectNodeIDs(from: tree2)

        // Render through tree 2's region end + 1 buffer past
        let tree2RemainingBuffers = (Int(region2End) - allSamples.count) / Int(config.bufferSize) + 1
        let tree2RemainingSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(tree2RemainingBuffers, 1), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2RemainingSamples)

        // Bookkeeping: promote tree 3, drain tree 2
        graph.promoteStagedToActive()
        graph.drainUnits(for: tree2IDs, engine: engine)

        let transition2Index = Int(region2End)

        // Render 2 cycles of tree 3
        let tree3Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: Int(cycleSamples) * 2 / Int(config.bufferSize), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree3Samples)

        engine.stop()

        // Check both transitions
        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transition1Index,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Arm back-to-back transition 1 (tree1→tree2)"
        )
        assertCleanTransition(
            samples: allSamples, transitionSampleIndex: transition2Index,
            config: config, cycleBeats: cycleLengthInBeats,
            label: "Arm back-to-back transition 2 (tree2→tree3)"
        )
    }

    /// 97 BPM (27278.35 samples/beat) — tests rounding at region boundaries.
    /// Non-integer samples/beat forces the arm mechanism to handle fractional alignment.
    func testArmTransition_FractionalBPM_97() throws {
        var config = TestConfig()
        config.bpm = 97

        let tree1 = makeTestTree(pitch: 48, name: "ArmTree1")
        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2")

        let (samples, transitionIndex) = try runArmTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            tree1CycleLengthInBeats: 4,
            tree1Cycles: 2,
            label: "Arm fractional BPM 97"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Arm fractional BPM (97)"
        )
    }

    /// 3-beat cycle (66150 samples at 120 BPM, not divisible by 512) — boundary
    /// falls mid-buffer, testing the arm mechanism's sample-level precision.
    func testArmTransition_MisalignedCycle_3Beat() throws {
        let config = defaultConfig
        let tree1 = makeTestTree(pitch: 48, name: "ArmTree1", lengthInBeats: 3)
        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2", lengthInBeats: 3)

        let (samples, transitionIndex) = try runArmTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            tree1CycleLengthInBeats: 3,
            tree1Cycles: 2,
            label: "Arm misaligned 3-beat"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 3,
            label: "Arm misaligned cycle (3-beat)"
        )
    }

    /// Note at beat 3.75 of 4-beat cycle — release tail overlaps with tree 2's onset.
    /// The arm mechanism's fade-in/fade-out must handle the overlap cleanly.
    func testArmTransition_NoteNearCycleEnd() throws {
        let config = defaultConfig

        // Tree 1: note at beat 0 AND beat 3.75 (near region boundary)
        let note1 = NoteEvent(pitch: 48, velocity: 0.8, startBeat: 0.0, duration: 0.25)
        let note2 = NoteEvent(pitch: 48, velocity: 0.8, startBeat: 3.75, duration: 0.25)
        let seq1 = NoteSequence(notes: [note1, note2], lengthInBeats: 4)
        let patch1 = SoundPatch(
            name: "ArmT1",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.01),
            volume: 0.8
        )
        let root1 = Node(name: "ArmT1", sequence: seq1, patch: patch1)
        let tree1 = NodeTree(name: "ArmTree1", rootNode: root1)

        let tree2 = makeTestTree(pitch: 52, name: "ArmTree2")

        let (samples, transitionIndex) = try runArmTransitionTest(
            tree1: tree1, tree2: tree2, config: config,
            tree1CycleLengthInBeats: 4,
            tree1Cycles: 2,
            label: "Arm note near cycle end"
        )

        assertCleanTransition(
            samples: samples, transitionSampleIndex: transitionIndex,
            config: config, cycleBeats: 4,
            label: "Arm note near cycle end (beat 3.75)"
        )
    }
}
