import SwiftUI

/// Bloom panel: synth controls with waveform picker, sliders.
/// Positioned in canvas space around the selected node.
///
/// Sliders use local @State during drag to avoid broadcasting every pixel
/// of movement through @Published → entire view tree. On drag end, the
/// final value is committed once to ProjectState.
struct SynthControlsPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state (view-local, zero cascade)

    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0
    @State private var localAttack: Double = 0.01
    @State private var localDecay: Double = 0.1
    @State private var localSustain: Double = 0.8
    @State private var localRelease: Double = 0.3
    @State private var localFilterEnabled: Bool = false
    @State private var localFilterCutoff: Double = 8000.0
    @State private var localFilterResonance: Double = 0.0

    private var node: Node? {
        projectState.selectedNode
    }

    private var patch: SoundPatch? {
        node?.patch
    }

    private var oscillatorConfig: OscillatorConfig? {
        guard let patch else { return nil }
        if case .oscillator(let config) = patch.soundType {
            return config
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * cs) {
            HStack {
                Text("SYNTH")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm")],
                    current: "osc",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "drum" {
                            projectState.swapEngine(nodeID: nodeID, to: .drumKit(DrumKitConfig()))
                        } else if type == "quake" {
                            projectState.swapEngine(nodeID: nodeID, to: .quake(QuakeConfig()))
                        } else if type == "west" {
                            projectState.swapEngine(nodeID: nodeID, to: .westCoast(WestCoastConfig()))
                        } else if type == "flow" {
                            projectState.swapEngine(nodeID: nodeID, to: .flow(FlowConfig()))
                        } else if type == "tide" {
                            projectState.swapEngine(nodeID: nodeID, to: .tide(TideConfig()))
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        }
                    }
                )
            }

            if let osc = oscillatorConfig, let _ = patch {
                // Volume / level slider
                bloomSlider(value: $localVolume, range: 0...1) {
                    commitPatch { $0.volume = localVolume }
                } onDrag: {
                    pushLocalPatchToEngine()
                }
                .modulationDropTarget(parameter: .volume, nodeID: projectState.selectedNodeID, projectState: projectState)

                // Pan slider
                VStack(spacing: 2 * cs) {
                    HStack {
                        Text("L")
                            .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                        Spacer()
                        Text("pan")
                            .font(.system(size: 10 * cs, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        Spacer()
                        Text("R")
                            .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                    }
                    panSlider(value: $localPan) {
                        commitPatch { $0.pan = localPan }
                    } onDrag: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        AudioEngine.shared.setNodePan(Float(localPan), nodeID: nodeID)
                    }
                }
                .modulationDropTarget(parameter: .pan, nodeID: projectState.selectedNodeID, projectState: projectState)

                // ADSR compact
                HStack(spacing: 6 * cs) {
                    miniSlider(label: "A", value: $localAttack, range: 0.001...2.0) {
                        commitEnvelope { $0.attack = localAttack }
                    } onDrag: {
                        pushLocalPatchToEngine()
                    }
                    miniSlider(label: "D", value: $localDecay, range: 0.001...2.0) {
                        commitEnvelope { $0.decay = localDecay }
                    } onDrag: {
                        pushLocalPatchToEngine()
                    }
                    miniSlider(label: "S", value: $localSustain, range: 0...1.0) {
                        commitEnvelope { $0.sustain = localSustain }
                    } onDrag: {
                        pushLocalPatchToEngine()
                    }
                    miniSlider(label: "R", value: $localRelease, range: 0.01...5.0) {
                        commitEnvelope { $0.release = localRelease }
                    } onDrag: {
                        pushLocalPatchToEngine()
                    }
                }

                // Filter section
                filterSection()

                // Waveform label
                Text("waveform")
                    .font(.system(size: 12 * cs, weight: .regular, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.6))

                // Waveform text buttons
                waveformPicker(current: osc.waveform)
            }
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 220 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { }
        .onAppear { syncFromModel() }
        .onChange(of: projectState.selectedNodeID) { _ in syncFromModel() }
    }

    // MARK: - Sync local state from model

    private func syncFromModel() {
        guard let patch else { return }
        localVolume = patch.volume
        localPan = patch.pan
        localAttack = patch.envelope.attack
        localDecay = patch.envelope.decay
        localSustain = patch.envelope.sustain
        localRelease = patch.envelope.release
        localFilterEnabled = patch.filter.enabled
        localFilterCutoff = patch.filter.cutoff
        localFilterResonance = patch.filter.resonance
    }

    // MARK: - Filter Section

    @ViewBuilder
    private func filterSection() -> some View {
        VStack(alignment: .leading, spacing: 6 * cs) {
            // Header with toggle
            HStack {
                Text("FILTER")
                    .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(localFilterEnabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.5))
                Spacer()
                Button(action: {
                    localFilterEnabled.toggle()
                    commitFilter { $0.enabled = localFilterEnabled }
                }) {
                    Text(localFilterEnabled ? "ON" : "OFF")
                        .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localFilterEnabled ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localFilterEnabled ? CanopyColors.glowColor.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(
                                    localFilterEnabled ? CanopyColors.glowColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            if localFilterEnabled {
                // Cutoff slider (logarithmic)
                VStack(spacing: 2 * cs) {
                    HStack {
                        Text("cutoff")
                            .font(.system(size: 10 * cs, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        Spacer()
                        Text(formatCutoff(localFilterCutoff))
                            .font(.system(size: 10 * cs, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                    }
                    bloomSlider(value: $localFilterCutoff, range: 20...20000, logarithmic: true) {
                        commitFilter { $0.cutoff = localFilterCutoff }
                    } onDrag: {
                        pushFilterToEngine()
                    }
                    .modulationDropTarget(parameter: .filterCutoff, nodeID: projectState.selectedNodeID, projectState: projectState)
                }

                // Resonance slider (linear)
                VStack(spacing: 2 * cs) {
                    HStack {
                        Text("resonance")
                            .font(.system(size: 10 * cs, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        Spacer()
                        Text("\(Int(localFilterResonance * 100))%")
                            .font(.system(size: 10 * cs, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.7))
                    }
                    bloomSlider(value: $localFilterResonance, range: 0...1) {
                        commitFilter { $0.resonance = localFilterResonance }
                    } onDrag: {
                        pushFilterToEngine()
                    }
                    .modulationDropTarget(parameter: .filterResonance, nodeID: projectState.selectedNodeID, projectState: projectState)
                }
            }
        }
    }

    private func formatCutoff(_ hz: Double) -> String {
        if hz >= 1000 {
            return String(format: "%.1fkHz", hz / 1000)
        } else {
            return String(format: "%.0fHz", hz)
        }
    }

    private func commitFilter(_ transform: (inout FilterConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch.filter)
        }
        pushPatchToEngine()
    }

    private func pushFilterToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        AudioEngine.shared.configureFilter(
            enabled: localFilterEnabled,
            cutoff: localFilterCutoff,
            resonance: localFilterResonance,
            nodeID: nodeID
        )
    }

    // MARK: - Waveform Picker

    private func waveformPicker(current: Waveform) -> some View {
        HStack(spacing: 6 * cs) {
            ForEach(waveformOptions, id: \.0) { (label, wf) in
                Button(action: {
                    updateOscillator { $0.waveform = wf }
                }) {
                    Text(label)
                        .font(.system(size: 12 * cs, weight: .medium, design: .monospaced))
                        .foregroundColor(current == wf ? CanopyColors.glowColor : CanopyColors.chromeText)
                        .padding(.horizontal, 8 * cs)
                        .padding(.vertical, 4 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * cs)
                                .fill(current == wf ? CanopyColors.glowColor.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4 * cs)
                                .stroke(
                                    current == wf ? CanopyColors.glowColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var waveformOptions: [(String, Waveform)] {
        [("saw", .sawtooth), ("sq", .square), ("tri", .triangle), ("sin", .sine)]
    }

    // MARK: - Sliders (Binding-based, local @State during drag)

    private func bloomSlider(value: Binding<Double>, range: ClosedRange<Double>, logarithmic: Bool = false, onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction: CGFloat = logarithmic
                ? CGFloat((log(value.wrappedValue) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
                : CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
            let filledWidth = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8 * cs)

                // Filled portion
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.glowColor.opacity(0.6))
                    .frame(width: filledWidth, height: 8 * cs)
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
                        onDrag()
                    }
                    .onEnded { _ in
                        onCommit()
                    }
            )
        }
        .frame(height: 8 * cs)
    }

    private func miniSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>, onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        VStack(spacing: 2 * cs) {
            Text(label)
                .font(.system(size: 9 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            GeometryReader { geo in
                let height = geo.size.height
                let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledHeight = max(0, min(height, height * fraction))

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2 * cs)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))

                    RoundedRectangle(cornerRadius: 2 * cs)
                        .fill(CanopyColors.glowColor.opacity(0.4))
                        .frame(height: filledHeight)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let frac = max(0, min(1, 1 - drag.location.y / height))
                            value.wrappedValue = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                            onDrag()
                        }
                        .onEnded { _ in
                            onCommit()
                        }
                )
            }
            .frame(width: 16 * cs, height: 32 * cs)
        }
    }

    // MARK: - Pan Slider

    private func panSlider(value: Binding<Double>, onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Map -1...1 to 0...1 fraction
            let fraction = CGFloat((value.wrappedValue + 1) / 2)
            let indicatorX = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8 * cs)

                // Center line
                Rectangle()
                    .fill(CanopyColors.chromeText.opacity(0.2))
                    .frame(width: 1, height: 8 * cs)
                    .position(x: width / 2, y: 4 * cs)

                // Indicator
                Circle()
                    .fill(CanopyColors.glowColor.opacity(0.8))
                    .frame(width: 10 * cs, height: 10 * cs)
                    .position(x: indicatorX, y: 4 * cs)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = max(0, min(1, drag.location.x / width))
                        value.wrappedValue = Double(frac) * 2 - 1 // Map 0...1 to -1...1
                        onDrag()
                    }
                    .onEnded { _ in
                        onCommit()
                    }
            )
        }
        .frame(height: 10 * cs)
    }

    // MARK: - Commit Helpers (write to ProjectState once on drag end)

    private func commitPatch(_ transform: (inout SoundPatch) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch)
        }
        pushPatchToEngine()
    }

    private func commitEnvelope(_ transform: (inout EnvelopeConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch.envelope)
        }
        pushPatchToEngine()
    }

    // MARK: - Waveform (discrete, not drag — still commits immediately)

    private func updateOscillator(_ transform: (inout OscillatorConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .oscillator(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .oscillator(config)
            }
        }
        pushPatchToEngine()
    }

    // MARK: - Push to AudioEngine

    /// Push local @State values directly to audio engine (no ProjectState mutation).
    private func pushLocalPatchToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        guard let osc = oscillatorConfig else { return }
        AudioEngine.shared.configurePatch(
            waveform: waveformToIndex(osc.waveform),
            detune: osc.detune,
            attack: localAttack,
            decay: localDecay,
            sustain: localSustain,
            release: localRelease,
            volume: localVolume,
            nodeID: nodeID
        )
    }

    /// Push committed model state to engine (used after waveform change or final commit).
    private func pushPatchToEngine() {
        guard let node = projectState.selectedNode,
              let nodeID = projectState.selectedNodeID else { return }
        let patch = node.patch
        if case .oscillator(let config) = patch.soundType {
            AudioEngine.shared.configurePatch(
                waveform: waveformToIndex(config.waveform),
                detune: config.detune,
                attack: patch.envelope.attack,
                decay: patch.envelope.decay,
                sustain: patch.envelope.sustain,
                release: patch.envelope.release,
                volume: patch.volume,
                nodeID: nodeID
            )
        }
        AudioEngine.shared.setNodePan(Float(patch.pan), nodeID: nodeID)
        AudioEngine.shared.configureFilter(
            enabled: patch.filter.enabled,
            cutoff: patch.filter.cutoff,
            resonance: patch.filter.resonance,
            nodeID: nodeID
        )
    }

    private func waveformToIndex(_ wf: Waveform) -> Int {
        switch wf {
        case .sine: return 0
        case .triangle: return 1
        case .sawtooth: return 2
        case .square: return 3
        case .noise: return 4
        }
    }
}

extension Waveform: CaseIterable {
    static var allCases: [Waveform] {
        [.sine, .triangle, .sawtooth, .square, .noise]
    }
}

// MARK: - Modulation Drop Target

/// View modifier that makes a slider a drop target for LFO chip drags.
/// Shows a colored dot when a routing exists and a highlight border when dragging over.
struct ModulationDropTargetModifier: ViewModifier {
    let parameter: ModulationParameter
    let nodeID: UUID?
    @ObservedObject var projectState: ProjectState
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                // Colored dots for existing routings
                if let nodeID {
                    let existingRoutings = projectState.routings(for: nodeID, parameter: parameter)
                    if !existingRoutings.isEmpty {
                        HStack(spacing: 2) {
                            ForEach(existingRoutings) { routing in
                                if let lfo = projectState.project.lfos.first(where: { $0.id == routing.lfoID }) {
                                    Circle()
                                        .fill(lfoColor(lfo.colorIndex))
                                        .frame(width: 6, height: 6)
                                }
                            }
                        }
                        .padding(.trailing, 2)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isTargeted ? CanopyColors.glowColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
                guard let nodeID else { return false }
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let uuidString = item as? String,
                          let lfoID = UUID(uuidString: uuidString) else { return }
                    DispatchQueue.main.async {
                        // Check if routing already exists
                        let existing = projectState.project.modulationRoutings.first {
                            $0.lfoID == lfoID && $0.nodeID == nodeID && $0.parameter == parameter
                        }
                        if existing == nil {
                            projectState.addModulationRouting(lfoID: lfoID, nodeID: nodeID, parameter: parameter)
                        }
                    }
                }
                return true
            }
    }
}

extension View {
    func modulationDropTarget(parameter: ModulationParameter, nodeID: UUID?, projectState: ProjectState) -> some View {
        modifier(ModulationDropTargetModifier(parameter: parameter, nodeID: nodeID, projectState: projectState))
    }
}
