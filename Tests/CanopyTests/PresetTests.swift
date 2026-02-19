import XCTest
@testable import Canopy

final class PresetTests: XCTestCase {

    // MARK: - Built-in Presets

    func testAllBuiltInPresetsExist() {
        XCTAssertEqual(NodePreset.builtIn.count, 7)
        let ids = NodePreset.builtIn.map(\.id)
        XCTAssertTrue(ids.contains("melody"))
        XCTAssertTrue(ids.contains("bass"))
        XCTAssertTrue(ids.contains("drums"))
        XCTAssertTrue(ids.contains("pad"))
        XCTAssertTrue(ids.contains("arp"))
        XCTAssertTrue(ids.contains("west"))
        XCTAssertTrue(ids.contains("flow"))
    }

    func testMelodyPresetDefaults() {
        let preset = NodePreset.find("melody")!
        XCTAssertEqual(preset.name, "Melody")
        XCTAssertEqual(preset.color, .blue)
        XCTAssertEqual(preset.nodeType, .melodic)
        XCTAssertEqual(preset.defaultLengthInBeats, 4)
        XCTAssertEqual(preset.defaultPitchRange.low, 60)
        XCTAssertEqual(preset.defaultPitchRange.high, 84)
        if case .oscillator(let config) = preset.defaultPatch.soundType {
            XCTAssertEqual(config.waveform, .sawtooth)
        } else {
            XCTFail("Melody preset should use oscillator")
        }
        XCTAssertTrue(preset.defaultPatch.filter.enabled)
        XCTAssertEqual(preset.defaultPatch.filter.cutoff, 4000)
    }

    func testBassPresetDefaults() {
        let preset = NodePreset.find("bass")!
        XCTAssertEqual(preset.name, "Bass")
        XCTAssertEqual(preset.color, .purple)
        XCTAssertEqual(preset.nodeType, .harmonic)
        if case .oscillator(let config) = preset.defaultPatch.soundType {
            XCTAssertEqual(config.waveform, .square)
        } else {
            XCTFail("Bass preset should use oscillator")
        }
        XCTAssertEqual(preset.defaultPatch.filter.cutoff, 800)
    }

    func testDrumsPresetDefaults() {
        let preset = NodePreset.find("drums")!
        XCTAssertEqual(preset.name, "Drums")
        XCTAssertEqual(preset.color, .orange)
        XCTAssertEqual(preset.nodeType, .rhythmic)
    }

    func testPadPresetDefaults() {
        let preset = NodePreset.find("pad")!
        XCTAssertEqual(preset.color, .green)
        XCTAssertEqual(preset.defaultLengthInBeats, 8)
        XCTAssertEqual(preset.defaultPatch.envelope.attack, 0.8, accuracy: 0.01)
    }

    func testArpPresetDefaults() {
        let preset = NodePreset.find("arp")!
        XCTAssertEqual(preset.color, .cyan)
        if case .oscillator(let config) = preset.defaultPatch.soundType {
            XCTAssertEqual(config.waveform, .triangle)
        } else {
            XCTFail("Arp preset should use oscillator")
        }
    }

    func testFindUnknownPresetReturnsNil() {
        XCTAssertNil(NodePreset.find("nonexistent"))
    }

    // MARK: - Node Created from Preset

    func testNodeFromPresetHasCorrectProperties() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        state.selectNode(rootID)

        let preset = NodePreset.find("melody")!
        let node = state.addChildNode(to: rootID, preset: preset)

        XCTAssertEqual(node.name, "Melody")
        XCTAssertEqual(node.type, .melodic)
        XCTAssertEqual(node.presetID, "melody")
        XCTAssertEqual(node.sequence.lengthInBeats, 4)
        XCTAssertEqual(node.sequence.pitchRange?.low, 60)
        XCTAssertEqual(node.sequence.pitchRange?.high, 84)
        if case .oscillator(let config) = node.patch.soundType {
            XCTAssertEqual(config.waveform, .sawtooth)
        } else {
            XCTFail("Node from melody preset should use sawtooth oscillator")
        }
    }

    func testNodeFromBassPreset() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        state.selectNode(rootID)

        let preset = NodePreset.find("bass")!
        let node = state.addChildNode(to: rootID, preset: preset)

        XCTAssertEqual(node.name, "Bass")
        XCTAssertEqual(node.type, .harmonic)
        XCTAssertEqual(node.presetID, "bass")
        XCTAssertTrue(node.patch.filter.enabled)
        XCTAssertEqual(node.patch.filter.cutoff, 800)
    }

    // MARK: - Codable Round-Trips

    func testNodeWithPresetIDRoundTrip() throws {
        let node = Node(name: "Melody", type: .melodic, presetID: "melody")

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(node, decoded)
        XCTAssertEqual(decoded.presetID, "melody")
    }

    func testOldNodeWithoutPresetIDDecodesAsNil() throws {
        // Simulate old JSON without presetID field
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "Legacy",
            "type": "melodic",
            "key": { "root": "C", "mode": "minor" },
            "sequence": { "notes": [], "lengthInBeats": 4.0 },
            "patch": {
                "id": "00000000-0000-0000-0000-000000000002",
                "name": "Default",
                "soundType": { "oscillator": { "_0": { "waveform": "sine", "detune": 0, "pulseWidth": 0.5 } } },
                "envelope": { "attack": 0.01, "decay": 0.1, "sustain": 0.7, "release": 0.3 },
                "volume": 0.8,
                "pan": 0.0
            },
            "effects": [],
            "children": [],
            "position": { "x": 0, "y": 0 },
            "isMuted": false,
            "isSolo": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertNil(decoded.presetID, "Old JSON without presetID should decode as nil")
    }

    func testPresetColorRoundTrip() throws {
        for color in PresetColor.allCases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(PresetColor.self, from: data)
            XCTAssertEqual(color, decoded, "Failed round-trip for \(color)")
        }
    }
}
