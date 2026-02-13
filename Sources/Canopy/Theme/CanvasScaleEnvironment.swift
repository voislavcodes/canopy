import SwiftUI

/// Environment key that passes the canvas zoom scale down to bloom panels.
/// Panels use this to scale font sizes, frames, and padding so they render
/// at native resolution (crisp text) rather than relying on bitmap scaleEffect.
private struct CanvasScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var canvasScale: CGFloat {
        get { self[CanvasScaleKey.self] }
        set { self[CanvasScaleKey.self] = newValue }
    }
}
