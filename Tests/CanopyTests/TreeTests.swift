import XCTest
@testable import Canopy

final class TreeTests: XCTestCase {

    // MARK: - LCM / Cycle Length

    func testCycleLengthSingleNode() {
        let state = ProjectState()
        // Default seed node has 4-beat sequence (16 steps × 0.25)
        XCTAssertEqual(state.cycleLengthInBeats(), 4)
    }

    func testCycleLengthTwoNodes() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // Add a child — default 2-beat length (8 steps × 0.25)
        _ = state.addChildNode(to: rootID)

        // LCM(4, 2) in beats = LCM(16, 8) in steps * 0.25 = 4 beats
        XCTAssertEqual(state.cycleLengthInBeats(), 4)
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

        // Child should be above root
        let childNode = state.findNode(id: child.id)!
        XCTAssertEqual(childNode.position.x, 0)
        XCTAssertEqual(childNode.position.y, -160)
    }

    func testTwoChildrenSymmetric() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child1 = state.addChildNode(to: rootID)
        let child2 = state.addChildNode(to: rootID)

        let c1 = state.findNode(id: child1.id)!
        let c2 = state.findNode(id: child2.id)!

        // Should be symmetric about x=0
        XCTAssertEqual(c1.position.x, -70, accuracy: 0.01)
        XCTAssertEqual(c2.position.x, 70, accuracy: 0.01)
        XCTAssertEqual(c1.position.y, -160)
        XCTAssertEqual(c2.position.y, -160)
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

        XCTAssertEqual(c1.position.x, -140, accuracy: 0.01)
        XCTAssertEqual(c2.position.x, 0, accuracy: 0.01)
        XCTAssertEqual(c3.position.x, 140, accuracy: 0.01)
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
        XCTAssertEqual(children[0].position.x, -280, accuracy: 0.01)
        XCTAssertEqual(children[1].position.x, -140, accuracy: 0.01)
        XCTAssertEqual(children[2].position.x, 0, accuracy: 0.01)
        XCTAssertEqual(children[3].position.x, 140, accuracy: 0.01)
        XCTAssertEqual(children[4].position.x, 280, accuracy: 0.01)
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

        // Default child sequence length should be 2 beats (8 steps × 0.25)
        XCTAssertEqual(child.sequence.lengthInBeats, 2)
    }

    // MARK: - Upward Growth

    func testChildrenAboveParent() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child = state.addChildNode(to: rootID)

        let childNode = state.findNode(id: child.id)!
        // Children should have negative Y (above parent)
        XCTAssertTrue(childNode.position.y < 0, "Child should be above parent (negative Y)")
    }

    // MARK: - Subtree-Aware Spacing

    func testSubtreeAwareSpacing() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id

        // child1 will have 3 grandchildren, child2 is a leaf
        let child1 = state.addChildNode(to: rootID)
        let child2 = state.addChildNode(to: rootID)
        state.addChildNode(to: child1.id)
        state.addChildNode(to: child1.id)
        state.addChildNode(to: child1.id)

        let c1 = state.findNode(id: child1.id)!
        let c2 = state.findNode(id: child2.id)!

        // child1's subtree needs 3×140=420, child2 gets 140. Total=560.
        // child1 at -560/2 + 420/2 = -70
        // child2 at -560/2 + 420 + 140/2 = 210
        XCTAssertEqual(c1.position.x, -70, accuracy: 0.01)
        XCTAssertEqual(c2.position.x, 210, accuracy: 0.01)
    }

    // MARK: - Collision Avoidance

    func testCollisionAvoidanceOnSelect() {
        let state = ProjectState()
        let rootID = state.project.trees[0].rootNode.id
        let child1 = state.addChildNode(to: rootID)
        let child2 = state.addChildNode(to: rootID)

        // Before selection: each child gets 140px slot, total=280
        // child1 at -70, child2 at +70
        let c1Before = state.findNode(id: child1.id)!
        let c2Before = state.findNode(id: child2.id)!
        XCTAssertEqual(c1Before.position.x, -70, accuracy: 0.01)
        XCTAssertEqual(c2Before.position.x, 70, accuracy: 0.01)

        // Select child1 → its slot expands to 600px
        state.selectNode(child1.id)

        let c1After = state.findNode(id: child1.id)!
        let c2After = state.findNode(id: child2.id)!

        // child1 slot=600, child2 slot=140. Total=740.
        // child1 at -740/2 + 600/2 = -70
        // child2 at -740/2 + 600 + 140/2 = 300
        XCTAssertEqual(c1After.position.x, -70, accuracy: 0.01)
        XCTAssertEqual(c2After.position.x, 300, accuracy: 0.01)

        // Deselect → siblings animate back
        state.selectNode(nil)
        let c2Reset = state.findNode(id: child2.id)!
        XCTAssertEqual(c2Reset.position.x, 70, accuracy: 0.01)
    }
}
