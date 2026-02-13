import SwiftUI

/// A "+" circle that appears near the selected node in canvas space.
/// Positioned above node if no children, right of rightmost child if has children.
struct AddBranchButton: View {
    let parentPosition: CGPoint
    let children: [Node]
    let action: () -> Void

    private let size: CGFloat = 28

    private var buttonPosition: CGPoint {
        if children.isEmpty {
            return CGPoint(x: parentPosition.x, y: parentPosition.y - 80)
        } else {
            let rightmostX = children.map(\.position.x).max() ?? parentPosition.x
            let childY = children.first?.position.y ?? (parentPosition.y - 160)
            return CGPoint(x: rightmostX + 140, y: childY)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(CanopyColors.bloomPanelBackground.opacity(0.9))
                    .frame(width: size, height: size)

                Circle()
                    .stroke(CanopyColors.glowColor.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)

                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(CanopyColors.glowColor)
            }
        }
        .buttonStyle(.plain)
        .position(buttonPosition)
    }
}
