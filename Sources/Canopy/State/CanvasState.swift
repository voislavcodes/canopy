import Foundation
import SwiftUI

class CanvasState: ObservableObject {
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero

    // Gesture accumulators
    var lastScale: CGFloat = 1.0
    var lastOffset: CGSize = .zero

    static let minScale: CGFloat = 0.3
    static let maxScale: CGFloat = 3.0

    func clampScale() {
        scale = min(max(scale, Self.minScale), Self.maxScale)
    }

    func clampOffset(viewSize: CGSize) {
        let maxOffsetX = viewSize.width
        let maxOffsetY = viewSize.height
        offset.width = min(max(offset.width, -maxOffsetX), maxOffsetX)
        offset.height = min(max(offset.height, -maxOffsetY), maxOffsetY)
    }
}
