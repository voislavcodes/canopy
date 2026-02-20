import SwiftUI

/// Preference key to report FX chip frames from children up to the strip.
private struct FXChipFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Preference key to report the +FX button frame for picker positioning.
private struct FXButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Horizontal FX lane strip between canvas and modulator strip.
///
/// Context-sensitive:
/// - Node selected → shows that node's effect chain
/// - Nothing selected → shows master bus effect chain
///
/// Effects render as compact chip tabs (like LFO chips).
/// Tapping a chip opens a popover above it with full controls.
struct FXLaneView: View {
    @ObservedObject var projectState: ProjectState
    @State private var showingPicker: Bool = false
    @State private var selectedFXID: UUID?
    @State private var chipFrames: [UUID: CGRect] = [:]
    @State private var addButtonFrame: CGRect = .zero
    @State private var pickerHeight: CGFloat = 240
    @State private var popoverHeight: CGFloat = 200

    private let stripCoordSpace = "fxLaneStrip"

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
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: FXButtonFrameKey.self,
                                value: geo.frame(in: .named(stripCoordSpace))
                            )
                        }
                    )

                // Scrollable FX chip tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(effects) { effect in
                            FXChipView(
                                effect: effect,
                                isSelected: selectedFXID == effect.id,
                                onTap: {
                                    withAnimation(.spring(duration: 0.2)) {
                                        showingPicker = false
                                        if selectedFXID == effect.id {
                                            selectedFXID = nil
                                        } else {
                                            selectedFXID = effect.id
                                        }
                                    }
                                },
                                onDelete: { removeEffect(effect.id) }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: FXChipFrameKey.self,
                                        value: [effect.id: geo.frame(in: .named(stripCoordSpace))]
                                    )
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
        .coordinateSpace(name: stripCoordSpace)
        .onPreferenceChange(FXButtonFrameKey.self) { addButtonFrame = $0 }
        .onPreferenceChange(FXChipFrameKey.self) { chipFrames = $0 }
        // Popovers overlay
        .overlay {
            // +FX picker popover
            if showingPicker {
                effectPickerPopover
                    .fixedSize()
                    .position(
                        x: addButtonFrame.midX,
                        y: -(pickerHeight / 2) - 4
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
            }

            // FX settings popover (above selected chip)
            if let fxID = selectedFXID,
               let effect = effects.first(where: { $0.id == fxID }),
               let chipFrame = chipFrames[fxID] {
                FXPopoverPanel(
                    effect: effect,
                    color: fxColor(effect.type),
                    onClose: {
                        withAnimation(.spring(duration: 0.2)) { selectedFXID = nil }
                    },
                    onToggleBypass: { toggleBypass(fxID) },
                    onParameterChange: { key, value in
                        updateParameter(effectID: fxID, key: key, value: value)
                    },
                    onWetDryChange: { value in
                        updateWetDry(effectID: fxID, value: value)
                    },
                    measuredHeight: $popoverHeight
                )
                .fixedSize()
                .position(
                    x: chipFrame.midX,
                    y: -(popoverHeight / 2) - 4
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
            }
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
        Button(action: {
            withAnimation(.spring(duration: 0.2)) {
                selectedFXID = nil
                showingPicker.toggle()
            }
        }) {
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

    // MARK: - Effect Picker Popover

    private var effectPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fxPickerOptions, id: \.0) { (type, label) in
                Button(action: {
                    withAnimation(.spring(duration: 0.2)) { showingPicker = false }
                    addEffect(type: type)
                }) {
                    HStack {
                        Text(type.displayName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeTextBright)
                        Spacer()
                        Text(label)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 180)
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(CanopyColors.bloomPanelBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { pickerHeight = geo.size.height }
                    .onChange(of: geo.size.height) { pickerHeight = $0 }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { } // Prevent tap-through
    }

    private var fxPickerOptions: [(EffectType, String)] {
        [(.color, "filter"), (.heat, "distortion"), (.echo, "delay"), (.space, "reverb"), (.pressure, "compressor"), (.level, "gain")]
    }

    // MARK: - Actions

    private func addEffect(type: EffectType) {
        let effect: Effect
        if let nodeID = projectState.selectedNodeID {
            effect = projectState.addNodeEffect(nodeID: nodeID, type: type)
        } else {
            effect = projectState.addMasterEffect(type: type)
        }
        withAnimation(.spring(duration: 0.2)) {
            selectedFXID = effect.id
        }
    }

    private func removeEffect(_ effectID: UUID) {
        if let nodeID = projectState.selectedNodeID {
            projectState.removeNodeEffect(nodeID: nodeID, effectID: effectID)
        } else {
            projectState.removeMasterEffect(effectID: effectID)
        }
        if selectedFXID == effectID {
            selectedFXID = nil
        }
    }

    private func toggleBypass(_ effectID: UUID) {
        if let nodeID = projectState.selectedNodeID {
            projectState.toggleNodeEffectBypass(nodeID: nodeID, effectID: effectID)
        } else {
            projectState.toggleMasterEffectBypass(effectID: effectID)
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
