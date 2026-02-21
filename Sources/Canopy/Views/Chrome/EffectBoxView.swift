import SwiftUI

// MARK: - FX Chip

/// Compact FX tab in the FX lane strip — just name + color dot + remove button.
/// Tapping selects/deselects to show the popover above.
struct FXChipView: View {
    let effect: Effect
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(effect.bypassed ? fxColor(effect.type).opacity(0.3) : fxColor(effect.type))
                .frame(width: 8, height: 8)

            Text(effect.type.canonical.displayName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(
                    effect.bypassed
                        ? CanopyColors.chromeText.opacity(0.3)
                        : (isSelected ? CanopyColors.chromeTextBright : CanopyColors.chromeText)
                )
                .strikethrough(effect.bypassed, color: CanopyColors.chromeText.opacity(0.3))
                .lineLimit(1)

            Button(action: onDelete) {
                Text("×")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? fxColor(effect.type).opacity(0.1) : CanopyColors.chromeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isSelected ? fxColor(effect.type).opacity(0.6) : CanopyColors.chromeBorder,
                    lineWidth: 1
                )
        )
        .opacity(effect.bypassed ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - FX Popover Panel

/// Settings panel that appears above the selected FX chip.
/// Shows bypass toggle, parameter sliders, and wet/dry.
struct FXPopoverPanel: View {
    let effect: Effect
    let color: Color
    let onClose: () -> Void
    let onToggleBypass: () -> Void
    let onParameterChange: (String, Double) -> Void
    let onWetDryChange: (Double) -> Void
    @Binding var measuredHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(effect.type.canonical.displayName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Spacer()
                Button(action: onClose) {
                    Text("×")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText)
                }
                .buttonStyle(.plain)
            }

            // Bypass toggle
            HStack {
                Text("bypass")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                Spacer()
                Button(action: onToggleBypass) {
                    Text(effect.bypassed ? "OFF" : "ON")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(effect.bypassed ? CanopyColors.chromeText.opacity(0.4) : color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(effect.bypassed ? Color.clear : color.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    effect.bypassed ? CanopyColors.bloomPanelBorder.opacity(0.3) : color.opacity(0.5),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            // Parameter sliders
            ForEach(keyParameters, id: \.0) { (key, label) in
                FXParamSlider(
                    label: label,
                    value: effect.parameters[key] ?? 0.5,
                    color: color,
                    dimmed: effect.bypassed,
                    onChange: { onParameterChange(key, $0) }
                )
            }

            // Wet/dry slider (hidden for level)
            if effect.type.canonical != .level {
                FXParamSlider(
                    label: "wet/dry",
                    value: effect.wetDry,
                    color: color,
                    dimmed: effect.bypassed,
                    onChange: { onWetDryChange($0) }
                )
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measuredHeight = geo.size.height }
                    .onChange(of: geo.size.height) { measuredHeight = $0 }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { } // Prevent tap-through
    }

    // MARK: - Key Parameters

    private var keyParameters: [(String, String)] {
        switch effect.type.canonical {
        case .color:    return [("hue", "hue"), ("resonance", "resonance")]
        case .heat:     return [("temperature", "temperature"), ("tone", "tone")]
        case .echo:     return [("distance", "distance"), ("decay", "decay")]
        case .space:    return [("size", "size"), ("damp", "damp")]
        case .pressure: return [("weight", "weight"), ("squeeze", "squeeze")]
        case .drift:    return [("rate", "rate"), ("depth", "depth")]
        case .tide:     return [("rate", "rate"), ("depth", "depth")]
        case .terrain:  return [("low", "low"), ("mid", "mid"), ("high", "high")]
        case .level:    return [("amount", "level")]
        case .ghost:    return [("life", "life"), ("blur", "blur"), ("shift", "shift"), ("wander", "wander"), ("delayTime", "time")]
        default:        return []
        }
    }
}

// MARK: - FX Param Slider

/// Slider for use in the FX popover panel. Uses local @State to avoid cascade.
struct FXParamSlider: View {
    let label: String
    let value: Double
    let color: Color
    let dimmed: Bool
    let onChange: (Double) -> Void

    @State private var localValue: Double = 0.5

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(dimmed ? 0.3 : 0.5))
                Spacer()
                Text(String(format: "%.2f", localValue))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(dimmed ? 0.3 : 0.7))
            }

            GeometryReader { geo in
                let width = geo.size.width
                let filledWidth = max(0, min(width, width * CGFloat(localValue)))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(dimmed ? 0.2 : 0.5))
                        .frame(width: filledWidth, height: 6)
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
            .frame(height: 6)
        }
        .onAppear { localValue = value }
        .onChange(of: value) { localValue = $0 }
    }
}

// MARK: - FX Color

/// Maps an effect type to its display color.
func fxColor(_ type: EffectType) -> Color {
    switch type.canonical {
    case .color:    return Color(red: 0.4, green: 0.7, blue: 0.9)   // Blue
    case .heat:     return Color(red: 0.9, green: 0.45, blue: 0.3)  // Orange-red
    case .echo:     return Color(red: 0.5, green: 0.8, blue: 0.5)   // Green
    case .space:    return Color(red: 0.6, green: 0.5, blue: 0.9)   // Purple
    case .pressure: return Color(red: 0.9, green: 0.7, blue: 0.3)   // Yellow
    case .drift:    return Color(red: 0.3, green: 0.8, blue: 0.8)   // Cyan
    case .tide:     return Color(red: 0.8, green: 0.4, blue: 0.7)   // Pink
    case .terrain:  return Color(red: 0.6, green: 0.6, blue: 0.5)   // Olive
    case .level:    return Color(red: 0.7, green: 0.7, blue: 0.75)  // Silver
    case .ghost:    return Color(red: 0.55, green: 0.65, blue: 0.75)  // Pale steel-blue
    default:        return CanopyColors.chromeText
    }
}
