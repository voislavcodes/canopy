import SwiftUI

/// Canvas-drawn butterfly icon for the catch system.
/// Uses a multi-layer palette for natural wing color variation.
struct CatchButterflyIcon: View {
    let palette: SeedColor.ButterflyPalette
    var size: CGFloat = 12

    /// Convenience initializer — derives a palette from a single color.
    init(color: Color, size: CGFloat = 12) {
        self.palette = SeedColor.butterflyPalette(from: color)
        self.size = size
    }

    init(palette: SeedColor.ButterflyPalette, size: CGFloat = 12) {
        self.palette = palette
        self.size = size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            // 1. Upper wings (outer fill)
            var upperLeft = Path()
            upperLeft.move(to: CGPoint(x: 0.5 * w, y: 0.35 * h))
            upperLeft.addCurve(
                to: CGPoint(x: 0.5 * w, y: 0.5 * h),
                control1: CGPoint(x: 0.05 * w, y: 0.08 * h),
                control2: CGPoint(x: 0.02 * w, y: 0.5 * h)
            )
            context.fill(upperLeft, with: .color(palette.outerWing))

            var upperRight = Path()
            upperRight.move(to: CGPoint(x: 0.5 * w, y: 0.35 * h))
            upperRight.addCurve(
                to: CGPoint(x: 0.5 * w, y: 0.5 * h),
                control1: CGPoint(x: 0.95 * w, y: 0.08 * h),
                control2: CGPoint(x: 0.98 * w, y: 0.5 * h)
            )
            context.fill(upperRight, with: .color(palette.outerWing))

            // 2. Upper wing inner spots — large enough to be visible at small sizes
            let spotW = w * 0.28
            let spotH = h * 0.20
            let spotY = h * 0.34
            let leftSpot = Path(ellipseIn: CGRect(
                x: 0.24 * w - spotW / 2, y: spotY - spotH / 2,
                width: spotW, height: spotH
            ))
            context.fill(leftSpot, with: .color(palette.innerWing))
            let rightSpot = Path(ellipseIn: CGRect(
                x: 0.76 * w - spotW / 2, y: spotY - spotH / 2,
                width: spotW, height: spotH
            ))
            context.fill(rightSpot, with: .color(palette.innerWing))

            // 3. Lower wings (outer fill)
            var lowerLeft = Path()
            lowerLeft.move(to: CGPoint(x: 0.5 * w, y: 0.5 * h))
            lowerLeft.addCurve(
                to: CGPoint(x: 0.5 * w, y: 0.72 * h),
                control1: CGPoint(x: 0.1 * w, y: 0.55 * h),
                control2: CGPoint(x: 0.12 * w, y: 0.85 * h)
            )
            context.fill(lowerLeft, with: .color(palette.lowerWing))

            var lowerRight = Path()
            lowerRight.move(to: CGPoint(x: 0.5 * w, y: 0.5 * h))
            lowerRight.addCurve(
                to: CGPoint(x: 0.5 * w, y: 0.72 * h),
                control1: CGPoint(x: 0.9 * w, y: 0.55 * h),
                control2: CGPoint(x: 0.88 * w, y: 0.85 * h)
            )
            context.fill(lowerRight, with: .color(palette.lowerWing))

            // 4. Lower wing inner accent — bigger for visibility
            let lowerSpotW = w * 0.18
            let lowerSpotH = h * 0.14
            let lowerSpotY = h * 0.61
            let lowerLeftAccent = Path(ellipseIn: CGRect(
                x: 0.32 * w - lowerSpotW / 2, y: lowerSpotY - lowerSpotH / 2,
                width: lowerSpotW, height: lowerSpotH
            ))
            context.fill(lowerLeftAccent, with: .color(palette.innerWing.opacity(0.7)))
            let lowerRightAccent = Path(ellipseIn: CGRect(
                x: 0.68 * w - lowerSpotW / 2, y: lowerSpotY - lowerSpotH / 2,
                width: lowerSpotW, height: lowerSpotH
            ))
            context.fill(lowerRightAccent, with: .color(palette.innerWing.opacity(0.7)))

            // 5. Wing edge veins (only at size >= 14 for readability)
            if size >= 14 {
                let veinWidth = max(0.5, w * 0.03)

                // Left upper wing veins
                var vein1L = Path()
                vein1L.move(to: CGPoint(x: 0.48 * w, y: 0.40 * h))
                vein1L.addLine(to: CGPoint(x: 0.18 * w, y: 0.22 * h))
                context.stroke(vein1L, with: .color(palette.vein.opacity(0.6)), lineWidth: veinWidth)

                var vein2L = Path()
                vein2L.move(to: CGPoint(x: 0.48 * w, y: 0.44 * h))
                vein2L.addLine(to: CGPoint(x: 0.12 * w, y: 0.40 * h))
                context.stroke(vein2L, with: .color(palette.vein.opacity(0.4)), lineWidth: veinWidth)

                // Right upper wing veins (mirror)
                var vein1R = Path()
                vein1R.move(to: CGPoint(x: 0.52 * w, y: 0.40 * h))
                vein1R.addLine(to: CGPoint(x: 0.82 * w, y: 0.22 * h))
                context.stroke(vein1R, with: .color(palette.vein.opacity(0.6)), lineWidth: veinWidth)

                var vein2R = Path()
                vein2R.move(to: CGPoint(x: 0.52 * w, y: 0.44 * h))
                vein2R.addLine(to: CGPoint(x: 0.88 * w, y: 0.40 * h))
                context.stroke(vein2R, with: .color(palette.vein.opacity(0.4)), lineWidth: veinWidth)
            }

            // 6. Body — thin vertical stroke (slightly thicker)
            var bodyPath = Path()
            bodyPath.move(to: CGPoint(x: 0.5 * w, y: 0.2 * h))
            bodyPath.addLine(to: CGPoint(x: 0.5 * w, y: 0.8 * h))
            context.stroke(bodyPath, with: .color(palette.body), lineWidth: max(1, w * 0.08))

            // 7. Antennae (only at size >= 14 for readability)
            if size >= 14 {
                let antennaWidth = max(0.5, w * 0.04)

                var leftAntenna = Path()
                leftAntenna.move(to: CGPoint(x: 0.5 * w, y: 0.2 * h))
                leftAntenna.addQuadCurve(
                    to: CGPoint(x: 0.3 * w, y: 0.05 * h),
                    control: CGPoint(x: 0.38 * w, y: 0.15 * h)
                )
                context.stroke(leftAntenna, with: .color(palette.body.opacity(0.8)), lineWidth: antennaWidth)

                var rightAntenna = Path()
                rightAntenna.move(to: CGPoint(x: 0.5 * w, y: 0.2 * h))
                rightAntenna.addQuadCurve(
                    to: CGPoint(x: 0.7 * w, y: 0.05 * h),
                    control: CGPoint(x: 0.62 * w, y: 0.15 * h)
                )
                context.stroke(rightAntenna, with: .color(palette.body.opacity(0.8)), lineWidth: antennaWidth)
            }
        }
        .frame(width: size, height: size)
    }
}
