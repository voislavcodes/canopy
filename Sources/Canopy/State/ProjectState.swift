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

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}
