import SwiftUI

struct CanopyCanvasView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var canvasState: CanvasState

    // Center offset so the origin (0,0) starts at the center of the view
    private func centerOffset(viewSize: CGSize) -> CGSize {
        CGSize(width: viewSize.width / 2, height: viewSize.height / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Fixed background
                CanopyColors.canvasBackground
                    .ignoresSafeArea()

                // Transformed content layer
                ZStack {
                    ForEach(projectState.allNodes()) { node in
                        NodeView(
                            node: node,
                            isSelected: projectState.selectedNodeID == node.id
                        )
                    }
                }
                .offset(centerOffset(viewSize: geometry.size))
                .offset(canvasState.offset)
                .scaleEffect(canvasState.scale)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        canvasState.offset = CGSize(
                            width: canvasState.lastOffset.width + value.translation.width,
                            height: canvasState.lastOffset.height + value.translation.height
                        )
                        canvasState.clampOffset(viewSize: geometry.size)
                    }
                    .onEnded { _ in
                        canvasState.lastOffset = canvasState.offset
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        canvasState.scale = canvasState.lastScale * value
                        canvasState.clampScale()
                    }
                    .onEnded { _ in
                        canvasState.lastScale = canvasState.scale
                    }
            )
            .onTapGesture { location in
                handleTap(at: location, viewSize: geometry.size)
            }
        }
    }

    private func handleTap(at location: CGPoint, viewSize: CGSize) {
        // Convert view coordinates to canvas coordinates
        let center = centerOffset(viewSize: viewSize)
        let canvasX = (location.x - viewSize.width / 2 - canvasState.offset.width) / canvasState.scale - center.width + viewSize.width / 2
        let canvasY = (location.y - viewSize.height / 2 - canvasState.offset.height) / canvasState.scale - center.height + viewSize.height / 2

        let hitRadius: CGFloat = 40

        for node in projectState.allNodes() {
            let dx = canvasX - node.position.x
            let dy = canvasY - node.position.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                projectState.selectNode(node.id)
                return
            }
        }

        // Clicked empty space — deselect
        projectState.selectNode(nil)
    }
}
