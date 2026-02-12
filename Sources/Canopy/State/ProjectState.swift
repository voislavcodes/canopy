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

    private func collectNodes(from node: Node, into result: inout [Node]) {
        result.append(node)
        for child in node.children {
            collectNodes(from: child, into: &result)
        }
    }
}
