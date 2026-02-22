import SwiftUI

/// Tab for the bottom lane: FX (effects chain) or MOD (LFO modulation).
private enum BottomLaneTab {
    case fx, mod
}

/// Preference key to report FX chip frames from children up to the strip.
private struct FXChipFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Preference key to report the add button frame for picker positioning.
private struct AddButtonFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Preference key to report LFO chip frames.
private struct LFOChipFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Single bottom lane with tabbed FX / MOD views.
///
/// FX tab (default): shows the selected node's or master bus effect chain.
/// MOD tab: shows project-level LFOs as draggable chips.
struct BottomLaneView: View {
    @ObservedObject var projectState: ProjectState
    @State private var activeTab: BottomLaneTab = .fx

    // FX state
    @State private var showingPicker: Bool = false
    @State private var selectedFXID: UUID?
    @State private var fxChipFrames: [UUID: CGRect] = [:]
    @State private var addButtonFrame: CGRect = .zero
    @State private var pickerHeight: CGFloat = 240
    @State private var fxPopoverHeight: CGFloat = 200

    // LFO state
    @State private var lfoChipFrames: [UUID: CGRect] = [:]
    @State private var lfoPopoverHeight: CGFloat = 300

    private let stripCoordSpace = "bottomLaneStrip"

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
                // Tab switch
                tabSwitch

                // Add button
                addButton
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: AddButtonFrameKey.self,
                                value: geo.frame(in: .named(stripCoordSpace))
                            )
                        }
                    )

                // Tab content
                if activeTab == .fx {
                    fxContent
                } else {
                    modContent
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(height: 36)
        }
        .background(CanopyColors.chromeBackground)
        .coordinateSpace(name: stripCoordSpace)
        .onPreferenceChange(AddButtonFrameKey.self) { addButtonFrame = $0 }
        .onPreferenceChange(FXChipFrameKey.self) { fxChipFrames = $0 }
        .onPreferenceChange(LFOChipFrameKey.self) { lfoChipFrames = $0 }
        // Popovers overlay
        .overlay {
            if activeTab == .fx {
                fxPopovers
            } else {
                modPopovers
            }
        }
    }

    // MARK: - Tab Switch

    private var tabSwitch: some View {
        HStack(spacing: 4) {
            tabButton("FX", tab: .fx)
            tabButton("MOD", tab: .mod)
        }
    }

    private func tabButton(_ label: String, tab: BottomLaneTab) -> some View {
        let isActive = activeTab == tab
        return Button(action: {
            withAnimation(.spring(duration: 0.2)) {
                activeTab = tab
                // Dismiss the other tab's popovers
                if tab == .fx {
                    projectState.selectedLFOID = nil
                } else {
                    selectedFXID = nil
                    showingPicker = false
                }
            }
        }) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(isActive ? CanopyColors.chromeTextBright : CanopyColors.chromeText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isActive ? CanopyColors.nodeFill.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isActive ? CanopyColors.nodeFill.opacity(0.4) : CanopyColors.chromeBorder,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add Button

    private var addButton: some View {
        Button(action: {
            withAnimation(.spring(duration: 0.2)) {
                if activeTab == .fx {
                    selectedFXID = nil
                    showingPicker.toggle()
                } else {
                    let lfo = projectState.addLFO()
                    projectState.selectedLFOID = lfo.id
                }
            }
        }) {
            Text("+")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(CanopyColors.chromeBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - FX Content

    private var fxContent: some View {
        HStack(spacing: 6) {
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
        }
    }

    // MARK: - MOD Content

    private var modContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(projectState.project.lfos) { lfo in
                    LFOChipView(
                        lfo: lfo,
                        isSelected: projectState.selectedLFOID == lfo.id,
                        onTap: {
                            withAnimation(.spring(duration: 0.2)) {
                                if projectState.selectedLFOID == lfo.id {
                                    projectState.selectedLFOID = nil
                                } else {
                                    projectState.selectedLFOID = lfo.id
                                }
                            }
                        },
                        onDelete: {
                            projectState.removeLFO(id: lfo.id)
                        }
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: LFOChipFrameKey.self,
                                value: [lfo.id: geo.frame(in: .named(stripCoordSpace))]
                            )
                        }
                    )
                }
            }
        }
    }

    // MARK: - FX Popovers

    @ViewBuilder
    private var fxPopovers: some View {
        // Effect picker popover
        if showingPicker {
            effectPickerPopover
                .fixedSize()
                .position(
                    x: addButtonFrame.minX + 90,
                    y: -(pickerHeight / 2) - 4
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
        }

        // FX settings popover (above selected chip)
        if let fxID = selectedFXID,
           let effect = effects.first(where: { $0.id == fxID }),
           let chipFrame = fxChipFrames[fxID] {
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
                measuredHeight: $fxPopoverHeight
            )
            .fixedSize()
            .position(
                x: max(chipFrame.midX, 110),
                y: -(fxPopoverHeight / 2) - 4
            )
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
        }
    }

    // MARK: - MOD Popovers

    @ViewBuilder
    private var modPopovers: some View {
        if let lfoID = projectState.selectedLFOID,
           let lfo = projectState.project.lfos.first(where: { $0.id == lfoID }),
           let chipFrame = lfoChipFrames[lfoID] {
            LFOPopoverPanel(lfo: lfo, projectState: projectState, measuredHeight: $lfoPopoverHeight)
                .fixedSize()
                .position(
                    x: chipFrame.midX,
                    y: -(lfoPopoverHeight / 2) - 4
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
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

    // MARK: - Effect Picker Popover

    private var effectPickerPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(EffectType.canopyTypes, id: \.self) { type in
                Button(action: {
                    withAnimation(.spring(duration: 0.2)) { showingPicker = false }
                    addEffect(type: type)
                }) {
                    Text(type.displayName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeTextBright)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - FX Actions

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

// MARK: - LFO Chip

/// A single draggable LFO chip in the modulator strip.
private struct LFOChipView: View {
    let lfo: LFODefinition
    let isSelected: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(lfoColor(lfo.colorIndex))
                .frame(width: 8, height: 8)

            Text(lfo.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(isSelected ? CanopyColors.chromeTextBright : CanopyColors.chromeText)
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
                .fill(isSelected ? lfoColor(lfo.colorIndex).opacity(0.1) : CanopyColors.chromeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isSelected ? lfoColor(lfo.colorIndex).opacity(0.6) : CanopyColors.chromeBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onDrag {
            NSItemProvider(object: lfo.id.uuidString as NSString)
        }
    }
}

// MARK: - LFO Popover Panel

/// Settings panel that appears above the selected LFO chip.
private struct LFOPopoverPanel: View {
    let lfo: LFODefinition
    @ObservedObject var projectState: ProjectState
    @Binding var measuredHeight: CGFloat

    @State private var localRate: Double = 1.0
    @State private var localPhase: Double = 0.0
    @State private var localEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Circle()
                    .fill(lfoColor(lfo.colorIndex))
                    .frame(width: 8, height: 8)
                Text(lfo.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(lfoColor(lfo.colorIndex))
                Spacer()
                Button(action: { projectState.selectedLFOID = nil }) {
                    Text("×")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText)
                }
                .buttonStyle(.plain)
            }

            // Waveform picker
            lfoWaveformPicker()

            // Rate slider
            VStack(spacing: 2) {
                HStack {
                    Text("rate")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    Spacer()
                    Text(String(format: "%.2f Hz", localRate))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                }
                lfoSlider(value: $localRate, range: 0.01...20.0, logarithmic: true) {
                    projectState.updateLFO(id: lfo.id) { $0.rateHz = localRate }
                }
            }

            // Phase slider
            VStack(spacing: 2) {
                HStack {
                    Text("phase")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    Spacer()
                    Text(String(format: "%.2f", localPhase))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                }
                lfoSlider(value: $localPhase, range: 0...1) {
                    projectState.updateLFO(id: lfo.id) { $0.phase = localPhase }
                }
            }

            // Enabled toggle
            HStack {
                Text("enabled")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                Spacer()
                Button(action: {
                    localEnabled.toggle()
                    projectState.updateLFO(id: lfo.id) { $0.enabled = localEnabled }
                }) {
                    Text(localEnabled ? "ON" : "OFF")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(localEnabled ? lfoColor(lfo.colorIndex) : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(localEnabled ? lfoColor(lfo.colorIndex).opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    localEnabled ? lfoColor(lfo.colorIndex).opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            // Routings section
            Divider()
                .background(CanopyColors.bloomPanelBorder)

            Text("ROUTINGS")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            let lfoRoutings = projectState.routings(for: lfo.id)
            if lfoRoutings.isEmpty {
                Text("drag to a slider to connect")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.3))
            } else {
                ForEach(lfoRoutings) { routing in
                    routingRow(routing)
                }
            }
        }
        .padding(12)
        .frame(width: 220)
        .background(CanopyColors.bloomPanelBackground.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(lfoColor(lfo.colorIndex).opacity(0.3), lineWidth: 1)
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
        .onAppear { syncFromLFO() }
        .onChange(of: lfo) { _ in syncFromLFO() }
    }

    private func syncFromLFO() {
        localRate = lfo.rateHz
        localPhase = lfo.phase
        localEnabled = lfo.enabled
    }

    // MARK: - Waveform Picker

    private func lfoWaveformPicker() -> some View {
        HStack(spacing: 4) {
            ForEach(lfoWaveformOptions, id: \.1) { (label, wf) in
                Button(action: {
                    projectState.updateLFO(id: lfo.id) { $0.waveform = wf }
                }) {
                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(lfo.waveform == wf ? lfoColor(lfo.colorIndex) : CanopyColors.chromeText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(lfo.waveform == wf ? lfoColor(lfo.colorIndex).opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    lfo.waveform == wf ? lfoColor(lfo.colorIndex).opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var lfoWaveformOptions: [(String, LFOWaveform)] {
        [("∿", .sine), ("△", .triangle), ("╱", .sawtooth), ("□", .square), ("?", .sampleAndHold)]
    }

    // MARK: - Routing Row

    @ViewBuilder
    private func routingRow(_ routing: ModulationRouting) -> some View {
        let nodeName = projectState.findNode(id: routing.nodeID)?.name ?? "?"
        VStack(spacing: 2) {
            HStack {
                Text("\(nodeName) > \(routing.parameter.rawValue)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                Button(action: {
                    projectState.removeModulationRouting(id: routing.id)
                }) {
                    Text("×")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            // Depth mini-slider
            RoutingDepthSlider(routing: routing, projectState: projectState, color: lfoColor(lfo.colorIndex))
        }
    }

    // MARK: - Slider

    private func lfoSlider(value: Binding<Double>, range: ClosedRange<Double>, logarithmic: Bool = false, onCommit: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction: CGFloat = logarithmic
                ? CGFloat((log(value.wrappedValue) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
                : CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let filledWidth = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(lfoColor(lfo.colorIndex).opacity(0.5))
                    .frame(width: filledWidth, height: 6)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = Double(max(0, min(1, drag.location.x / width)))
                        if logarithmic {
                            value.wrappedValue = exp(log(range.lowerBound) + frac * (log(range.upperBound) - log(range.lowerBound)))
                        } else {
                            value.wrappedValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                        }
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 6)
    }
}

// MARK: - Routing Depth Slider

/// Inline depth slider for a routing row. Uses local @State to avoid cascade.
private struct RoutingDepthSlider: View {
    let routing: ModulationRouting
    @ObservedObject var projectState: ProjectState
    let color: Color

    @State private var localDepth: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filledWidth = max(0, min(width, width * CGFloat(localDepth)))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color.opacity(0.5))
                    .frame(width: filledWidth, height: 4)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        localDepth = max(0, min(1, Double(drag.location.x / width)))
                    }
                    .onEnded { _ in
                        projectState.updateModulationRouting(id: routing.id, depth: localDepth)
                    }
            )
        }
        .frame(height: 4)
        .onAppear { localDepth = routing.depth }
        .onChange(of: routing.depth) { newValue in localDepth = newValue }
    }
}

// MARK: - LFO Color Palette

/// Maps a color index (0-7) to an LFO chip color.
func lfoColor(_ index: Int) -> Color {
    let colors: [Color] = [
        Color(red: 0.9, green: 0.3, blue: 0.3),   // red
        Color(red: 0.3, green: 0.5, blue: 0.9),   // blue
        Color(red: 0.9, green: 0.8, blue: 0.3),   // yellow
        Color(red: 0.6, green: 0.3, blue: 0.8),   // purple
        Color(red: 0.3, green: 0.8, blue: 0.4),   // green
        Color(red: 0.9, green: 0.5, blue: 0.2),   // orange
        Color(red: 0.9, green: 0.4, blue: 0.6),   // pink
        Color(red: 0.3, green: 0.8, blue: 0.8),   // cyan
    ]
    return colors[index % colors.count]
}
