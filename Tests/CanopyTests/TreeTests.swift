import XCTest
@testable import Canopy

final class TreeTests: XCTestCase {

    // MARK: - LCM / Cycle Length

    func testCycleLengthSingleNode() {
        let state = ProjectState()
        // Default seed node has 16-beat sequence
        XCTAssertEqual(state.cycleLengthInBeats(), 16)
    }

    func testCycleLengthTwoNodes() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // Add a child with 8-beat length
        let child = state.addChildNode(to: rootID)
        state.updateNode(id: child.id) { node in
            node.sequence.lengthInBeats = 8
        }

        // LCM(16, 8) = 16
        XCTAssertEqual(state.cycleLengthInBeats(), 16)
    }

    func testCycleLengthPolyrhythm3and4() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // Set root to 3 beats
        state.updateNode(id: rootID) { node in
            node.sequence.lengthInBeats = 3
        }

        // Add child with 4 beats
        let child = state.addChildNode(to: rootID)
        state.updateNode(id: child.id) { node in
            node.sequence.lengthInBeats = 4
        }

        // LCM(3, 4) = 12
        XCTAssertEqual(state.cycleLengthInBeats(), 12)
    }

    func testCycleLengthThreeNodes() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.updateNode(id: rootID) { $0.sequence.lengthInBeats = 3 }

        let child1 = state.addChildNode(to: rootID)
        state.updateNode(id: child1.id) { $0.sequence.lengthInBeats = 4 }

        let child2 = state.addChildNode(to: rootID)
        state.updateNode(id: child2.id) { $0.sequence.lengthInBeats = 5 }

        // LCM(3, 4, 5) = 60
        XCTAssertEqual(state.cycleLengthInBeats(), 60)
    }

    func testCycleLengthSameLengths() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.updateNode(id: rootID) { $0.sequence.lengthInBeats = 4 }

        let child = state.addChildNode(to: rootID)
        state.updateNode(id: child.id) { $0.sequence.lengthInBeats = 4 }

        // LCM(4, 4) = 4
        XCTAssertEqual(state.cycleLengthInBeats(), 4)
    }

    // MARK: - Tree Layout

    func testSingleNodePosition() {
        let state = ProjectState()
        let root = state.project.trees[0].rootNode
        XCTAssertEqual(root.position.x, 0)
        XCTAssertEqual(root.position.y, 0)
    }

    func testOneChildLayout() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child = state.addChildNode(to: rootID)

        // Root should stay at origin
        let rootPos = state.project.trees[0].rootNode.position
        XCTAssertEqual(rootPos.x, 0)
        XCTAssertEqual(rootPos.y, 0)

        // Child should be below root
        let childNode = state.findNode(id: child.id)!
        XCTAssertEqual(childNode.position.x, 0)
        XCTAssertEqual(childNode.position.y, 150)
    }

    func testTwoChildrenSymmetric() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child1 = state.addChildNode(to: rootID)
        let child2 = state.addChildNode(to: rootID)

        let c1 = state.findNode(id: child1.id)!
        let c2 = state.findNode(id: child2.id)!

        // Should be symmetric about x=0
        XCTAssertEqual(c1.position.x, -60, accuracy: 0.01)
        XCTAssertEqual(c2.position.x, 60, accuracy: 0.01)
        XCTAssertEqual(c1.position.y, 150)
        XCTAssertEqual(c2.position.y, 150)
    }

    func testThreeChildrenLayout() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child1 = state.addChildNode(to: rootID)
        let child2 = state.addChildNode(to: rootID)
        let child3 = state.addChildNode(to: rootID)

        let c1 = state.findNode(id: child1.id)!
        let c2 = state.findNode(id: child2.id)!
        let c3 = state.findNode(id: child3.id)!

        XCTAssertEqual(c1.position.x, -120, accuracy: 0.01)
        XCTAssertEqual(c2.position.x, 0, accuracy: 0.01)
        XCTAssertEqual(c3.position.x, 120, accuracy: 0.01)
    }

    func testFiveChildrenLayout() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        for _ in 0..<5 {
            state.addChildNode(to: rootID)
        }

        let children = state.project.trees[0].rootNode.children
        XCTAssertEqual(children.count, 5)

        // Should be symmetric
        XCTAssertEqual(children[0].position.x, -240, accuracy: 0.01)
        XCTAssertEqual(children[1].position.x, -120, accuracy: 0.01)
        XCTAssertEqual(children[2].position.x, 0, accuracy: 0.01)
        XCTAssertEqual(children[3].position.x, 120, accuracy: 0.01)
        XCTAssertEqual(children[4].position.x, 240, accuracy: 0.01)
    }

    // MARK: - Add / Remove Node

    func testAddChildNode() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let initialCount = state.allNodes().count

        let child = state.addChildNode(to: rootID)

        XCTAssertEqual(state.allNodes().count, initialCount + 1)
        XCTAssertNotNil(state.findNode(id: child.id))
        XCTAssertEqual(child.type, .melodic)
        XCTAssertTrue(state.isDirty)
    }

    func testAddChildWithType() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        let child = state.addChildNode(to: rootID, type: .rhythmic)
        XCTAssertEqual(child.type, .rhythmic)
        XCTAssertEqual(child.name, "Rhythm")
    }

    func testRemoveNode() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child = state.addChildNode(to: rootID)

        state.removeNode(id: child.id)

        XCTAssertNil(state.findNode(id: child.id))
        XCTAssertEqual(state.allNodes().count, 1) // Just root
    }

    func testCannotRemoveRoot() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        state.removeNode(id: rootID)

        // Root should still exist
        XCTAssertNotNil(state.findNode(id: rootID))
    }

    func testAllNodesFlattened() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        state.addChildNode(to: rootID)
        state.addChildNode(to: rootID)

        XCTAssertEqual(state.allNodes().count, 3)
    }

    // MARK: - Codable Round-Trip

    func testNodeWithChildrenCodableRoundTrip() throws {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // Build a tree
        let child1 = state.addChildNode(to: rootID, type: .melodic)
        let child2 = state.addChildNode(to: rootID, type: .rhythmic)
        state.updateNode(id: child1.id) { node in
            node.sequence.lengthInBeats = 6
            node.sequence.notes = [NoteEvent(pitch: 60, startBeat: 0)]
        }
        state.updateNode(id: child2.id) { node in
            node.sequence.lengthInBeats = 4
            node.patch.soundType = .oscillator(OscillatorConfig(waveform: .sawtooth))
        }

        // Encode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(state.project)

        // Decode
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        // Verify tree structure
        let decodedRoot = decoded.trees[0].rootNode
        XCTAssertEqual(decodedRoot.children.count, 2)
        XCTAssertEqual(decodedRoot.children[0].type, .melodic)
        XCTAssertEqual(decodedRoot.children[0].sequence.lengthInBeats, 6)
        XCTAssertEqual(decodedRoot.children[0].sequence.notes.count, 1)
        XCTAssertEqual(decodedRoot.children[1].type, .rhythmic)
        XCTAssertEqual(decodedRoot.children[1].sequence.lengthInBeats, 4)

        if case .oscillator(let config) = decodedRoot.children[1].patch.soundType {
            XCTAssertEqual(config.waveform, .sawtooth)
        } else {
            XCTFail("Expected oscillator patch")
        }
    }

    func testChildSequenceDefaultLength() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child = state.addChildNode(to: rootID)

        // Default child sequence length should be 8
        XCTAssertEqual(child.sequence.lengthInBeats, 8)
    }
}
