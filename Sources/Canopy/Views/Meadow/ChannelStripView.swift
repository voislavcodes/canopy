import SwiftUI

/// Single mixer channel strip for one branch node.
struct ChannelStripView: View {
    let node: Node
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    let nodeColor: Color
    @EnvironmentObject var viewModeManager: ViewModeManager

    @State private var isDragging = false
    @State private var dragFaderPosition: Double = 0.75
    @State private var lastDragY: CGFloat = 0

    @State private var isPanDragging = false
    @State private var dragPan: Double = 0.0
    @State private var lastPanDragX: CGFloat = 0

    @State private var isEditingDb = false
    @State private var editDbText: String = ""

    private let stripWidth: CGFloat = 60
    private let faderHeight: CGFloat = 140

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
            // Name + color dot (tap to navigate to Forest)
            HStack(spacing: 3) {
                Circle()
                    .fill(nodeColor)
                    .frame(width: 5, height: 5)
                Text(node.name.prefix(6).lowercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .lineLimit(1)
            }
            .onTapGesture {
                projectState.selectNodeInTree(node.id)
                viewModeManager.exitMeadow()
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

            // dB display (click to type)
            if isEditingDb {
                TextField("dB", text: $editDbText, onCommit: {
                    commitDbEdit()
                })
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: stripWidth - 8)
                .onExitCommand { isEditingDb = false }
            } else {
                Text(displayDb)
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                    .frame(width: stripWidth - 8)
                    .onTapGesture {
                        editDbText = displayDb.replacingOccurrences(of: "+", with: "")
                        isEditingDb = true
                    }
            }

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
            if NSEvent.modifierFlags.contains(.option) {
                projectState.exclusiveSolo(nodeID: node.id)
            } else {
                projectState.toggleSolo(nodeID: node.id)
            }
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
                            lastDragY = value.translation.height
                        }
                        let rawDelta = value.translation.height - lastDragY
                        lastDragY = value.translation.height
                        let scale: CGFloat = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                        dragFaderPosition = max(0, min(1, dragFaderPosition + (-rawDelta / trackHeight) * scale))

                        // Real-time audio feedback
                        let linear = VolumeConversion.faderToLinear(dragFaderPosition)
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
                                lastPanDragX = value.translation.width
                            }
                            let rawDelta = value.translation.width - lastPanDragX
                            lastPanDragX = value.translation.width
                            let scale: CGFloat = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                            dragPan = max(-1, min(1, dragPan + (rawDelta / (barWidth / 2)) * scale))
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
                .overlay(alignment: .topTrailing) {
                    if !node.effects.isEmpty {
                        Circle()
                            .fill(CanopyColors.glowColor)
                            .frame(width: 4, height: 4)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - dB Edit

    private func commitDbEdit() {
        isEditingDb = false
        guard let dbValue = Double(editDbText) else { return }
        let clamped = max(-60, min(6, dbValue))
        let linear = VolumeConversion.dbToLinear(clamped)
        projectState.updateNode(id: node.id) { $0.patch.setMixVolume(linear) }
        AudioEngine.shared.setNodeVolume(Float(linear), nodeID: node.id)
    }
}
