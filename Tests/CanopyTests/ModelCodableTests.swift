import XCTest
@testable import Canopy

final class ModelCodableTests: XCTestCase {
    func testFullProjectRoundTrip() throws {
        let project = ProjectFactory.newProject()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertEqual(project, decoded)
    }

    func testNodeWithChildrenRoundTrip() throws {
        var parent = Node(name: "Parent", type: .group)
        let child1 = Node(name: "Child 1", type: .melodic, position: NodePosition(x: 100, y: 50))
        let child2 = Node(name: "Child 2", type: .rhythmic, position: NodePosition(x: -100, y: 50))
        parent.children = [child1, child2]

        let data = try JSONEncoder().encode(parent)
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(parent, decoded)
        XCTAssertEqual(decoded.children.count, 2)
        XCTAssertEqual(decoded.children[0].name, "Child 1")
    }

    func testSoundTypeOscillatorRoundTrip() throws {
        let patch = SoundPatch(
            name: "Test Saw",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth, detune: 5.0)),
            volume: 0.6
        )

        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(SoundPatch.self, from: data)

        XCTAssertEqual(patch, decoded)
    }

    func testEffectRoundTrip() throws {
        let effect = Effect(
            type: .delay,
            mix: 0.4,
            parameters: ["time": 0.25, "feedback": 0.5]
        )

        let data = try JSONEncoder().encode(effect)
        let decoded = try JSONDecoder().decode(Effect.self, from: data)

        XCTAssertEqual(effect, decoded)
    }

    func testMusicalKeyRoundTrip() throws {
        let key = MusicalKey(root: .Fs, mode: .dorian)

        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(MusicalKey.self, from: data)

        XCTAssertEqual(key, decoded)
    }

    // MARK: - New Fields Round-Trip

    func testNoteEventWithProbabilityRoundTrip() throws {
        let event = NoteEvent(pitch: 60, velocity: 0.7, startBeat: 2.0, duration: 0.5,
                              probability: 0.6, ratchetCount: 3)

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)

        XCTAssertEqual(event, decoded)
        XCTAssertEqual(decoded.probability, 0.6)
        XCTAssertEqual(decoded.ratchetCount, 3)
    }

    func testNoteSequenceWithAllFieldsRoundTrip() throws {
        let seq = NoteSequence(
            notes: [NoteEvent(pitch: 60, startBeat: 0)],
            lengthInBeats: 8,
            globalProbability: 0.75,
            euclidean: EuclideanConfig(pulses: 5, rotation: 1),
            pitchRange: PitchRange(low: 48, high: 84),
            playbackDirection: .pingPong,
            mutation: MutationConfig(amount: 0.2, range: 3),
            accumulator: AccumulatorConfig(target: .velocity, amount: 1.5, limit: 24, mode: .wrap)
        )

        let data = try JSONEncoder().encode(seq)
        let decoded = try JSONDecoder().decode(NoteSequence.self, from: data)

        XCTAssertEqual(seq, decoded)
        XCTAssertEqual(decoded.globalProbability, 0.75)
        XCTAssertEqual(decoded.euclidean?.pulses, 5)
        XCTAssertEqual(decoded.playbackDirection, .pingPong)
        XCTAssertEqual(decoded.mutation?.amount, 0.2)
        XCTAssertEqual(decoded.accumulator?.mode, .wrap)
    }

    func testNodeWithScaleOverrideRoundTrip() throws {
        let node = Node(name: "Test", scaleOverride: MusicalKey(root: .Fs, mode: .lydian))

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(node, decoded)
        XCTAssertEqual(decoded.scaleOverride?.root, .Fs)
        XCTAssertEqual(decoded.scaleOverride?.mode, .lydian)
    }

    func testNodeTreeWithScaleRoundTrip() throws {
        let tree = NodeTree(name: "Test Tree", scale: MusicalKey(root: .D, mode: .dorian))

        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(NodeTree.self, from: data)

        XCTAssertEqual(tree, decoded)
        XCTAssertEqual(decoded.scale?.root, .D)
    }

    // MARK: - Backward Compatibility

    func testOldNoteEventDecodesWithDefaults() throws {
        // Simulate old JSON without probability/ratchetCount
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "pitch": 60,
            "velocity": 0.8,
            "startBeat": 0.0,
            "duration": 1.0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)

        XCTAssertEqual(decoded.pitch, 60)
        XCTAssertEqual(decoded.probability, 1.0, "Missing probability should default to 1.0")
        XCTAssertEqual(decoded.ratchetCount, 1, "Missing ratchetCount should default to 1")
    }

    func testOldNoteSequenceDecodesWithDefaults() throws {
        // Simulate old JSON without new fields
        let json = """
        {
            "notes": [],
            "lengthInBeats": 16.0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NoteSequence.self, from: data)

        XCTAssertEqual(decoded.globalProbability, 1.0)
        XCTAssertNil(decoded.euclidean)
        XCTAssertNil(decoded.pitchRange)
        XCTAssertNil(decoded.playbackDirection)
        XCTAssertNil(decoded.mutation)
        XCTAssertNil(decoded.accumulator)
    }

    func testOldNodeDecodesWithNilScaleOverride() throws {
        // Node encoded without scaleOverride field — should decode as nil
        var node = Node(name: "Legacy")
        // Encode with new format (scaleOverride will be nil)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        XCTAssertNil(decoded.scaleOverride)
    }

    func testOldNodeTreeDecodesWithNilScale() throws {
        let tree = NodeTree(name: "Legacy Tree")
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(NodeTree.self, from: data)
        XCTAssertNil(decoded.scale)
    }

    func testFilterConfigRoundTrip() throws {
        let patch = SoundPatch(
            name: "Filtered Saw",
            soundType: .oscillator(OscillatorConfig(waveform: .sawtooth)),
            filter: FilterConfig(enabled: true, cutoff: 1200.0, resonance: 0.7)
        )

        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(SoundPatch.self, from: data)

        XCTAssertEqual(patch, decoded)
        XCTAssertTrue(decoded.filter.enabled)
        XCTAssertEqual(decoded.filter.cutoff, 1200.0)
        XCTAssertEqual(decoded.filter.resonance, 0.7)
    }

    func testOldSoundPatchDecodesWithDefaultFilter() throws {
        // Simulate old JSON without "filter" key
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Legacy",
            "soundType": { "oscillator": { "_0": { "waveform": "sine", "detune": 0, "pulseWidth": 0.5 } } },
            "envelope": { "attack": 0.01, "decay": 0.1, "sustain": 0.7, "release": 0.3 },
            "volume": 0.8,
            "pan": 0.0
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SoundPatch.self, from: data)

        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertFalse(decoded.filter.enabled, "Missing filter should default to disabled")
        XCTAssertEqual(decoded.filter.cutoff, 8000.0, "Missing filter cutoff should default to 8000")
        XCTAssertEqual(decoded.filter.resonance, 0.0, "Missing filter resonance should default to 0")
    }

    // MARK: - LFO Modulation

    func testLFODefinitionRoundTrip() throws {
        let lfo = LFODefinition(
            name: "LFO 1",
            waveform: .sampleAndHold,
            rateHz: 3.5,
            phase: 0.25,
            enabled: true,
            colorIndex: 4
        )

        let data = try JSONEncoder().encode(lfo)
        let decoded = try JSONDecoder().decode(LFODefinition.self, from: data)

        XCTAssertEqual(lfo, decoded)
        XCTAssertEqual(decoded.waveform, .sampleAndHold)
        XCTAssertEqual(decoded.rateHz, 3.5)
        XCTAssertEqual(decoded.phase, 0.25)
        XCTAssertEqual(decoded.colorIndex, 4)
    }

    func testModulationRoutingRoundTrip() throws {
        let lfoID = UUID()
        let nodeID = UUID()
        let routing = ModulationRouting(
            lfoID: lfoID,
            nodeID: nodeID,
            parameter: .filterCutoff,
            depth: 0.75
        )

        let data = try JSONEncoder().encode(routing)
        let decoded = try JSONDecoder().decode(ModulationRouting.self, from: data)

        XCTAssertEqual(routing, decoded)
        XCTAssertEqual(decoded.lfoID, lfoID)
        XCTAssertEqual(decoded.parameter, .filterCutoff)
        XCTAssertEqual(decoded.depth, 0.75)
    }

    func testOldProjectDecodesWithEmptyModulation() throws {
        // Simulate old project JSON without lfos/modulationRoutings fields
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Old Project",
            "bpm": 120.0,
            "globalKey": { "root": "C", "mode": "minor" },
            "trees": [],
            "arrangements": [],
            "createdAt": 1700000000,
            "modifiedAt": 1700000000
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertEqual(decoded.name, "Old Project")
        XCTAssertEqual(decoded.lfos.count, 0, "Missing lfos should default to empty array")
        XCTAssertEqual(decoded.modulationRoutings.count, 0, "Missing modulationRoutings should default to empty array")
    }

    func testOldProjectDecodesWithScaleAwareDisabled() throws {
        // Simulate old project JSON without scaleAwareEnabled field
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Old Project",
            "bpm": 120.0,
            "globalKey": { "root": "C", "mode": "minor" },
            "trees": [],
            "arrangements": [],
            "createdAt": 1700000000,
            "modifiedAt": 1700000000
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertFalse(decoded.scaleAwareEnabled, "Missing scaleAwareEnabled should default to false")
    }

    func testScaleAwareEnabledRoundTrip() throws {
        var project = ProjectFactory.newProject()
        project.scaleAwareEnabled = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertTrue(decoded.scaleAwareEnabled)
    }

    func testNewScaleModesEncodeDecode() throws {
        let modes: [ScaleMode] = [.harmonicMinor, .melodicMinor, .phrygian, .lydian,
                                   .locrian, .pentatonicMajor, .pentatonicMinor, .wholeTone]
        for mode in modes {
            let key = MusicalKey(root: .C, mode: mode)
            let data = try JSONEncoder().encode(key)
            let decoded = try JSONDecoder().decode(MusicalKey.self, from: data)
            XCTAssertEqual(key, decoded, "Failed round-trip for \(mode)")
        }
    }
}
