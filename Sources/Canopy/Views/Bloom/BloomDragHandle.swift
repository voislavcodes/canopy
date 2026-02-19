import SwiftUI

/// Visual drag handle bar rendered at the top of each bloom panel.
/// The drag gesture itself lives on the parent `DraggableBloomPanel` wrapper
/// so it can use @GestureState for smooth, re-render-free offset updates.
struct BloomDragHandle: View {
    let panel: BloomPanel
    @ObservedObject var bloomState: BloomState

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            // Focus/expand button (X when focused)
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    if bloomState.focusedPanel == panel {
                        bloomState.unfocus()
                    } else {
                        bloomState.focusedPanel = panel
                    }
                }
            } label: {
                Image(systemName: bloomState.focusedPanel == panel ? "xmark" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: bloomState.focusedPanel == panel ? 10 : 11, weight: bloomState.focusedPanel == panel ? .bold : .medium))
                    .foregroundColor(CanopyColors.chromeText.opacity(isHovering ? 0.8 : 0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 22)
        .background(
            isHovering
                ? CanopyColors.chromeText.opacity(0.06)
                : Color.clear
        )
        .clipShape(TopRoundedRect(radius: 10))
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
    }
}

/// Wraps a bloom panel with a drag handle and smooth @GestureState-driven dragging.
/// Owns `.position()` and `.scaleEffect()` so the drag translation can be applied
/// directly to the screen position — keeping the hit area in sync with the visual.
/// Uses global coordinate space so transforms don't distort the drag delta.
struct DraggableBloomPanel<Content: View>: View {
    let panel: BloomPanel
    let nodeID: UUID
    let bloomState: BloomState
    let canvasScale: CGFloat
    let screenPosition: CGPoint
    let content: Content

    @GestureState private var dragTranslation: CGSize = .zero

    init(panel: BloomPanel, nodeID: UUID, bloomState: BloomState, canvasScale: CGFloat, screenPosition: CGPoint, @ViewBuilder content: () -> Content) {
        self.panel = panel
        self.nodeID = nodeID
        self.bloomState = bloomState
        self.canvasScale = canvasScale
        self.screenPosition = screenPosition
        self.content = content()
    }

    var body: some View {
        content
            .overlay(alignment: .top) {
                BloomDragHandle(panel: panel, bloomState: bloomState)
                    .gesture(panelDrag)
            }
            .environment(\.canvasScale, 1.0)
            .scaleEffect(canvasScale)
            .position(
                x: screenPosition.x + dragTranslation.width,
                y: screenPosition.y + dragTranslation.height
            )
            .transaction { $0.animation = nil }
    }

    private var panelDrag: some Gesture {
        DragGesture(coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let s = max(canvasScale, 0.01)
                var current = bloomState.panelOffsets[nodeID] ?? .zero
                let stored = current.offset(for: panel)
                current.setOffset(
                    CGSize(
                        width: stored.width + value.translation.width / s,
                        height: stored.height + value.translation.height / s
                    ),
                    for: panel
                )
                bloomState.panelOffsets[nodeID] = current
            }
    }
}

/// Rectangle with only the top two corners rounded. macOS 13 compatible.
private struct TopRoundedRect: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY),
                    radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius),
                    radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
