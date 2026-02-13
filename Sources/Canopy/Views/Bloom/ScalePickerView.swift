import SwiftUI

/// Compact scale picker: root note selector + mode selector.
/// Used in both tree chrome and node bloom.
struct ScalePickerView: View {
    @Binding var selectedKey: MusicalKey?
    var inheritedKey: MusicalKey
    var label: String = "Scale"

    @State private var isExpanded = false

    private var effectiveKey: MusicalKey {
        selectedKey ?? inheritedKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                Spacer()

                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    HStack(spacing: 3) {
                        Text(effectiveKey.displayName)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(selectedKey != nil ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.6))

                        if selectedKey == nil {
                            Text("(inherited)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                        }

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CanopyColors.bloomPanelBackground.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Override toggle
                    HStack(spacing: 6) {
                        Button(action: {
                            if selectedKey != nil {
                                selectedKey = nil
                            } else {
                                selectedKey = inheritedKey
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: selectedKey != nil ? "checkmark.square" : "square")
                                    .font(.system(size: 10))
                                Text("Override")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }

                    // Root note selector
                    rootSelector

                    // Mode selector
                    modeSelector
                }
            }
        }
    }

    private var rootSelector: some View {
        let roots = PitchClass.allCases
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 2), count: 6), spacing: 2) {
            ForEach(roots, id: \.self) { pitch in
                let isSelected = effectiveKey.root == pitch
                Button(action: { setRoot(pitch) }) {
                    Text(pitch.displayName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.6))
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isSelected ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var modeSelector: some View {
        let modes = ScaleMode.allCases
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(modes, id: \.self) { mode in
                    let isSelected = effectiveKey.mode == mode
                    Button(action: { setMode(mode) }) {
                        Text(mode.rawValue)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.5))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isSelected ? CanopyColors.glowColor.opacity(0.15) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(isSelected ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func setRoot(_ pitch: PitchClass) {
        if selectedKey == nil {
            selectedKey = MusicalKey(root: pitch, mode: inheritedKey.mode)
        } else {
            selectedKey?.root = pitch
        }
    }

    private func setMode(_ mode: ScaleMode) {
        if selectedKey == nil {
            selectedKey = MusicalKey(root: inheritedKey.root, mode: mode)
        } else {
            selectedKey?.mode = mode
        }
    }
}
