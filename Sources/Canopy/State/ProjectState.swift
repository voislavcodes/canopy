import Foundation
import Combine

class ProjectState: ObservableObject {
    @Published var project: CanopyProject
    @Published var selectedNodeID: UUID?
    @Published var currentFilePath: URL?
    @Published var isDirty: Bool = false

    init(project: CanopyProject = ProjectFactory.newProject()) {
        self.project = project
    }

    /// The currently selected node, if any.
    var selectedNode: Node? {
        guard let id = selectedNodeID else { return nil }
        return findNode(id: id)
    }

    func selectNode(_ id: UUID?) {
        selectedNodeID = id
    }

    func findNode(id: UUID) -> Node? {
        for tree in project.trees {
            if let found = findNodeRecursive(id: id, in: tree.rootNode) {
                return found
            }
        }
        return nil
    }

    /// Update a node in-place using a transform closure. Marks project as dirty.
    func updateNode(id: UUID, transform: (inout Node) -> Void) {
        for i in 0..<project.trees.count {
            if updateNodeRecursive(id: id, in: &project.trees[i].rootNode, transform: transform) {
                isDirty = true
                return
            }
        }
    }

    func allNodes() -> [Node] {
        var result: [Node] = []
        for tree in project.trees {
            collectNodes(from: tree.rootNode, into: &result)
        }
        return result
    }

    // MARK: - Tree Mutations

    /// Add a child node to the given parent. Returns the new node.
    @discardableResult
    func addChildNode(to parentID: UUID, type: NodeType = .melodic) -> Node {
        let name: String
        switch type {
        case .melodic: name = "Melody"
        case .harmonic: name = "Harmony"
        case .rhythmic: name = "Rhythm"
        case .seed: name = "Seed"
        case .effect: name = "Effect"
        case .group: name = "Group"
        }

        let newNode = Node(
            name: name,
            type: type,
            sequence: NoteSequence(lengthInBeats: 8),
            patch: SoundPatch(
                name: "Default",
                soundType: .oscillator(OscillatorConfig(waveform: .sine))
            ),
            position: NodePosition()
        )

        updateNode(id: parentID) { parent in
            parent.children.append(newNode)
        }

        // Recompute layout for the entire tree
        if project.trees.count > 0 {
            recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        }

        isDirty = true
        return newNode
    }

    /// Remove a node by ID. Cannot remove the root node.
    func removeNode(id: UUID) {
        guard project.trees.count > 0 else { return }
        let rootID = project.trees[0].rootNode.id
        guard id != rootID else { return }

        removeNodeRecursive(id: id, from: &project.trees[0].rootNode)
        recomputeLayout(root: &project.trees[0].rootNode, x: 0, y: 0, depth: 0)
        isDirty = true
    }

    /// Compute the LCM of all nodes' sequence lengths (the natural polyrhythmic cycle).
    func cycleLengthInBeats() -> Int {
        let nodes = allNodes()
        guard !nodes.isEmpty else { return 1 }
        let lengths = nodes.map { max(1, Int(round($0.sequence.lengthInBeats))) }
        return lengths.reduce(1) { lcm($0, $1) }
    }

    // MARK: - Layout

    /// Spacing constants for tree layout.
    private static let horizontalSpacing: Double = 120
    private static let verticalSpacing: Double = 150

    /// Recursively position nodes in a fan layout.
    /// Root is at (x, y). Children fan out below.
    private func recomputeLayout(root: inout Node, x: Double, y: Double, depth: Int) {
        root.position = NodePosition(x: x, y: y)

        let childCount = root.children.count
        guard childCount > 0 else { return }

        let totalWidth = Double(childCount - 1) * Self.horizontalSpacing
        let startX = x - totalWidth / 2
        let childY = y + Self.verticalSpacing

        for i in 0..<childCount {
            let childX = startX + Double(i) * Self.horizontalSpacing
            recomputeLayout(root: &root.children[i], x: childX, y: childY, depth: depth + 1)
        }
    }

    // MARK: - Private Helpers

    private func findNodeRecursive(id: UUID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children {
            if let found = findNodeRecursive(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    private func updateNodeRecursive(id: UUID, in node: inout Node, transform: (inout Node) -> Void) -> Bool {
        if node.id == id {
            transform(&node)
            return true
        }
        for i in 0..<node.children.count {
            if updateNodeRecursive(id: id, in: &node.children[i], transform: transform) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func removeNodeRecursive(id: UUID, from node: inout Node) -> Bool {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            node.children.remove(at: index)
            return true
        }
        for i in 0..<node.children.count {
            if removeNodeRecursive(id: id, from: &node.children[i]) {
                return true
            }
        }
        return false
    }

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}

// MARK: - Math Helpers

private func gcd(_ a: Int, _ b: Int) -> Int {
    var a = abs(a)
    var b = abs(b)
    while b != 0 {
        let t = b
        b = a % b
        a = t
    }
    return a
}

private func lcm(_ a: Int, _ b: Int) -> Int {
    guard a != 0 && b != 0 else { return 1 }
    return abs(a * b) / gcd(a, b)
}
