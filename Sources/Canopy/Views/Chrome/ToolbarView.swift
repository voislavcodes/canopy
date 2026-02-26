import SwiftUI

struct ToolbarView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState
    @ObservedObject var forestPlayback: ForestPlaybackState

    @State private var showRootPicker = false
    @State private var showModePicker = false
    @State private var showTreesPopover = false

    private var globalKey: MusicalKey {
        get { projectState.project.globalKey }
    }

    var body: some View {
        HStack(spacing: 12) {
                // FOREST / RIVER tabs — matching FX/MOD style
                HStack(spacing: 12) {
                    Text("FOREST")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeTextBright)
                    Text("RIVER")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .allowsHitTesting(false)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(CanopyColors.bloomPanelBackground.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                )

                // Trees icon — visible with 2+ trees
                if projectState.project.trees.count >= 2 {
                    Button(action: { showTreesPopover.toggle() }) {
                        TreesIconView()
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showTreesPopover) {
                        TreesPopoverView(
                            projectState: projectState,
                            forestPlayback: forestPlayback
                        )
                    }
                    .help("Trees & playback mode")
                }

                Spacer()

                // Transport (centered via spacers)
                TransportView(transportState: transportState)

                Spacer()

                // Scale controls + keyboard toggle (right side)
                scaleSection

                // Computer keyboard MIDI input toggle
                Button(action: {
                    projectState.computerKeyboardEnabled.toggle()
                }) {
                    let enabled = projectState.computerKeyboardEnabled
                    Image(systemName: "pianokeys")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(enabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(enabled ? CanopyColors.glowColor.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(enabled ? CanopyColors.glowColor.opacity(0.3) : CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Computer keyboard MIDI input (A-L = notes, ; / ' = octave)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(CanopyColors.chromeBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(CanopyColors.chromeBorder),
            alignment: .bottom
        )
    }

    // MARK: - Ableton-Style Scale Section

    private var scaleSection: some View {
        let enabled = projectState.project.scaleAwareEnabled

        return HStack(spacing: 6) {
            // Scale-aware toggle
            Button(action: {
                projectState.project.scaleAwareEnabled.toggle()
                projectState.markDirty()
            }) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(enabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Scale-aware mode")

            // Root note picker
            Button(action: { showRootPicker.toggle() }) {
                Text(globalKey.root.displayName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(enabled ? CanopyColors.glowColor : CanopyColors.chromeTextBright)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRootPicker) {
                rootPickerPopover
            }

            // Mode picker
            Button(action: { showModePicker.toggle() }) {
                Text(shortModeName(globalKey.mode))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(enabled ? CanopyColors.chromeTextBright : CanopyColors.chromeText.opacity(0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModePicker) {
                modePickerPopover
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(CanopyColors.bloomPanelBackground.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Root Picker Popover

    private var rootPickerPopover: some View {
        VStack(spacing: 4) {
            // Piano-layout: top row (black keys), bottom row (white keys)
            let whiteKeys: [PitchClass] = [.C, .D, .E, .F, .G, .A, .B]
            let blackKeys: [(PitchClass, Int)] = [(.Cs, 0), (.Ds, 1), (.Fs, 3), (.Gs, 4), (.As, 5)]

            // Black keys row
            HStack(spacing: 3) {
                ForEach(0..<6, id: \.self) { slot in
                    if let bk = blackKeys.first(where: { $0.1 == slot }) {
                        rootButton(bk.0)
                    } else {
                        Color.clear.frame(width: 28, height: 24)
                    }
                }
            }

            // White keys row
            HStack(spacing: 3) {
                ForEach(whiteKeys, id: \.self) { pitch in
                    rootButton(pitch)
                }
            }
        }
        .padding(10)
        .background(CanopyColors.bloomPanelBackground)
    }

    private func rootButton(_ pitch: PitchClass) -> some View {
        let isSelected = globalKey.root == pitch
        return Button(action: {
            projectState.project.globalKey.root = pitch
            projectState.markDirty()
            showRootPicker = false
        }) {
            Text(pitch.displayName)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeTextBright)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : CanopyColors.chromeBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? CanopyColors.glowColor.opacity(0.5) : CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mode Picker Popover

    private var modePickerPopover: some View {
        let grouped: [(String, [ScaleMode])] = [
            ("Common", [.major, .minor, .dorian, .mixolydian]),
            ("Modes", [.phrygian, .lydian, .locrian]),
            ("Minor Variants", [.harmonicMinor, .melodicMinor]),
            ("Pentatonic", [.pentatonic, .pentatonicMajor, .pentatonicMinor]),
            ("Other", [.blues, .wholeTone, .chromatic]),
        ]

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(grouped, id: \.0) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.0.uppercased())
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.35))
                        .padding(.leading, 4)

                    FlowLayout(spacing: 3) {
                        ForEach(group.1, id: \.self) { mode in
                            modeButton(mode)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 220)
        .background(CanopyColors.bloomPanelBackground)
    }

    private func modeButton(_ mode: ScaleMode) -> some View {
        let isSelected = globalKey.mode == mode
        return Button(action: {
            projectState.project.globalKey.mode = mode
            projectState.markDirty()
            showModePicker = false
        }) {
            Text(shortModeName(mode))
                .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .monospaced))
                .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.chromeBorder.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func shortModeName(_ mode: ScaleMode) -> String {
        switch mode {
        case .major: return "Major"
        case .minor: return "Minor"
        case .dorian: return "Dorian"
        case .mixolydian: return "Mixo"
        case .phrygian: return "Phryg"
        case .lydian: return "Lydian"
        case .locrian: return "Locrian"
        case .harmonicMinor: return "Harm Min"
        case .melodicMinor: return "Mel Min"
        case .pentatonic: return "Penta"
        case .pentatonicMajor: return "Penta Maj"
        case .pentatonicMinor: return "Penta Min"
        case .blues: return "Blues"
        case .wholeTone: return "Whole"
        case .chromatic: return "Chrom"
        case .hirajoshi: return "Hira"
        case .inSen: return "In Sen"
        case .diminished: return "Dim"
        }
    }
}

// MARK: - Trees Icon (●─●)

private struct TreesIconView: View {
    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            let leftX: CGFloat = 6
            let rightX = size.width - 6
            let r: CGFloat = 3.5

            // Line
            var line = Path()
            line.move(to: CGPoint(x: leftX + r, y: y))
            line.addLine(to: CGPoint(x: rightX - r, y: y))
            context.stroke(line, with: .color(CanopyColors.glowColor.opacity(0.6)), lineWidth: 1.5)

            // Left dot
            let leftRect = CGRect(x: leftX - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: leftRect), with: .color(CanopyColors.glowColor))

            // Right dot
            let rightRect = CGRect(x: rightX - r, y: y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rightRect), with: .color(CanopyColors.glowColor))
        }
        .frame(width: 30, height: 22)
    }
}

// MARK: - Trees Popover

private struct TreesPopoverView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var forestPlayback: ForestPlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("TREES")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            // Tree list
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(projectState.project.trees.enumerated()), id: \.element.id) { index, tree in
                    treeRow(tree: tree, index: index)
                }
            }

            Divider()
                .background(CanopyColors.chromeBorder)

            // Playback mode
            Text("PLAYBACK")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            // Sequential mode pill (only mode for now)
            HStack(spacing: 6) {
                Text("→")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Text("Sequential")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundColor(CanopyColors.glowColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(CanopyColors.glowColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(CanopyColors.glowColor.opacity(0.4), lineWidth: 0.5)
            )
        }
        .padding(14)
        .frame(width: 200)
        .background(CanopyColors.bloomPanelBackground)
    }

    private func treeRow(tree: NodeTree, index: Int) -> some View {
        let isSelected = projectState.selectedTreeID == tree.id
        let isActive = forestPlayback.activeTreeID == tree.id
        let treeColor = treeColorFor(tree)

        return Button(action: { projectState.selectTree(tree.id) }) {
            HStack(spacing: 8) {
                Text("\(index + 1).")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 18, alignment: .trailing)

                // Color dot
                Circle()
                    .fill(treeColor)
                    .frame(width: 8, height: 8)

                // Active indicator
                if isActive {
                    Circle()
                        .fill(CanopyColors.glowColor)
                        .frame(width: 5, height: 5)
                }

                Text(tree.name.lowercased())
                    .font(.system(size: 12, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeTextBright)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                isSelected
                    ? CanopyColors.glowColor.opacity(0.08)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func treeColorFor(_ tree: NodeTree) -> Color {
        if let pid = tree.rootNode.presetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color)
        }
        return CanopyColors.nodeSeed
    }
}

// MARK: - Simple Flow Layout for Mode Tags

/// Wraps children horizontally, breaking to the next line when full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
