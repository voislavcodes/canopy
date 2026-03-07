import SwiftUI

/// Master bus SHORE ring at the far right of Meadow.
/// Single ring (volume only, no pan), accent-colored.
struct MeadowShoreView: View {
    @ObservedObject var projectState: ProjectState

    @State private var smoothedLevel: Double = 0
    @State private var isDragging = false

    private let accentColor = Color(red: 0.29, green: 0.68, blue: 0.50)
    private let radius = MeadowMetrics.innerRingRadius

    private var isSelected: Bool {
        projectState.selectedTreeID == nil
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Selection glow
                if isSelected {
                    NodeGlowEffect(radius: radius, color: accentColor)
                }

                // Ring + loudness arc + volume dot
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let r = radius

                        // Ring stroke
                        let ringPath = Path { p in
                            p.addEllipse(in: CGRect(
                                x: center.x - r, y: center.y - r,
                                width: r * 2, height: r * 2
                            ))
                        }
                        context.stroke(ringPath, with: .color(accentColor.opacity(0.3)), lineWidth: 1.5)

                        let masterVol = projectState.project.masterBus.volume
                        let volAngle = volumeToAngle(min(1, masterVol))

                        // Loudness arc
                        if smoothedLevel > 0.001 {
                            let loudAngle = volumeToAngle(min(smoothedLevel, min(1, masterVol)))
                            var loudPath = Path()
                            loudPath.addArc(center: center, radius: r, startAngle: .radians(-.pi / 2), endAngle: .radians(loudAngle), clockwise: false)
                            context.stroke(loudPath, with: .color(accentColor.opacity(0.25)), lineWidth: MeadowMetrics.loudnessArcWidth)
                        }

                        // Volume arc trail
                        if masterVol > 0.001 {
                            var arcPath = Path()
                            arcPath.addArc(center: center, radius: r, startAngle: .radians(-.pi / 2), endAngle: .radians(volAngle), clockwise: false)
                            context.stroke(arcPath, with: .color(accentColor.opacity(0.15)), lineWidth: 1)
                        }

                        // Volume dot
                        let dotCenter = CGPoint(
                            x: center.x + cos(volAngle) * Double(r),
                            y: center.y + sin(volAngle) * Double(r)
                        )
                        let dotR = MeadowMetrics.volumeDotRadius
                        let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
                        context.fill(Path(ellipseIn: dotRect), with: .color(accentColor))
                        context.stroke(Path(ellipseIn: dotRect), with: .color(Color.black.opacity(0.6)), lineWidth: 1)
                    }
                    .onChange(of: timeline.date) { _ in
                        updateMasterLevel()
                    }
                }
                .frame(width: radius * 2 + 20, height: radius * 2 + 20)
                .gesture(masterVolumeDragGesture)
                .onTapGesture(count: 2) {
                    projectState.setMasterVolume(1.0)
                }

                // SHORE text in center
                Text("SHORE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor.opacity(0.4))
            }

            // Labels
            VStack(spacing: 2) {
                Text("shore")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(accentColor)

                Text(dbText)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }
        }
        .onTapGesture {
            projectState.selectTree(nil)
        }
    }

    private var masterVolumeDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    projectState.selectTree(nil)
                }
                let frame = radius * 2 + 20
                let center = CGPoint(x: frame / 2, y: frame / 2)
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                let vol = angleToVolume(angle)
                projectState.setMasterVolume(vol)
            }
            .onEnded { _ in
                isDragging = false
            }
    }

    private func updateMasterLevel() {
        let m = AudioEngine.shared.masterMeterLevels()
        let rawLevel = Double(max(m.rmsL, m.rmsR))
        let clamped = min(rawLevel, projectState.project.masterBus.volume)
        smoothedLevel = smoothedLevel * MeadowMetrics.smoothingFactor + clamped * (1 - MeadowMetrics.smoothingFactor)
    }

    private var dbText: String {
        VolumeConversion.formatDb(VolumeConversion.linearToDb(projectState.project.masterBus.volume))
    }

    private func volumeToAngle(_ volume: Double) -> Double {
        volume * 2.0 * .pi - .pi / 2.0
    }

    private func angleToVolume(_ angle: Double) -> Double {
        let normalized = angle + .pi / 2.0
        let wrapped = normalized < 0 ? normalized + 2.0 * .pi : normalized
        return max(0, min(1, wrapped / (2.0 * .pi)))
    }
}
