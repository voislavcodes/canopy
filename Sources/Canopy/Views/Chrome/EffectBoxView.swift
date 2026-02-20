import SwiftUI

/// Compact effect box in the FX lane.
///
/// Shows effect name (tappable for bypass), remove button,
/// and 1–3 mini parameter sliders for key params.
/// Tapping expands to show all parameters.
struct EffectBoxView: View {
    let effect: Effect
    let isExpanded: Bool
    let onTapName: () -> Void
    let onTapExpand: () -> Void
    let onRemove: () -> Void
    let onParameterChange: (String, Double) -> Void
    let onWetDryChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header row: name + remove
            HStack(spacing: 4) {
                // Effect name (tap to bypass)
                Button(action: onTapName) {
                    Text(effect.type.canonical.displayName)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(effect.bypassed ? CanopyColors.chromeText.opacity(0.3) : effectColor)
                        .strikethrough(effect.bypassed, color: CanopyColors.chromeText.opacity(0.3))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 2)

                // Remove button
                Button(action: onRemove) {
                    Text("\u{00D7}")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            // Key parameter sliders (always visible)
            ForEach(keyParameters, id: \.0) { (key, label) in
                MiniSliderView(
                    label: label,
                    value: effect.parameters[key] ?? 0.5,
                    color: effectColor,
                    dimmed: effect.bypassed,
                    onChange: { onParameterChange(key, $0) }
                )
            }

            // Wet/dry slider (hidden for level — wet/dry on a gain makes no sense)
            if effect.type.canonical != .level {
                MiniSliderView(
                    label: "wet",
                    value: effect.wetDry,
                    color: effectColor,
                    dimmed: effect.bypassed,
                    onChange: { onWetDryChange($0) }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 64)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(effect.bypassed ? CanopyColors.chromeBackground : effectColor.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    effect.bypassed ? CanopyColors.chromeBorder.opacity(0.5) : effectColor.opacity(0.3),
                    lineWidth: 1
                )
        )
        .opacity(effect.bypassed ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onTapExpand() }
    }

    // MARK: - Effect-specific color

    private var effectColor: Color {
        switch effect.type.canonical {
        case .color:    return Color(red: 0.4, green: 0.7, blue: 0.9)   // Blue
        case .heat:     return Color(red: 0.9, green: 0.45, blue: 0.3)  // Orange-red
        case .echo:     return Color(red: 0.5, green: 0.8, blue: 0.5)   // Green
        case .space:    return Color(red: 0.6, green: 0.5, blue: 0.9)   // Purple
        case .pressure: return Color(red: 0.9, green: 0.7, blue: 0.3)   // Yellow
        case .drift:    return Color(red: 0.3, green: 0.8, blue: 0.8)   // Cyan
        case .tide:     return Color(red: 0.8, green: 0.4, blue: 0.7)   // Pink
        case .terrain:  return Color(red: 0.6, green: 0.6, blue: 0.5)   // Olive
        case .level:    return Color(red: 0.7, green: 0.7, blue: 0.75)  // Silver
        default:        return CanopyColors.chromeText
        }
    }

    // MARK: - Key Parameters (1–3 most important)

    private var keyParameters: [(String, String)] {
        switch effect.type.canonical {
        case .color:    return [("hue", "hue"), ("resonance", "res")]
        case .heat:     return [("temperature", "temp"), ("tone", "tone")]
        case .echo:     return [("distance", "dist"), ("decay", "decay")]
        case .space:    return [("size", "size"), ("damp", "damp")]
        case .pressure: return [("weight", "wt"), ("squeeze", "sq")]
        case .drift:    return [("rate", "rate"), ("depth", "depth")]
        case .tide:     return [("rate", "rate"), ("depth", "depth")]
        case .terrain:  return [("low", "lo"), ("mid", "mid"), ("high", "hi")]
        case .level:    return [("amount", "LEVEL")]
        default:        return []
        }
    }
}

// MARK: - Mini Slider

/// Tiny parameter slider for effect boxes.
struct MiniSliderView: View {
    let label: String
    let value: Double
    let color: Color
    let dimmed: Bool
    let onChange: (Double) -> Void

    @State private var localValue: Double = 0.5

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(dimmed ? 0.2 : 0.4))
                .frame(width: 24, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filledWidth = max(0, min(width, width * CGFloat(localValue)))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(dimmed ? 0.2 : 0.5))
                        .frame(width: filledWidth)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            localValue = max(0, min(1, Double(drag.location.x / width)))
                        }
                        .onEnded { _ in
                            onChange(localValue)
                        }
                )
            }
            .frame(height: 4)
        }
        .frame(height: 8)
        .onAppear { localValue = value }
        .onChange(of: value) { localValue = $0 }
    }
}
