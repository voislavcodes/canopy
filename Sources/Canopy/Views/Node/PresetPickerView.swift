import SwiftUI

/// 2x3 grid of preset circles that appears in-place when the "+" button is tapped.
struct PresetPickerView: View {
    let onSelect: (NodePreset) -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    private let presets = NodePreset.builtIn
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(presets) { preset in
                presetButton(preset)
            }
        }
        .padding(16)
        .frame(width: 220)
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .scaleEffect(appeared ? 1 : 0.7)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                appeared = true
            }
        }
    }

    private func presetButton(_ preset: NodePreset) -> some View {
        let color = CanopyColors.presetColor(preset.color)
        return Button(action: { onSelect(preset) }) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 42, height: 42)

                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 42, height: 42)

                    Image(systemName: preset.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(color)
                }

                Text(preset.name.lowercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }
}
