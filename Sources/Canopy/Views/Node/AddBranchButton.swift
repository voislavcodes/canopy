import SwiftUI

/// A "+" circle that appears below the selected node in canvas space.
/// Tapping it adds a new child branch to the selected node.
struct AddBranchButton: View {
    let position: CGPoint
    let action: () -> Void

    private let size: CGFloat = 28

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
        .position(x: position.x, y: position.y + 55)
    }
}
