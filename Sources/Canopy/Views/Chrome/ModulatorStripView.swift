import SwiftUI

/// Bottom bar showing project-level LFOs as draggable chips.
/// Tapping a chip opens a settings popover above it.
struct ModulatorStripView: View {
    @ObservedObject var projectState: ProjectState

    var body: some View {
        HStack(spacing: 8) {
            // "+ LFO" button
            Button(action: {
                let lfo = projectState.addLFO()
                projectState.selectedLFOID = lfo.id
            }) {
                HStack(spacing: 4) {
                    Text("+")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("LFO")
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

            // Scrollable chip list
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
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(CanopyColors.chromeBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(CanopyColors.chromeBorder)
                .frame(height: 1)
        }
        // Popover overlay above the strip
        .overlay(alignment: .topLeading) {
            if let lfoID = projectState.selectedLFOID,
               let lfo = projectState.project.lfos.first(where: { $0.id == lfoID }) {
                LFOPopoverPanel(lfo: lfo, projectState: projectState)
                    .offset(x: popoverXOffset(for: lfoID), y: -popoverHeight - 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
            }
        }
    }

    /// Approximate X offset for the popover based on chip index.
    private func popoverXOffset(for lfoID: UUID) -> CGFloat {
        guard let index = projectState.project.lfos.firstIndex(where: { $0.id == lfoID }) else { return 80 }
        // "+ LFO" button is ~60pt, each chip is ~80pt with spacing
        return 68 + CGFloat(index) * 86
    }

    private var popoverHeight: CGFloat { 320 }
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

/// Maps a color index (0–7) to an LFO chip color.
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
