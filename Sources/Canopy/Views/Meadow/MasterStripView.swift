import SwiftUI

/// Master channel strip — fixed on the right side of MeadowView.
struct MasterStripView: View {
    @ObservedObject var projectState: ProjectState

    @State private var isDragging = false
    @State private var dragFaderPosition: Double = 0.75

    private let stripWidth: CGFloat = 80
    private let faderHeight: CGFloat = 140

    private var masterVolume: Double { projectState.project.masterBus.volume }

    private var faderPosition: Double {
        isDragging ? dragFaderPosition : VolumeConversion.linearToFader(masterVolume)
    }

    private var displayDb: String {
        let db = isDragging
            ? VolumeConversion.faderToDb(dragFaderPosition)
            : VolumeConversion.linearToDb(masterVolume)
        return VolumeConversion.formatDb(db)
    }

    var body: some View {
        VStack(spacing: 4) {
            // MASTER label
            Text("MASTER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)

            Spacer().frame(height: 4)

            // Level meter (polled at display rate)
            MasterMeterView()
                .frame(width: 20, height: faderHeight * 0.3)

            // Volume fader
            masterFader

            // dB display
            Text(displayDb)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))

            Spacer().frame(height: 4)

            // Shore indicator
            shoreIndicator

            // FX button (selects master bus FX)
            fxButton
        }
        .frame(width: stripWidth)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(CanopyColors.bloomPanelBackground.opacity(0.4))
        )
    }

    // MARK: - Master Fader

    private var masterFader: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let handleY = (1.0 - faderPosition) * trackHeight

            ZStack(alignment: .top) {
                // Track background
                RoundedRectangle(cornerRadius: 1)
                    .fill(CanopyColors.chromeBorder.opacity(0.3))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                // Fill (below handle)
                VStack {
                    Spacer()
                        .frame(height: handleY)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(CanopyColors.glowColor.opacity(0.4))
                        .frame(width: 4)
                }

                // Handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(CanopyColors.chromeTextBright)
                    .frame(width: 28, height: 10)
                    .offset(y: handleY - 5)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragFaderPosition = faderPosition
                        }
                        let delta = -value.translation.height / trackHeight
                        let newPos = max(0, min(1, dragFaderPosition + delta))
                        dragFaderPosition = newPos

                        // Real-time audio feedback
                        let linear = VolumeConversion.faderToLinear(newPos)
                        AudioEngine.shared.configureMasterVolume(Float(linear))
                    }
                    .onEnded { _ in
                        let linear = VolumeConversion.faderToLinear(dragFaderPosition)
                        projectState.project.masterBus.volume = linear
                        projectState.syncMasterBusToEngine()
                        projectState.markDirty()
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                // Double-click: reset to 0dB (linear 1.0)
                projectState.project.masterBus.volume = 1.0
                projectState.syncMasterBusToEngine()
                projectState.markDirty()
            }
        }
        .frame(width: stripWidth - 20, height: faderHeight)
    }

    // MARK: - Shore Indicator

    private var shoreIndicator: some View {
        let shore = projectState.project.masterBus.shore
        return HStack(spacing: 3) {
            Circle()
                .fill(shore.enabled ? Color.green.opacity(0.7) : CanopyColors.chromeText.opacity(0.2))
                .frame(width: 5, height: 5)
            Text("SHORE")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(shore.enabled ? 0.6 : 0.3))
        }
    }

    // MARK: - FX Button

    private var fxButton: some View {
        Button(action: {
            // Deselect node to show master bus FX in BottomLaneView
            projectState.selectedNodeID = nil
        }) {
            Text("FX")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(
                    projectState.selectedNodeID == nil
                        ? CanopyColors.glowColor
                        : CanopyColors.chromeText.opacity(0.5)
                )
                .frame(width: 36, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            projectState.selectedNodeID == nil
                                ? CanopyColors.glowColor.opacity(0.1)
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
}
