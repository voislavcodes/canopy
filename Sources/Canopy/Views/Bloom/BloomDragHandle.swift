import SwiftUI

/// Drag handle bar rendered above each bloom panel content.
/// Uses the same background as the panel. Users recognize it as draggable
/// from the hand cursor and hover highlight.
struct BloomDragHandle: View {
    let panel: BloomPanel
    let nodeID: UUID
    @ObservedObject var bloomState: BloomState
    let canvasScale: CGFloat

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // Focus/expand button
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    if bloomState.focusedPanel == panel {
                        bloomState.unfocus()
                    } else {
                        bloomState.focusedPanel = panel
                    }
                }
            } label: {
                Image(systemName: bloomState.focusedPanel == panel ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(CanopyColors.chromeText.opacity(isHovering ? 0.8 : 0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 22)
        .background(
            CanopyColors.bloomPanelBackground.opacity(0.9)
                .overlay(isHovering ? CanopyColors.chromeText.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    // Convert screen-space drag delta to canvas-space
                    let scale = max(canvasScale, 0.01)
                    let canvasDelta = CGSize(
                        width: value.translation.width / scale,
                        height: value.translation.height / scale
                    )
                    bloomState.activeDrag = ActivePanelDrag(panel: panel, delta: canvasDelta)
                }
                .onEnded { _ in
                    bloomState.commitDrag(nodeID: nodeID)
                }
        )
    }
}
