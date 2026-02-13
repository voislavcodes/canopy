import Foundation

/// Resolves the effective scale for a node using the inheritance chain:
/// node.scaleOverride → tree.scale → project.globalKey
enum ScaleResolver {
    static func resolve(node: Node, tree: NodeTree, project: CanopyProject) -> MusicalKey {
        node.scaleOverride ?? tree.scale ?? project.globalKey
    }
}
