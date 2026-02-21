import XCTest
@testable import Canopy

final class QuakeModelTests: XCTestCase {

    // MARK: - QuakeConfig Codable

    func testQuakeConfigCodableRoundTrip() throws {
        var config = QuakeConfig()
        config.voices[0] = QuakeVoiceSlot(mass: 0.7, surface: 0.4, force: 0.8, sustain: 0.6)
        config.voices[1] = QuakeVoiceSlot(mass: 0.2, surface: 0.9, force: 0.1, sustain: 0.5)
        config.volume = 0.9
        config.pan = -0.3
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(QuakeConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testQuakeConfigDefaultValues() {
        let config = QuakeConfig()
        XCTAssertEqual(config.voices.count, 8)
        XCTAssertEqual(config.voices[0].mass, 0.5)
        XCTAssertEqual(config.voices[0].surface, 0.3)
        XCTAssertEqual(config.voices[0].force, 0.5)
        XCTAssertEqual(config.voices[0].sustain, 0.3)
        XCTAssertEqual(config.volume, 0.8)
        XCTAssertEqual(config.pan, 0.0)
    }

    func testQuakeConfigPerVoiceIndependence() {
        var config = QuakeConfig()
        config.voices[0] = QuakeVoiceSlot(mass: 0.9, surface: 0.1, force: 0.9, sustain: 0.1)
        config.voices[1] = QuakeVoiceSlot(mass: 0.1, surface: 0.9, force: 0.1, sustain: 0.9)
        XCTAssertNotEqual(config.voices[0], config.voices[1])
        // Other voices should still be defaults
        XCTAssertEqual(config.voices[2].mass, 0.5)
    }

    func testQuakeConfigBackwardCompat() throws {
        // Legacy shared-control format (old JSON without voices array)
        let json = """
        {"mass":0.7,"surface":0.4,"force":0.8,"sustain":0.6}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QuakeConfig.self, from: data)
        XCTAssertEqual(decoded.voices.count, 8)
        // All voices should have the shared values
        for v in decoded.voices {
            XCTAssertEqual(v.mass, 0.7)
            XCTAssertEqual(v.surface, 0.4)
            XCTAssertEqual(v.force, 0.8)
            XCTAssertEqual(v.sustain, 0.6)
        }
        XCTAssertEqual(decoded.volume, 0.8, "Volume should default to 0.8")
        XCTAssertEqual(decoded.pan, 0.0, "Pan should default to 0.0")
    }

    func testQuakePresetSeeds() {
        let presets: [QuakeConfig] = [
            .cleanKit, .eightOhEight, .industrial, .glassy, .tribal,
            .machine, .gamelan, .thunder, .whisper, .droneKit
        ]
        XCTAssertEqual(presets.count, 10)
        for preset in presets {
            XCTAssertEqual(preset.voices.count, 8)
            for voice in preset.voices {
                XCTAssertGreaterThanOrEqual(voice.mass, 0)
                XCTAssertLessThanOrEqual(voice.mass, 1)
                XCTAssertGreaterThanOrEqual(voice.force, 0)
                XCTAssertLessThanOrEqual(voice.force, 1)
            }
        }
    }

    // MARK: - QuakeVoiceSlot Codable

    func testQuakeVoiceSlotCodableRoundTrip() throws {
        let slot = QuakeVoiceSlot(mass: 0.8, surface: 0.6, force: 0.4, sustain: 0.2)
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(QuakeVoiceSlot.self, from: data)
        XCTAssertEqual(decoded, slot)
    }

    // MARK: - OrbitConfig Codable

    func testOrbitConfigCodableRoundTrip() throws {
        let config = OrbitConfig(gravity: 0.5, bodyCount: 5, tension: 0.7, density: 0.8)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OrbitConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testOrbitConfigDefaultValues() {
        let config = OrbitConfig()
        XCTAssertEqual(config.gravity, 0.3)
        XCTAssertEqual(config.bodyCount, 4)
        XCTAssertEqual(config.tension, 0.0)
        XCTAssertEqual(config.density, 0.5)
    }

    func testOrbitConfigBodyCountClamped() {
        let low = OrbitConfig(bodyCount: 0)
        XCTAssertEqual(low.bodyCount, 2, "Body count should clamp to minimum 2")

        let high = OrbitConfig(bodyCount: 10)
        XCTAssertEqual(high.bodyCount, 6, "Body count should clamp to maximum 6")

        let normal = OrbitConfig(bodyCount: 4)
        XCTAssertEqual(normal.bodyCount, 4)
    }

    func testOrbitPresetSeeds() {
        let presets: [OrbitConfig] = [
            .metronome, .pocket, .poly, .elastic, .dense,
            .sparse, .reich, .chaos, .ritual, .drift
        ]
        XCTAssertEqual(presets.count, 10)
        for preset in presets {
            XCTAssertGreaterThanOrEqual(preset.bodyCount, 2)
            XCTAssertLessThanOrEqual(preset.bodyCount, 6)
        }
    }

    // MARK: - SoundType.quake Codable

    func testSoundTypeQuakeCodableRoundTrip() throws {
        let soundType = SoundType.quake(QuakeConfig())
        let data = try JSONEncoder().encode(soundType)
        let decoded = try JSONDecoder().decode(SoundType.self, from: data)
        XCTAssertEqual(decoded, soundType)
    }

    // MARK: - Node with OrbitConfig

    func testNodeWithOrbitConfigCodableRoundTrip() throws {
        var node = Node()
        node.orbitConfig = OrbitConfig(gravity: 0.5, bodyCount: 3, tension: 0.2, density: 0.6)
        node.sequencerType = .orbit

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(decoded.sequencerType, .orbit)
        XCTAssertEqual(decoded.orbitConfig?.gravity, 0.5)
        XCTAssertEqual(decoded.orbitConfig?.bodyCount, 3)
    }

    func testNodeWithoutOrbitConfigBackwardCompat() throws {
        // Old node JSON without orbitConfig field
        var node = Node()
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        XCTAssertNil(decoded.orbitConfig, "orbitConfig should be nil for legacy nodes")
    }

    // MARK: - SequencerType.orbit

    func testSequencerTypeOrbitCodable() throws {
        let type = SequencerType.orbit
        let data = try JSONEncoder().encode(type)
        let decoded = try JSONDecoder().decode(SequencerType.self, from: data)
        XCTAssertEqual(decoded, .orbit)
    }
}
