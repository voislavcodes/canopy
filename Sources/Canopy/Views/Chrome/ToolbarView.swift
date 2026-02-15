import SwiftUI

struct ToolbarView: View {
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var showRootPicker = false
    @State private var showModePicker = false

    private var globalKey: MusicalKey {
        get { projectState.project.globalKey }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Project name
            if isEditingName {
                TextField("Project Name", text: $editedName, onCommit: {
                    projectState.project.name = editedName
                    projectState.isDirty = true
                    isEditingName = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(CanopyColors.chromeTextBright)
                .frame(width: 160)
            } else {
                Text(projectState.project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .onTapGesture(count: 2) {
                        editedName = projectState.project.name
                        isEditingName = true
                    }
            }

            // Scale section — Ableton-style inline
            scaleSection

            Spacer()

            TransportView(transportState: transportState)

            Spacer()

            // Dirty indicator
            if projectState.isDirty {
                Circle()
                    .fill(CanopyColors.chromeText.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        HStack(spacing: 2) {
            // "Scale" label
            Text("SCALE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                .padding(.trailing, 4)

            // Scale-aware toggle
            Button(action: {
                projectState.project.scaleAwareEnabled.toggle()
                projectState.isDirty = true
            }) {
                let enabled = projectState.project.scaleAwareEnabled
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(enabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.35))
                    .frame(width: 22, height: 22)
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
            .help("Scale-aware mode")

            // Root note picker
            Button(action: { showRootPicker.toggle() }) {
                Text(globalKey.root.displayName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.glowColor)
                    .frame(minWidth: 24, minHeight: 22)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CanopyColors.glowColor.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(CanopyColors.glowColor.opacity(0.3), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRootPicker) {
                rootPickerPopover
            }

            // Mode picker
            Button(action: { showModePicker.toggle() }) {
                Text(shortModeName(globalKey.mode))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CanopyColors.chromeBackground.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(CanopyColors.chromeBorder.opacity(0.4), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModePicker) {
                modePickerPopover
            }
        }
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
            projectState.isDirty = true
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
            projectState.isDirty = true
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
        }
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
