import XCTest
import AVFoundation
@testable import Canopy

/// Headless tests for forest timeline playback across two trees.
///
/// Verifies:
/// 1. Note events fire in correct order without wrapping
///    (tree 1: beats 1,2,3,4 then tree 2: beats 1,2,3,4)
/// 2. No audio clicks at transitions or at any point during playback
///
/// Click detection uses both derivative analysis and per-sample scanning.
/// Tests cover adversarial conditions: small buffers, fractional BPMs,
/// sustained notes across boundaries, notes near the boundary, high volume.
final class ForestPlaybackTests: XCTestCase {

    // MARK: - Config

    struct TestConfig {
        var sampleRate: Double = 44100
        var bpm: Double = 120
        var bufferSize: AVAudioFrameCount = 512

        var samplesPerBeat: Double { 60.0 * sampleRate / bpm }
    }

    private let defaultConfig = TestConfig()

    // MARK: - Tree Builders

    /// 4 quarter notes at beats 0, 1, 2, 3.
    /// Each beat gets a distinct pitch (basePitch + beatIndex) for identification.
    private func makeFourBeatTree(
        basePitch: Int, name: String,
        waveform: Waveform = .sawtooth,
        envelope: EnvelopeConfig = EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.0, release: 0.01),
        volume: Double = 0.8,
        lengthInBeats: Double = 4
    ) -> NodeTree {
        let notes = (0..<Int(lengthInBeats)).map { i in
            NoteEvent(
                pitch: basePitch + i,
                velocity: 0.8,
                startBeat: Double(i),
                duration: 0.25
            )
        }
        let sequence = NoteSequence(notes: notes, lengthInBeats: lengthInBeats)
        let patch = SoundPatch(
            name: name,
            soundType: .oscillator(OscillatorConfig(waveform: waveform)),
            envelope: envelope,
            volume: volume
        )
        let root = Node(name: name, sequence: sequence, patch: patch)
        return NodeTree(name: name, rootNode: root)
    }

    /// Tree with a sustained note that rings across the full cycle.
    private func makeSustainedTree(pitch: Int, name: String, lengthInBeats: Double = 4) -> NodeTree {
        let note = NoteEvent(
            pitch: pitch,
            velocity: 1.0,
            startBeat: 0.0,
            duration: lengthInBeats  // note spans the entire cycle
        )
        let sequence = NoteSequence(notes: [note], lengthInBeats: lengthInBeats)
        let patch = SoundPatch(
            name: name,
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.01),
            volume: 1.0
        )
        let root = Node(name: name, sequence: sequence, patch: patch)
        return NodeTree(name: name, rootNode: root)
    }

    /// Tree with notes at each beat AND a note near the end of the cycle.
    private func makeLateNoteTree(
        pitch: Int, name: String,
        lastNoteBeat: Double = 3.875,
        lengthInBeats: Double = 4
    ) -> NodeTree {
        // Notes at every beat plus an extra note near the boundary
        var notes = (0..<Int(lengthInBeats)).map { i in
            NoteEvent(pitch: pitch + i, velocity: 0.8, startBeat: Double(i), duration: 0.25)
        }
        notes.append(NoteEvent(pitch: pitch + 7, velocity: 1.0, startBeat: lastNoteBeat, duration: 0.125))
        let sequence = NoteSequence(notes: notes, lengthInBeats: lengthInBeats)
        let patch = SoundPatch(
            name: name,
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            envelope: EnvelopeConfig(attack: 0.001, decay: 0.05, sustain: 0.5, release: 0.05),
            volume: 1.0
        )
        let root = Node(name: name, sequence: sequence, patch: patch)
        return NodeTree(name: name, rootNode: root)
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

    /// RMS energy of a window.
    private func rms(of samples: [Float], range: Range<Int>) -> Float {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return 0 }
        var sum: Float = 0
        for i in range { sum += samples[i] * samples[i] }
        return sqrt(sum / Float(range.count))
    }

    /// Detect onset events (amplitude crossing threshold after silence).
    private func detectOnsets(
        in samples: [Float], range: Range<Int>,
        threshold: Float, minGapSamples: Int
    ) -> [Int] {
        guard range.lowerBound >= 0, range.upperBound <= samples.count else { return [] }
        var onsets: [Int] = []
        var wasBelow = true
        for i in range {
            let amp = abs(samples[i])
            if amp > threshold {
                if wasBelow {
                    if let last = onsets.last, i - last < minGapSamples { /* too close */ }
                    else { onsets.append(i) }
                    wasBelow = false
                }
            } else {
                wasBelow = true
            }
        }
        return onsets
    }

    /// Render N buffers offline, advancing clock. Returns left-channel samples.
    private func renderSamples(
        engine: AVAudioEngine, graph: TreeAudioGraph,
        bufferCount: Int, format: AVAudioFormat,
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
                for i in 0..<Int(bufferSize) { samples.append(leftChannel[i]) }
            }
            graph.clockSamplePosition.pointee += Int64(bufferSize)
        }
        return samples
    }

    private func collectNodeIDs(from tree: NodeTree) -> [UUID] {
        var ids: [UUID] = []
        collectNodeIDsRecursive(from: tree.rootNode, into: &ids)
        return ids
    }

    private func collectNodeIDsRecursive(from node: Node, into ids: inout [UUID]) {
        ids.append(node.id)
        for child in node.children { collectNodeIDsRecursive(from: child, into: &ids) }
    }

    /// Max derivative from steady-state (second beat region).
    private func steadyStateMaxDerivative(in samples: [Float], config: TestConfig, cycleBeats: Double) -> Float {
        let start = Int(1.0 * config.samplesPerBeat)
        let end = min(Int(2.0 * config.samplesPerBeat), samples.count)
        guard start + 1 < end else { return 0.001 }
        return maxDerivative(in: samples, range: max(1, start)..<end)
    }

    // MARK: - Transition Runner

    /// Common arm-based transition: mirrors the production ForestPlaybackState flow.
    /// Returns (samples, transitionSampleIndex).
    private func runArmTransition(
        tree1: NodeTree, tree2: NodeTree,
        config: TestConfig,
        tree1CycleBeats: Double,
        tree2CycleBeats: Double? = nil,
        bookkeepingDelayBuffers: Int = 0,
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
        graph.startAll(bpm: config.bpm, resetClock: true)

        let samplesPerBeat = config.samplesPerBeat
        let region1End = Int64(tree1CycleBeats * samplesPerBeat)
        graph.setActiveRegionBounds(start: 0, end: region1End)

        let t2Cycle = tree2CycleBeats ?? tree1CycleBeats
        let t2CycleSamples = Int64(t2Cycle * samplesPerBeat)
        let region2End = region1End + t2CycleSamples * 2

        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)
        graph.armStagedUnits(regionStart: region1End, regionEnd: region2End, bpm: config.bpm)

        let tree1IDs = collectNodeIDs(from: tree1)

        // Render through tree 1's full region + 1 buffer past boundary
        let tree1Buffers = Int(region1End) / Int(config.bufferSize) + 1
        var allSamples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: tree1Buffers, format: format,
            bufferSize: config.bufferSize
        )

        // Optional bookkeeping delay (simulates main-thread lag)
        if bookkeepingDelayBuffers > 0 {
            let delaySamples = try renderSamples(
                engine: engine, graph: graph,
                bufferCount: bookkeepingDelayBuffers, format: format,
                bufferSize: config.bufferSize
            )
            allSamples.append(contentsOf: delaySamples)
        }

        // Bookkeeping: promote staged → active, drain old tree
        graph.promoteStagedToActive()
        graph.drainUnits(for: tree1IDs, engine: engine)

        // Render 2 cycles of tree 2
        let tree2Buffers = Int(t2CycleSamples) * 2 / Int(config.bufferSize)
        let tree2Samples = try renderSamples(
            engine: engine, graph: graph,
            bufferCount: max(tree2Buffers, 10), format: format,
            bufferSize: config.bufferSize
        )
        allSamples.append(contentsOf: tree2Samples)

        engine.stop()
        return (allSamples, Int(region1End))
    }

    /// Assert no clicks around a transition point AND across the full buffer.
    /// Uses a tight threshold: 2× steady-state derivative (not 3×).
    private func assertNoClicks(
        samples: [Float], transitionIndex: Int,
        config: TestConfig, cycleBeats: Double,
        label: String,
        derivMultiplier: Float = 2.0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let samplesPerBeat = config.samplesPerBeat
        let baselineDeriv = steadyStateMaxDerivative(in: samples, config: config, cycleBeats: cycleBeats)
        guard baselineDeriv > 0 else {
            XCTFail("\(label): No signal detected in steady state", file: file, line: line)
            return
        }

        let derivThreshold = max(baselineDeriv * derivMultiplier, 0.05)

        // --- PER-SAMPLE click scan in a ±1 beat window around transition ---
        let scanStart = max(1, transitionIndex - Int(samplesPerBeat))
        let scanEnd = min(samples.count, transitionIndex + Int(samplesPerBeat))

        var worstDeriv: Float = 0
        var worstPos = 0
        for i in scanStart..<scanEnd {
            let d = abs(samples[i] - samples[i - 1])
            if d > worstDeriv {
                worstDeriv = d
                worstPos = i
            }
        }

        XCTAssertLessThanOrEqual(
            worstDeriv, derivThreshold,
            "\(label): Click near transition at sample \(worstPos) " +
            "(beat \(String(format: "%.3f", Double(worstPos) / samplesPerBeat))): " +
            "derivative \(String(format: "%.5f", worstDeriv)) > \(derivMultiplier)× baseline (\(String(format: "%.5f", baselineDeriv)))",
            file: file, line: line
        )

        // --- Full buffer scan in 256-sample sliding windows ---
        let windowSize = 256
        var clickLocations: [(pos: Int, deriv: Float)] = []

        // All expected onset positions (±3ms tolerance)
        let onsetTolerance = Int(config.sampleRate * 0.003)
        var expectedOnsets: [Int] = []
        for beat in 0..<Int(cycleBeats) {
            expectedOnsets.append(Int(Double(beat) * samplesPerBeat))
        }
        // Tree 2 onsets
        for beat in 0..<Int(cycleBeats) {
            expectedOnsets.append(transitionIndex + Int(Double(beat) * samplesPerBeat))
        }

        var pos = 1
        while pos + windowSize <= samples.count {
            let windowDeriv = maxDerivative(in: samples, range: pos..<(pos + windowSize))
            if windowDeriv > derivThreshold {
                let nearOnset = expectedOnsets.contains { abs(pos - $0) < onsetTolerance }
                if !nearOnset {
                    clickLocations.append((pos: pos, deriv: windowDeriv))
                }
            }
            pos += windowSize / 2  // 50% overlap for better coverage
        }

        XCTAssertEqual(
            clickLocations.count, 0,
            "\(label): \(clickLocations.count) click(s) detected. " +
            "First 3: " + clickLocations.prefix(3).map {
                "sample \($0.pos) (beat \(String(format: "%.2f", Double($0.pos) / samplesPerBeat))) " +
                "deriv=\(String(format: "%.5f", $0.deriv))"
            }.joined(separator: "; "),
            file: file, line: line
        )
    }

    // =========================================================================
    // MARK: - Test 1: Note Event Ordering (Sequencer-Level)
    // =========================================================================

    /// Drives two region-gated sequencers sample-by-sample and verifies:
    /// - Tree 1 fires note-ons at beats 0, 1, 2, 3 (pitches 60–63)
    /// - Tree 2 fires note-ons at beats 0, 1, 2, 3 (pitches 72–75)
    /// - Exactly 8 note-ons total, no wrap-around re-triggers
    /// - All tree 1 events precede all tree 2 events
    func testNoteEventOrdering_NoWrapping() {
        let sampleRate = defaultConfig.sampleRate
        let bpm = defaultConfig.bpm
        let samplesPerBeat = defaultConfig.samplesPerBeat
        let beatsPerTree: Double = 4
        let samplesPerTree = Int64(beatsPerTree * samplesPerBeat)

        let events1 = (0..<4).map { i in
            SequencerEvent(pitch: 60 + i, velocity: 0.8,
                           startBeat: Double(i), endBeat: Double(i) + 0.25)
        }
        let events2 = (0..<4).map { i in
            SequencerEvent(pitch: 72 + i, velocity: 0.8,
                           startBeat: Double(i), endBeat: Double(i) + 0.25)
        }

        var seq1 = Sequencer()
        seq1.load(events: events1, lengthInBeats: beatsPerTree)
        seq1.bpm = bpm
        seq1.setRegion(start: 0, end: samplesPerTree)
        seq1.arm()

        var seq2 = Sequencer()
        seq2.load(events: events2, lengthInBeats: beatsPerTree)
        seq2.bpm = bpm
        seq2.setRegion(start: samplesPerTree, end: samplesPerTree * 2)
        seq2.arm()

        var voices1 = VoiceManager(voiceCount: 8)
        voices1.configurePatch(waveform: 0, detune: 0,
                               attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                               sampleRate: sampleRate)
        var voices2 = VoiceManager(voiceCount: 8)
        voices2.configurePatch(waveform: 0, detune: 0,
                               attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001,
                               sampleRate: sampleRate)

        struct NoteOnRecord { let sample: Int64; let pitch: Int }
        var noteOns: [NoteOnRecord] = []
        var prevPitches1 = voices1.voicePitches
        var prevPitches2 = voices2.voicePitches

        let totalSamples = samplesPerTree * 2 + 100
        for sample in 0..<totalSamples {
            seq1.tick(globalSample: sample, sampleRate: sampleRate, receiver: &voices1, detune: 0)
            seq2.tick(globalSample: sample, sampleRate: sampleRate, receiver: &voices2, detune: 0)

            for v in 0..<voices1.voiceCount {
                let cur = voices1.voicePitches[v]
                if cur != prevPitches1[v] && cur >= 0 && voices1.voices[v].isActive {
                    noteOns.append(NoteOnRecord(sample: sample, pitch: cur))
                }
            }
            prevPitches1 = voices1.voicePitches

            for v in 0..<voices2.voiceCount {
                let cur = voices2.voicePitches[v]
                if cur != prevPitches2[v] && cur >= 0 && voices2.voices[v].isActive {
                    noteOns.append(NoteOnRecord(sample: sample, pitch: cur))
                }
            }
            prevPitches2 = voices2.voicePitches
        }

        XCTAssertEqual(noteOns.count, 8,
                       "Expected 8 note-ons, got \(noteOns.count). Pitches: \(noteOns.map { $0.pitch })")

        let tree1Notes = noteOns.filter { $0.pitch >= 60 && $0.pitch <= 63 }
        let tree2Notes = noteOns.filter { $0.pitch >= 72 && $0.pitch <= 75 }

        XCTAssertEqual(tree1Notes.count, 4, "Tree 1 should fire 4 events")
        XCTAssertEqual(tree2Notes.count, 4, "Tree 2 should fire 4 events")

        for i in 0..<min(tree1Notes.count, 4) {
            XCTAssertEqual(tree1Notes[i].pitch, 60 + i,
                           "Tree 1 beat \(i): expected pitch \(60 + i), got \(tree1Notes[i].pitch)")
        }
        for i in 0..<min(tree2Notes.count, 4) {
            XCTAssertEqual(tree2Notes[i].pitch, 72 + i,
                           "Tree 2 beat \(i): expected pitch \(72 + i), got \(tree2Notes[i].pitch)")
        }

        if let lastT1 = tree1Notes.last, let firstT2 = tree2Notes.first {
            XCTAssertLessThan(lastT1.sample, firstT2.sample,
                              "Tree 1 last (sample \(lastT1.sample)) must precede tree 2 first (sample \(firstT2.sample))")
        }

        let tolerance: Int64 = 2
        for i in 0..<min(tree1Notes.count, 4) {
            let expected = Int64(Double(i) * samplesPerBeat)
            XCTAssertTrue(abs(tree1Notes[i].sample - expected) <= tolerance,
                          "Tree 1 beat \(i): expected ~\(expected), got \(tree1Notes[i].sample)")
        }
        for i in 0..<min(tree2Notes.count, 4) {
            let expected = samplesPerTree + Int64(Double(i) * samplesPerBeat)
            XCTAssertTrue(abs(tree2Notes[i].sample - expected) <= tolerance,
                          "Tree 2 beat \(i): expected ~\(expected), got \(tree2Notes[i].sample)")
        }
    }

    // =========================================================================
    // MARK: - Test 2: Baseline — Standard 4-Beat Trees, 512 Buffer
    // =========================================================================

    func testForestPlayback_Baseline_NoClicks() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "Baseline"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "Baseline 512")
    }

    // =========================================================================
    // MARK: - Test 3: Sustained Note Across Boundary
    // =========================================================================

    /// Tree 1 has a note with sustain=1.0 spanning the entire 4-beat cycle.
    /// At the transition, this note is at full amplitude — the region auto-stop
    /// must fade it cleanly without a click.
    func testSustainedNote_AcrossBoundary() throws {
        let tree1 = makeSustainedTree(pitch: 48, name: "Sustained")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "Sustained"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "Sustained across boundary")
    }

    // =========================================================================
    // MARK: - Test 4: Note Near Boundary (beat 3.875)
    // =========================================================================

    /// Tree 1 has a note at beat 3.875 — only 0.125 beats (27ms at 120 BPM)
    /// before the transition. The note is still in its attack/sustain when the
    /// region boundary hits.
    func testLateNote_NearBoundary() throws {
        let tree1 = makeLateNoteTree(pitch: 48, name: "LateNote")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "Late note"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "Note at beat 3.875")
    }

    // =========================================================================
    // MARK: - Test 5: Small Buffer Size (128 samples)
    // =========================================================================

    /// At 128 samples, the fade-in ramp is only ~2.9ms.
    /// Any click that relies on a longer fade to mask it will be exposed.
    func testSmallBuffer_128() throws {
        var config = TestConfig()
        config.bufferSize = 128

        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Buffer 128"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "Small buffer (128)")
    }

    // =========================================================================
    // MARK: - Test 6: Small Buffer Size (64 samples)
    // =========================================================================

    /// At 64 samples, the fade-in is only ~1.5ms.
    /// This is the most aggressive buffer size test.
    func testSmallBuffer_64() throws {
        var config = TestConfig()
        config.bufferSize = 64

        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Buffer 64"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "Small buffer (64)")
    }

    // =========================================================================
    // MARK: - Test 7: Fractional BPM — 97 BPM
    // =========================================================================

    /// At 97 BPM: samples/beat = 27278.35...
    /// Fractional, forces rounding at region boundaries. The transition
    /// sample lands mid-buffer at most buffer sizes.
    func testFractionalBPM_97() throws {
        var config = TestConfig()
        config.bpm = 97

        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "BPM 97"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "Fractional BPM (97)")
    }

    // =========================================================================
    // MARK: - Test 8: Fractional BPM + Small Buffer — Worst Case
    // =========================================================================

    /// 97 BPM + 128 buffer: non-integer samples/beat AND non-aligned boundary.
    func testWorstCase_FractionalBPM_SmallBuffer() throws {
        var config = TestConfig()
        config.bpm = 97
        config.bufferSize = 128

        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Worst case"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "97 BPM + 128 buffer")
    }

    // =========================================================================
    // MARK: - Test 9: 3-Beat Cycle (Misaligned Boundary)
    // =========================================================================

    /// 3-beat cycle at 120 BPM: 66150 samples, doesn't divide evenly by any
    /// common buffer size. Tests mid-buffer transition.
    func testMisalignedCycle_3Beat() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1", lengthInBeats: 3)
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2", lengthInBeats: 3)

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 3,
            tree2CycleBeats: 3,
            label: "3-beat cycle"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 3, label: "3-beat misaligned")
    }

    // =========================================================================
    // MARK: - Test 10: Full Volume + Sustained + Small Buffer
    // =========================================================================

    /// Combines the worst conditions: sustained note at full volume,
    /// 128-sample buffer. If there's a click anywhere, this finds it.
    func testAdversarial_SustainedFullVolume_SmallBuffer() throws {
        var config = TestConfig()
        config.bufferSize = 128

        let tree1 = makeSustainedTree(pitch: 48, name: "Sustained")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2", volume: 1.0)

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Adversarial sustained"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "Sustained + full vol + 128 buf")
    }

    // =========================================================================
    // MARK: - Test 11: Late Bookkeeping (Main Thread Lag)
    // =========================================================================

    /// Simulates ~50ms main-thread lag before drainUnits is called.
    /// Audio thread has already auto-started tree 2, but old tree's units
    /// are still connected and rendering (fading out via region auto-stop).
    func testLateBookkeeping_50ms() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        // 50ms ≈ 2205 samples ≈ ~4 buffers at 512
        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            bookkeepingDelayBuffers: 4,
            label: "Late bookkeeping 50ms"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "Late bookkeeping 50ms")
    }

    /// Simulates ~200ms main-thread lag.
    func testLateBookkeeping_200ms() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        // 200ms ≈ 8820 samples ≈ ~17 buffers
        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            bookkeepingDelayBuffers: 17,
            label: "Late bookkeeping 200ms"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "Late bookkeeping 200ms")
    }

    // =========================================================================
    // MARK: - Test 12: Different Cycle Lengths (4 beats → 3 beats)
    // =========================================================================

    /// Tree 1 is 4 beats, tree 2 is 3 beats. Different region sizes
    /// stress the arm/region boundary logic.
    func testDifferentCycleLengths_4to3() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1-4beat", lengthInBeats: 4)
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2-3beat", lengthInBeats: 3)

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            tree2CycleBeats: 3,
            label: "4→3 beat"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4, label: "4-beat → 3-beat transition")
    }

    // =========================================================================
    // MARK: - Test 13: Late Note + Small Buffer (Maximum Click Likelihood)
    // =========================================================================

    /// Note at beat 3.9375 (only 14ms before boundary at 120 BPM) + 64-sample
    /// buffer. The note is at peak amplitude when the boundary hits.
    func testLateNote_TinyBuffer() throws {
        var config = TestConfig()
        config.bufferSize = 64

        let tree1 = makeLateNoteTree(pitch: 48, name: "LateNote", lastNoteBeat: 3.9375)
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Late note + tiny buffer"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "Note 14ms before boundary + 64 buf")
    }

    // =========================================================================
    // MARK: - Test 14: High BPM (180) — Fast Transitions
    // =========================================================================

    /// At 180 BPM, beats are very short (14700 samples/beat).
    /// 4-beat cycle = 58800 samples = only 114 buffers at 512.
    func testHighBPM_180() throws {
        var config = TestConfig()
        config.bpm = 180

        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "180 BPM"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4, label: "180 BPM")
    }

    // =========================================================================
    // MARK: - Test 15: Onset Count Across Transition
    // =========================================================================

    /// Verifies exactly 4 onsets per tree and no spurious events at boundary.
    func testForestPlayback_CorrectOnsetCount() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "Onset count"
        )

        let samplesPerBeat = defaultConfig.samplesPerBeat
        let minGap = Int(samplesPerBeat * 0.5)

        let tree1Onsets = detectOnsets(in: samples, range: 0..<transIdx,
                                       threshold: 0.01, minGapSamples: minGap)
        let tree2End = min(transIdx + Int(4.0 * samplesPerBeat), samples.count)
        let tree2Onsets = detectOnsets(in: samples, range: transIdx..<tree2End,
                                       threshold: 0.01, minGapSamples: minGap)

        XCTAssertEqual(tree1Onsets.count, 4,
                       "Tree 1: expected 4 onsets, got \(tree1Onsets.count). " +
                       "Beats: \(tree1Onsets.map { String(format: "%.2f", Double($0) / samplesPerBeat) })")
        XCTAssertEqual(tree2Onsets.count, 4,
                       "Tree 2: expected 4 onsets, got \(tree2Onsets.count). " +
                       "Beats: \(tree2Onsets.map { String(format: "%.2f", Double($0 - transIdx) / samplesPerBeat) })")

        // No spurious onset between tree 1's last beat and the transition
        let gapStart = Int(3.5 * samplesPerBeat)
        let gapOnsets = detectOnsets(in: samples, range: gapStart..<transIdx,
                                     threshold: 0.01, minGapSamples: minGap)
        XCTAssertEqual(gapOnsets.count, 0,
                       "Spurious onsets in gap: \(gapOnsets.map { String(format: "%.2f", Double($0) / samplesPerBeat) })")
    }

    // =========================================================================
    // MARK: - Test 16: RMS Continuity — No Energy Spikes
    // =========================================================================

    func testForestPlayback_RMSContinuity() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1")
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2")

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "RMS"
        )

        let samplesPerBeat = defaultConfig.samplesPerBeat
        let windowSize = Int(samplesPerBeat * 0.2)

        // Measure steady-state RMS from beat 1
        let steadyStart = Int(1.0 * samplesPerBeat)
        let steadyRMS = rms(of: samples, range: steadyStart..<min(steadyStart + windowSize, samples.count))

        // Check no energy spike at transition (RMS < 3× steady)
        let transStart = max(0, transIdx - Int(defaultConfig.bufferSize))
        let transEnd = min(samples.count, transIdx + Int(defaultConfig.bufferSize))
        var pos = transStart
        while pos + windowSize <= transEnd {
            let windowRMS = rms(of: samples, range: pos..<(pos + windowSize))
            XCTAssertLessThanOrEqual(
                windowRMS, steadyRMS * 3.0,
                "RMS spike at sample \(pos): \(windowRMS) > 3× steady (\(steadyRMS))")
            pos += windowSize
        }

        // Verify each onset produces audible energy
        for beat in 0..<4 {
            let t2Start = transIdx + Int(Double(beat) * samplesPerBeat) + 10
            let t2End = min(t2Start + windowSize, samples.count)
            if t2Start < samples.count && t2End <= samples.count {
                let t2RMS = rms(of: samples, range: t2Start..<t2End)
                XCTAssertGreaterThan(t2RMS, 0.001,
                                     "Tree 2 beat \(beat): no audible signal, RMS = \(t2RMS)")
            }
        }
    }

    // =========================================================================
    // MARK: - Test 17: Sine Wave (No Natural Discontinuities)
    // =========================================================================

    /// Sine has no waveform-inherent discontinuities, making click detection
    /// much more sensitive. Any derivative spike IS a click.
    func testSineWave_MaxSensitivity() throws {
        let tree1 = makeFourBeatTree(basePitch: 48, name: "T1-sine", waveform: .sine,
                                      envelope: EnvelopeConfig(attack: 0.01, decay: 0.1, sustain: 0.5, release: 0.05),
                                      volume: 1.0)
        let tree2 = makeFourBeatTree(basePitch: 60, name: "T2-sine", waveform: .sine,
                                      envelope: EnvelopeConfig(attack: 0.01, decay: 0.1, sustain: 0.5, release: 0.05),
                                      volume: 1.0)

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: defaultConfig, tree1CycleBeats: 4,
            label: "Sine wave"
        )

        // Sine: use tighter threshold (1.5×) since no waveform edges
        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: defaultConfig, cycleBeats: 4,
                       label: "Sine wave (max sensitivity)", derivMultiplier: 1.5)
    }

    // =========================================================================
    // MARK: - Test 18: Sustained Sine + Small Buffer (Ultimate Click Detector)
    // =========================================================================

    /// Sustained sine at full volume + 64-sample buffer.
    /// This is the ultimate click detector: sine has no natural discontinuities,
    /// sustain keeps the signal at full level through the boundary, and the tiny
    /// buffer minimizes fade protection.
    func testUltimateClickDetector() throws {
        var config = TestConfig()
        config.bufferSize = 64

        let tree1 = NodeTree(name: "SustSine1", rootNode: Node(
            name: "SustSine1",
            sequence: NoteSequence(
                notes: [NoteEvent(pitch: 48, velocity: 1.0, startBeat: 0, duration: 4)],
                lengthInBeats: 4
            ),
            patch: SoundPatch(
                name: "SustSine1",
                soundType: .oscillator(OscillatorConfig(waveform: .sine)),
                envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001),
                volume: 1.0
            )
        ))
        let tree2 = NodeTree(name: "SustSine2", rootNode: Node(
            name: "SustSine2",
            sequence: NoteSequence(
                notes: [NoteEvent(pitch: 60, velocity: 1.0, startBeat: 0, duration: 4)],
                lengthInBeats: 4
            ),
            patch: SoundPatch(
                name: "SustSine2",
                soundType: .oscillator(OscillatorConfig(waveform: .sine)),
                envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.001),
                volume: 1.0
            )
        ))

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Ultimate"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4,
                       label: "Sustained sine + 64 buf (ultimate)", derivMultiplier: 1.5)
    }

    // =========================================================================
    // MARK: - Test 19: Combined Adversarial — 133 BPM, 3-Beat, 128 Buffer,
    //                   Late Note, Sustained Sine
    // =========================================================================

    func testCombinedAdversarial() throws {
        var config = TestConfig()
        config.bpm = 133
        config.bufferSize = 128

        // Tree 1: sustained sine, 3-beat cycle
        let tree1 = NodeTree(name: "Adv1", rootNode: Node(
            name: "Adv1",
            sequence: NoteSequence(
                notes: [
                    NoteEvent(pitch: 48, velocity: 1.0, startBeat: 0, duration: 3),
                    NoteEvent(pitch: 55, velocity: 1.0, startBeat: 2.875, duration: 0.125)
                ],
                lengthInBeats: 3
            ),
            patch: SoundPatch(
                name: "Adv1",
                soundType: .oscillator(OscillatorConfig(waveform: .sine)),
                envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.01),
                volume: 1.0
            )
        ))

        // Tree 2: normal 3-beat pattern
        let tree2 = makeFourBeatTree(basePitch: 60, name: "Adv2",
                                      waveform: .sine, volume: 1.0, lengthInBeats: 3)

        let (samples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 3, tree2CycleBeats: 3,
            label: "Combined adversarial"
        )

        assertNoClicks(samples: samples, transitionIndex: transIdx,
                       config: config, cycleBeats: 3,
                       label: "133BPM + 3-beat + 128buf + late note + sustained sine",
                       derivMultiplier: 1.5)
    }

    // =========================================================================
    // MARK: - Test 21: Full Production Path with MasterBusAU
    // =========================================================================

    /// Inserts MasterBusAU into the offline engine chain to reproduce the exact
    /// production signal path: source nodes → mainMixer → MasterBusAU → outputNode.
    /// MasterBusAU processes through Shore and advances the clock (no manual advance needed).
    func testFullProductionPath_WithMasterBusAU() throws {
        let config = TestConfig(sampleRate: 44100, bpm: 120, bufferSize: 512)

        let tree1 = makeSustainedTree(pitch: 48, name: "MBus1", lengthInBeats: 4)
        let tree2 = makeSustainedTree(pitch: 55, name: "MBus2", lengthInBeats: 4)

        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: config.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: config.bufferSize)

        let graph = TreeAudioGraph()
        graph.buildGraph(from: tree1, engine: engine, sampleRate: config.sampleRate)
        graph.configureAllPatches(from: tree1)
        graph.loadAllSequences(from: tree1, bpm: config.bpm)

        // Insert MasterBusAU into chain: mainMixer → MasterBusAU → outputNode
        MasterBusAU.register()
        var masterBusAVUnit: AVAudioUnit?
        let semaphore = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(with: MasterBusAU.masterBusDescription,
                                options: .loadInProcess) { avUnit, error in
            XCTAssertNil(error, "MasterBusAU instantiation failed: \(error?.localizedDescription ?? "")")
            masterBusAVUnit = avUnit
            semaphore.signal()
        }
        semaphore.wait()

        guard let avUnit = masterBusAVUnit else {
            XCTFail("MasterBusAU returned nil")
            return
        }

        engine.attach(avUnit)
        let mainMixer = engine.mainMixerNode
        let mixerFormat = mainMixer.outputFormat(forBus: 0)
        engine.disconnectNodeOutput(mainMixer)
        engine.connect(mainMixer, to: avUnit, format: mixerFormat)
        engine.connect(avUnit, to: engine.outputNode, format: mixerFormat)

        let masterBusAU = avUnit.auAudioUnit as! MasterBusAU
        masterBusAU.setClockPointers(samplePosition: graph.clockSamplePosition,
                                      isRunning: graph.clockIsRunning)

        try engine.start()
        graph.startAll(bpm: config.bpm, resetClock: true)

        let samplesPerBeat = config.samplesPerBeat
        let region1End = Int64(4 * samplesPerBeat)
        graph.setActiveRegionBounds(start: 0, end: region1End)

        let region2End = region1End + Int64(4 * samplesPerBeat) * 2
        graph.stageNextTree(tree2, engine: engine, sampleRate: config.sampleRate, bpm: config.bpm)
        graph.armStagedUnits(regionStart: region1End, regionEnd: region2End, bpm: config.bpm)

        let tree1IDs = collectNodeIDs(from: tree1)

        // Render: MasterBusAU advances clock, so NO manual clock advance
        let totalBuffers = Int(region1End) / Int(config.bufferSize) + 1
        var allSamples: [Float] = []
        allSamples.reserveCapacity((totalBuffers + 50) * Int(config.bufferSize))
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: config.bufferSize)!

        for _ in 0..<totalBuffers {
            let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
            guard status == .success else { break }
            if let ch = outputBuffer.floatChannelData {
                for i in 0..<Int(config.bufferSize) { allSamples.append(ch[0][i]) }
            }
            // Clock advanced by MasterBusAU — do NOT advance manually
        }

        // Bookkeeping: promote, drain
        graph.promoteStagedToActive()
        graph.drainUnits(for: tree1IDs, engine: engine)

        // Render tree 2
        let tree2Buffers = Int(4 * samplesPerBeat) * 2 / Int(config.bufferSize)
        for _ in 0..<max(tree2Buffers, 10) {
            let status = try engine.renderOffline(config.bufferSize, to: outputBuffer)
            guard status == .success else { break }
            if let ch = outputBuffer.floatChannelData {
                for i in 0..<Int(config.bufferSize) { allSamples.append(ch[0][i]) }
            }
        }

        engine.stop()

        // Shore adds 48-sample latency
        let transIdx = Int(region1End) + 48

        assertNoClicks(samples: allSamples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4,
                       label: "Full production path (MasterBusAU + Shore)", derivMultiplier: 2.0)
    }

    // =========================================================================
    // MARK: - Test 22: Shore Limiter Click Detection
    // =========================================================================

    /// Processes the clean transition audio through StereoShore.
    func testShore_ClickAtTransition() throws {
        let config = TestConfig(sampleRate: 44100, bpm: 120, bufferSize: 512)

        // Use sustained trees at high volume — maximizes Shore activity
        let tree1 = makeSustainedTree(pitch: 48, name: "Shore1", lengthInBeats: 4)
        let tree2 = makeSustainedTree(pitch: 55, name: "Shore2", lengthInBeats: 4)

        let (cleanSamples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Shore click test"
        )

        // Verify the clean samples pass (baseline)
        assertNoClicks(samples: cleanSamples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4,
                       label: "Shore baseline (no limiter)", derivMultiplier: 2.0)

        // Now process through Shore — simulating the production MasterBusAU path
        var shore = StereoShore(lookaheadSamples: 48, releaseMs: 100,
                                ceiling: 0.97, sampleRate: Float(config.sampleRate))

        var shoreSamples: [Float] = []
        shoreSamples.reserveCapacity(cleanSamples.count)
        for sample in cleanSamples {
            let (limitedL, _) = shore.process(left: sample, right: sample)
            shoreSamples.append(limitedL)
        }

        // Shore adds 48-sample latency, so adjust transition index
        let shoreTransIdx = transIdx + 48

        assertNoClicks(samples: shoreSamples, transitionIndex: shoreTransIdx,
                       config: config, cycleBeats: 4,
                       label: "Shore limiter (48-sample lookahead)", derivMultiplier: 2.0)
    }

    // =========================================================================
    // MARK: - Test 22: Shore with Gain Reduction State Carryover
    // =========================================================================

    /// Tests a worst-case scenario: tree 1 is loud (forcing Shore into heavy
    /// gain reduction), then tree 2 starts with different dynamics.
    /// The stale gain reduction + lookahead buffer is most likely to click here.
    func testShore_GainReductionCarryover() throws {
        let config = TestConfig(sampleRate: 44100, bpm: 120, bufferSize: 512)

        // Tree 1: loud sustained sine (will push Shore into limiting)
        let tree1 = makeSustainedTree(pitch: 48, name: "LoudSine", lengthInBeats: 4)
        // Tree 2: also loud but different pitch (different waveform interference)
        let tree2 = makeSustainedTree(pitch: 60, name: "LoudSine2", lengthInBeats: 4)

        let (cleanSamples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Shore gain carryover"
        )

        // Process through Shore with aggressive ceiling (forces heavy limiting)
        var shore = StereoShore(lookaheadSamples: 48, releaseMs: 100,
                                ceiling: 0.5, sampleRate: Float(config.sampleRate))

        var shoreSamples: [Float] = []
        for sample in cleanSamples {
            let (limitedL, _) = shore.process(left: sample, right: sample)
            shoreSamples.append(limitedL)
        }

        let shoreTransIdx = transIdx + 48

        // Use 2.5× multiplier — Shore can't add worse artifacts than 2.5× steady state
        assertNoClicks(samples: shoreSamples, transitionIndex: shoreTransIdx,
                       config: config, cycleBeats: 4,
                       label: "Shore gain reduction carryover (ceiling=0.5)",
                       derivMultiplier: 2.5)
    }

    // =========================================================================
    // MARK: - Test 23: Shore with Reset at Transition
    // =========================================================================

    /// Tests whether resetting Shore state at the transition fixes any click.
    /// If Test 21/22 fail but this passes, `resetShore()` at transition is the fix.
    func testShore_ResetAtTransition() throws {
        let config = TestConfig(sampleRate: 44100, bpm: 120, bufferSize: 512)

        let tree1 = makeSustainedTree(pitch: 48, name: "ResetShore1", lengthInBeats: 4)
        let tree2 = makeSustainedTree(pitch: 60, name: "ResetShore2", lengthInBeats: 4)

        let (cleanSamples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Shore reset test"
        )

        // Process through Shore, but reset it right at the transition
        var shore = StereoShore(lookaheadSamples: 48, releaseMs: 100,
                                ceiling: 0.5, sampleRate: Float(config.sampleRate))

        var shoreSamples: [Float] = []
        for (i, sample) in cleanSamples.enumerated() {
            if i == transIdx {
                shore.reset()  // Clear lookahead buffer and gain state
            }
            let (limitedL, _) = shore.process(left: sample, right: sample)
            shoreSamples.append(limitedL)
        }

        // After reset, there's a 48-sample silence (zeros in the lookahead buffer).
        // Use original transIdx since reset clears the delay.
        assertNoClicks(samples: shoreSamples, transitionIndex: transIdx,
                       config: config, cycleBeats: 4,
                       label: "Shore with reset at transition (ceiling=0.5)",
                       derivMultiplier: 2.5)
    }

    // =========================================================================
    // MARK: - Test 24: Shore with Sawtooth (Rich Harmonics)
    // =========================================================================

    /// Sawtooth waves have the richest harmonic content and highest peak-to-RMS
    /// ratio, making Shore work hardest. Combined with small buffer + high volume.
    func testShore_SawtoothHeavyLimiting() throws {
        let config = TestConfig(sampleRate: 44100, bpm: 120, bufferSize: 128)

        let tree1 = makeFourBeatTree(basePitch: 36, name: "ShoreSaw1",
                                      waveform: .sawtooth,
                                      envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.01),
                                      volume: 1.0)
        let tree2 = makeFourBeatTree(basePitch: 48, name: "ShoreSaw2",
                                      waveform: .sawtooth,
                                      envelope: EnvelopeConfig(attack: 0.001, decay: 0.01, sustain: 1.0, release: 0.01),
                                      volume: 1.0)

        let (cleanSamples, transIdx) = try runArmTransition(
            tree1: tree1, tree2: tree2,
            config: config, tree1CycleBeats: 4,
            label: "Shore sawtooth"
        )

        var shore = StereoShore(lookaheadSamples: 48, releaseMs: 100,
                                ceiling: 0.7, sampleRate: Float(config.sampleRate))

        var shoreSamples: [Float] = []
        for sample in cleanSamples {
            let (limitedL, _) = shore.process(left: sample, right: sample)
            shoreSamples.append(limitedL)
        }

        let shoreTransIdx = transIdx + 48
        assertNoClicks(samples: shoreSamples, transitionIndex: shoreTransIdx,
                       config: config, cycleBeats: 4,
                       label: "Shore sawtooth (ceiling=0.7, buf=128)",
                       derivMultiplier: 2.0)
    }
}
