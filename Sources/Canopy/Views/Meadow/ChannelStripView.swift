import SwiftUI

/// Single mixer channel strip for one branch node.
struct ChannelStripView: View {
    let node: Node
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    @State private var isDragging = false
    @State private var dragFaderPosition: Double = 0.75

    @State private var isPanDragging = false
    @State private var dragPan: Double = 0.0

    private let stripWidth: CGFloat = 60
    private let faderHeight: CGFloat = 140

    private var nodeColor: Color {
        if let pid = node.presetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color)
        }
        return CanopyColors.nodeSeed
    }

    private var engineBadge: String {
        switch node.patch.soundType {
        case .oscillator: return "OSC"
        case .drumKit: return "DRUM"
        case .westCoast: return "WEST"
        case .flow: return "FLOW"
        case .tide: return "TIDE"
        case .swarm: return "SWRM"
        case .quake: return "QUAK"
        case .spore: return "SPOR"
        case .fuse: return "FUSE"
        case .volt: return "VOLT"
        case .schmynth: return "SCHM"
        case .sampler: return "SMPL"
        case .auv3: return "AU"
        }
    }

    private var currentVolume: Double { node.patch.volume }
    private var currentPan: Double { node.patch.pan }

    private var faderPosition: Double {
        isDragging ? dragFaderPosition : VolumeConversion.linearToFader(currentVolume)
    }

    private var displayDb: String {
        let db = isDragging
            ? VolumeConversion.faderToDb(dragFaderPosition)
            : VolumeConversion.linearToDb(currentVolume)
        return VolumeConversion.formatDb(db)
    }

    private var panValue: Double {
        isPanDragging ? dragPan : currentPan
    }

    var body: some View {
        VStack(spacing: 4) {
            // Name + color dot
            HStack(spacing: 3) {
                Circle()
                    .fill(nodeColor)
                    .frame(width: 5, height: 5)
                Text(node.name.prefix(6).lowercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .lineLimit(1)
            }

            // Engine badge
            Text(engineBadge)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(nodeColor.opacity(0.7))

            // Solo / Mute buttons
            HStack(spacing: 2) {
                soloButton
                muteButton
            }

            // Level meter (polled at display rate)
            NodeMeterView(nodeID: node.id)
                .frame(width: 16, height: faderHeight * 0.3)

            // Volume fader
            volumeFader

            // dB display
            Text(displayDb)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: stripWidth - 8)

            // Pan control
            panControl

            // FX button
            fxButton
        }
        .frame(width: stripWidth)
        .padding(.vertical, 4)
        .opacity(node.isMuted ? 0.4 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(CanopyColors.bloomPanelBackground.opacity(0.3))
        )
    }

    // MARK: - Solo / Mute Buttons

    private var soloButton: some View {
        Button(action: {
            projectState.toggleSolo(nodeID: node.id)
        }) {
            Text("S")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(node.isSolo ? Color.green : CanopyColors.chromeText.opacity(0.4))
                .frame(width: 20, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(node.isSolo ? Color.green.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(node.isSolo ? Color.green.opacity(0.4) : CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var muteButton: some View {
        Button(action: {
            projectState.toggleMute(nodeID: node.id)
        }) {
            Text("M")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(node.isMuted ? Color.orange : CanopyColors.chromeText.opacity(0.4))
                .frame(width: 20, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(node.isMuted ? Color.orange.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(node.isMuted ? Color.orange.opacity(0.4) : CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume Fader

    private var volumeFader: some View {
        GeometryReader { geo in
            let trackHeight = geo.size.height
            let handleY = (1.0 - faderPosition) * trackHeight

            ZStack(alignment: .top) {
                // Track background
                RoundedRectangle(cornerRadius: 1)
                    .fill(CanopyColors.chromeBorder.opacity(0.3))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)

                // Fill (below handle)
                VStack {
                    Spacer()
                        .frame(height: handleY)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(nodeColor.opacity(0.4))
                        .frame(width: 3)
                }

                // Handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(CanopyColors.chromeTextBright)
                    .frame(width: 20, height: 8)
                    .offset(y: handleY - 4)
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
                        AudioEngine.shared.setNodeVolume(Float(linear), nodeID: node.id)
                    }
                    .onEnded { _ in
                        let linear = VolumeConversion.faderToLinear(dragFaderPosition)
                        projectState.updateNode(id: node.id) { $0.patch.setMixVolume(linear) }
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                // Double-click: reset to 0dB (linear 1.0)
                projectState.updateNode(id: node.id) { $0.patch.setMixVolume(1.0) }
                AudioEngine.shared.setNodeVolume(1.0, nodeID: node.id)
            }
        }
        .frame(width: stripWidth - 16, height: faderHeight)
    }

    // MARK: - Pan Control

    private var panControl: some View {
        VStack(spacing: 1) {
            // Pan display
            Text(panDisplayText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            // Pan slider bar
            GeometryReader { geo in
                let barWidth = geo.size.width
                let centerX = barWidth / 2
                let indicatorX = centerX + CGFloat(panValue) * (barWidth / 2 - 4)

                ZStack {
                    // Track
                    RoundedRectangle(cornerRadius: 1)
                        .fill(CanopyColors.chromeBorder.opacity(0.3))
                        .frame(height: 3)

                    // Center mark
                    Rectangle()
                        .fill(CanopyColors.chromeText.opacity(0.2))
                        .frame(width: 1, height: 6)

                    // Indicator
                    Circle()
                        .fill(CanopyColors.chromeTextBright)
                        .frame(width: 6, height: 6)
                        .position(x: indicatorX, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !isPanDragging {
                                isPanDragging = true
                                dragPan = currentPan
                            }
                            let delta = value.translation.width / (barWidth / 2)
                            dragPan = max(-1, min(1, currentPan + delta))
                            AudioEngine.shared.setNodePan(Float(dragPan), nodeID: node.id)
                        }
                        .onEnded { _ in
                            let finalPan = dragPan
                            projectState.updateNode(id: node.id) { $0.patch.pan = finalPan }
                            isPanDragging = false
                        }
                )
                .onTapGesture(count: 2) {
                    // Double-click: reset to center
                    projectState.updateNode(id: node.id) { $0.patch.pan = 0 }
                    AudioEngine.shared.setNodePan(0, nodeID: node.id)
                }
            }
            .frame(height: 12)
        }
        .frame(width: stripWidth - 8)
    }

    private var panDisplayText: String {
        let p = panValue
        if abs(p) < 0.05 { return "C" }
        let deg = Int(abs(p) * 90)
        return p < 0 ? "L\(deg)" : "R\(deg)"
    }

    // MARK: - FX Button

    private var fxButton: some View {
        Button(action: {
            projectState.selectedNodeID = node.id
        }) {
            Text("FX")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(
                    projectState.selectedNodeID == node.id
                        ? CanopyColors.glowColor
                        : CanopyColors.chromeText.opacity(0.5)
                )
                .frame(width: 30, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            projectState.selectedNodeID == node.id
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
