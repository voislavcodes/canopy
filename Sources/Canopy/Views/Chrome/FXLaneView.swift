import SwiftUI

/// Horizontal FX lane strip between canvas and modulator strip.
///
/// Context-sensitive:
/// - Node selected → shows that node's effect chain
/// - Nothing selected → shows master bus effect chain
struct FXLaneView: View {
    @ObservedObject var projectState: ProjectState
    @State private var showingPicker: Bool = false
    @State private var expandedEffectID: UUID?

    /// Whether we're showing the master bus (no node selected) or a node's chain.
    private var isShowingMasterBus: Bool {
        projectState.selectedNodeID == nil
    }

    /// Current effects list (node or master bus).
    private var effects: [Effect] {
        if let nodeID = projectState.selectedNodeID,
           let node = projectState.findNode(id: nodeID) {
            return node.effects
        }
        return projectState.project.masterBus.effects
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(CanopyColors.chromeBorder)
                .frame(height: 1)

            HStack(spacing: 6) {
                // +FX button on the left
                addButton

                // Scrollable effect boxes
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(effects) { effect in
                            if effects.first?.id != effect.id {
                                Text("\u{2192}")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(CanopyColors.chromeText.opacity(0.3))
                            }

                            EffectBoxView(
                                effect: effect,
                                isExpanded: expandedEffectID == effect.id,
                                onTapName: { toggleBypass(effect.id) },
                                onTapExpand: { toggleExpand(effect.id) },
                                onRemove: { removeEffect(effect.id) },
                                onParameterChange: { key, value in
                                    updateParameter(effectID: effect.id, key: key, value: value)
                                },
                                onWetDryChange: { value in
                                    updateWetDry(effectID: effect.id, value: value)
                                }
                            )
                        }
                    }
                }

                // Shore indicator (master bus only)
                if isShowingMasterBus {
                    shoreIndicator
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(height: 36)
        }
        .background(CanopyColors.chromeBackground)
        .sheet(isPresented: $showingPicker) {
            effectPickerSheet
        }
    }

    // MARK: - Shore Indicator

    private var shoreIndicator: some View {
        let shore = projectState.project.masterBus.shore
        return HStack(spacing: 3) {
            Text("shore")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(shore.enabled ? CanopyColors.nodeFill : CanopyColors.chromeText.opacity(0.4))
            Text(String(format: "%.1f dB", shore.ceiling))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(shore.enabled ? CanopyColors.nodeFill.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(shore.enabled ? CanopyColors.nodeFill.opacity(0.3) : CanopyColors.chromeBorder, lineWidth: 1)
        )
        .onTapGesture {
            projectState.configureShore(
                enabled: !shore.enabled,
                ceiling: shore.ceiling
            )
        }
    }

    // MARK: - Add Button

    private var addButton: some View {
        Button(action: { showingPicker = true }) {
            HStack(spacing: 4) {
                Text("+")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("FX")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundColor(CanopyColors.chromeText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(CanopyColors.chromeBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Effect Picker Sheet

    private var effectPickerSheet: some View {
        VStack(spacing: 8) {
            Text("add effect")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .padding(.top, 12)

            ForEach([EffectType.color, .heat, .echo, .space, .pressure], id: \.self) { type in
                Button(action: {
                    addEffect(type: type)
                    showingPicker = false
                }) {
                    HStack {
                        Text(type.displayName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                        Spacer()
                        Text(effectDescription(type))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    }
                    .foregroundColor(CanopyColors.chromeTextBright)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            Button("cancel") { showingPicker = false }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)
                .padding(.bottom, 12)
        }
        .frame(width: 240)
        .background(CanopyColors.bloomPanelBackground)
    }

    private func effectDescription(_ type: EffectType) -> String {
        switch type {
        case .color:    return "filter"
        case .heat:     return "distortion"
        case .echo:     return "delay"
        case .space:    return "reverb"
        case .pressure: return "compressor"
        default:        return ""
        }
    }

    // MARK: - Actions

    private func addEffect(type: EffectType) {
        if let nodeID = projectState.selectedNodeID {
            projectState.addNodeEffect(nodeID: nodeID, type: type)
        } else {
            projectState.addMasterEffect(type: type)
        }
    }

    private func removeEffect(_ effectID: UUID) {
        if let nodeID = projectState.selectedNodeID {
            projectState.removeNodeEffect(nodeID: nodeID, effectID: effectID)
        } else {
            projectState.removeMasterEffect(effectID: effectID)
        }
        if expandedEffectID == effectID {
            expandedEffectID = nil
        }
    }

    private func toggleBypass(_ effectID: UUID) {
        if let nodeID = projectState.selectedNodeID {
            projectState.toggleNodeEffectBypass(nodeID: nodeID, effectID: effectID)
        } else {
            projectState.toggleMasterEffectBypass(effectID: effectID)
        }
    }

    private func toggleExpand(_ effectID: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedEffectID = expandedEffectID == effectID ? nil : effectID
        }
    }

    private func updateParameter(effectID: UUID, key: String, value: Double) {
        if let nodeID = projectState.selectedNodeID {
            projectState.updateNodeEffect(nodeID: nodeID, effectID: effectID) { effect in
                effect.parameters[key] = value
            }
        } else {
            projectState.updateMasterEffect(effectID: effectID) { effect in
                effect.parameters[key] = value
            }
        }
    }

    private func updateWetDry(effectID: UUID, value: Double) {
        if let nodeID = projectState.selectedNodeID {
            projectState.updateNodeEffect(nodeID: nodeID, effectID: effectID) { effect in
                effect.wetDry = value
            }
        } else {
            projectState.updateMasterEffect(effectID: effectID) { effect in
                effect.wetDry = value
            }
        }
    }
}
