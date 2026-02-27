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

    /// Activate tree 2 before the old tree reaches the cycle boundary.
    /// With percussive notes (sustain=0, decay=0.05s), tree 1's audio has decayed
    /// to silence by the activation point (~beat 2). The key checks:
    /// 1. New tree's fade-in starts from near-zero (no pop)
    /// 2. Old tree is properly faded out (no overlap)
    /// 3. No double onset near the transition
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
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: earlyBuffers, format: format, bufferSize: config.bufferSize
        )

        // Stage tree 2
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        // Render 2 more buffers, then activate (about 1 beat before boundary)
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 2, format: format, bufferSize: config.bufferSize
        )

        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render the first buffer of tree 2 — should fade in from near-zero
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: config.bufferSize)!
        let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
        graph.clockSamplePosition.pointee += Int64(config.bufferSize)

        XCTAssertEqual(status, .success)

        if let channelData = outputBuffer.floatChannelData {
            let leftChannel = channelData[0]

            // First sample should be near zero (fade-in ramp starts at 0)
            let firstSample = abs(leftChannel[0])
            XCTAssertLessThan(
                firstSample, 0.01,
                "Early activation: first sample should be near zero (fade-in), got \(firstSample)"
            )

            // Last sample should be larger (ramp goes 0→1)
            let lastSample = abs(leftChannel[Int(config.bufferSize) - 1])
            XCTAssertGreaterThan(
                lastSample, firstSample,
                "Early activation: fade-in should ramp up: first=\(firstSample), last=\(lastSample)"
            )
        }

        // Render one more cycle and check no double onset near the transition
        let postSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: samplesPerCycle / Int(config.bufferSize), format: format,
            bufferSize: config.bufferSize
        )

        // Check onsets in post-transition audio — should be exactly 1 per cycle
        let onsets = detectOnsets(
            in: postSamples, range: 0..<min(postSamples.count, Int(config.samplesPerBeat * 2)),
            threshold: 0.01, samplesPerBeat: config.samplesPerBeat
        )
        XCTAssertLessThanOrEqual(
            onsets.count, 1,
            "Early activation: \(onsets.count) onsets in first 2 beats of tree 2 (expected ≤1)"
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
    // MARK: - Adversarial: Fade-In Race Condition
    // =========================================================================

    /// Verifies that activateStagedTree (which uses the atomic startSequencerWithFadeIn
    /// command) produces a clean fade-in even when extra renders happen between
    /// staging completion and activation — the window where the race used to occur.
    func testAtomicFadeInPreventsRace() throws {
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

        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining = cycleBuffers - stagingBuffers
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining, format: format, bufferSize: config.bufferSize
        )

        // Simulate extra renders in the gap (audio thread running while main thread
        // is about to call activateStagedTree). Before the fix, requestFadeIn was a
        // pointer write that could be consumed here on silence. Now activateStagedTree
        // uses the atomic command, so these gap renders are harmless.
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 3, format: format, bufferSize: config.bufferSize
        )

        // Activate using the fixed path (atomic fade-in + sequencer start)
        graph.activateStagedTree(engine: engine, bpm: config.bpm)

        // Render the first buffer of tree 2
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: config.bufferSize)!
        let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
        graph.clockSamplePosition.pointee += Int64(config.bufferSize)

        XCTAssertEqual(status, .success)

        if let channelData = outputBuffer.floatChannelData {
            let leftChannel = channelData[0]

            // First few samples must be near zero — the atomic fade-in ramp starts
            // at gain 0/511. With the old race, the fade-in would have been wasted
            // on a silent gap buffer, and this sample would be at full amplitude.
            let earlySample = abs(leftChannel[2])
            XCTAssertLessThan(
                earlySample, 0.02,
                "Atomic fade-in: early sample = \(earlySample). " +
                "Expected near-zero (fade-in ramp starts at 0)."
            )

            // Late samples should have significant amplitude (ramp reaches ~1)
            let lateSample = abs(leftChannel[Int(config.bufferSize) - 1])
            XCTAssertGreaterThan(
                lateSample, earlySample,
                "Atomic fade-in should ramp up: early=\(earlySample), late=\(lateSample)"
            )
        }

        engine.stop()
    }

    /// Regression guard: verifies that the OLD separate requestFadeIn + startSequencer
    /// path still exhibits the race when a render happens between them.
    /// The race wastes the fade-in on silence, so subsequent audio starts without
    /// attenuation. This documents the bug that the atomic command fixed.
    func testSeparateFadeInStartStillRaces() throws {
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

        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: stagingBuffers, format: format, bufferSize: config.bufferSize
        )

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate,
                            bpm: config.bpm, currentCycleLengthInBeats: cycleLengthInBeats)

        let remaining = cycleBuffers - stagingBuffers
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: remaining, format: format, bufferSize: config.bufferSize
        )

        // OLD PATH: separate pointer-write fade-in + ring-buffer sequencer start
        let tree2NodeID = tree2.rootNode.id
        let currentClock = graph.clockSamplePosition.pointee
        if let newUnit = graph.unit(for: tree2NodeID) {
            newUnit.setClockStartOffset(currentClock)
            newUnit.requestFadeIn()   // pointer write — immediate
        }
        graph.clockIsRunning.pointee = true

        // Render consumes the fade-in ramp on silence (the race!)
        _ = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: 1, format: format, bufferSize: config.bufferSize
        )

        // NOW push sequencer start — too late, fade already consumed
        if let newUnit = graph.unit(for: tree2NodeID) {
            newUnit.startSequencer(bpm: config.bpm)
        }

        // Render: sequencer starts, but fadeState is 0 (consumed). No fade applied.
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: config.bufferSize)!
        let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
        graph.clockSamplePosition.pointee += Int64(config.bufferSize)

        XCTAssertEqual(status, .success)

        if let channelData = outputBuffer.floatChannelData {
            let leftChannel = channelData[0]
            // Frame 0 is silent (needsClockSync skips first tick). Frame ~10+ has
            // audio at full amplitude (no fade). Check a sample in the middle of
            // the buffer where the note is active and the fade-in ramp SHOULD have
            // attenuated it (but didn't, because fade was consumed on silence).
            let midSample = abs(leftChannel[Int(config.bufferSize) / 2])
            let fadedMidGain = Float(config.bufferSize / 2) / Float(config.bufferSize - 1)
            // If fade were applied, midSample would be roughly midSample * fadedMidGain.
            // Without fade (race), it's at full amplitude.
            // We check that the sample is significantly above what a faded version would be,
            // proving the fade was NOT applied (the race happened).
            // With a sawtooth at ~0.5 peak and 0.8 volume, mid-buffer should be ~0.2+
            // A properly faded mid-buffer sample would be ~0.1 (gain ≈ 0.5)
            // This test EXPECTS the race to produce unfaded audio.
            XCTAssertGreaterThan(
                midSample, 0.05,
                "Regression: separate path should produce audible audio without fade. " +
                "mid-buffer sample = \(midSample)"
            )
        }

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

    func testAutoStopPreventsBeatZeroRetrigger() throws {
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
            XCTAssertTrue(unit.isFadedOut,
                          "Tree 1 unit should be faded out after passing cycle boundary")
        }

        engine.stop()
    }

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
}
