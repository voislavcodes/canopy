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
}
