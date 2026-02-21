import SwiftUI

/// Bloom panel: SPORE SEQ probabilistic sequencer controls.
/// Subdivision picker + density/focus + drift/memory sliders.
struct SporeSeqPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    @State private var localSubdivision: SporeSubdivision = .sixteenth
    @State private var localDensity: Double = 0.5
    @State private var localFocus: Double = 0.4
    @State private var localDrift: Double = 0.3
    @State private var localMemory: Double = 0.3
    @State private var localRange: Int = 3

    private var node: Node? { projectState.selectedNode }

    private var sporeSeqConfig: SporeSeqConfig? {
        node?.sporeSeqConfig
    }

    private let accentColor = CanopyColors.nodeSpore

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("SPORE SEQ")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ModuleSwapButton(
                    options: [("Pitched", SequencerType.pitched), ("Drum", SequencerType.drum), ("Orbit", SequencerType.orbit), ("Spore", SequencerType.sporeSeq)],
                    current: SequencerType.sporeSeq,
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        projectState.swapSequencer(nodeID: nodeID, to: type)
                    }
                )

                Spacer()

                // Enable/disable toggle
                Button(action: toggleSporeSeq) {
                    Text(sporeSeqConfig != nil ? "ON" : "OFF")
                        .font(.system(size: 9 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(sporeSeqConfig != nil ? accentColor : CanopyColors.chromeText.opacity(0.4))
                        .padding(.horizontal, 8 * cs)
                        .padding(.vertical, 3 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * cs)
                                .fill(sporeSeqConfig != nil ? accentColor.opacity(0.15) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4 * cs)
                                .stroke(sporeSeqConfig != nil ? accentColor.opacity(0.4) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            if sporeSeqConfig != nil {
                // Grid subdivision picker
                VStack(alignment: .leading, spacing: 4 * cs) {
                    sectionLabel("GRID")

                    HStack(spacing: 4 * cs) {
                        ForEach(SporeSubdivision.allCases, id: \.self) { sub in
                            Button(action: {
                                localSubdivision = sub
                                commitSeqConfig { $0.subdivision = sub }
                            }) {
                                Text(sub.displayName)
                                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                                    .foregroundColor(localSubdivision == sub ? accentColor : CanopyColors.chromeText.opacity(0.5))
                                    .padding(.horizontal, 6 * cs)
                                    .padding(.vertical, 3 * cs)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3 * cs)
                                            .fill(localSubdivision == sub ? accentColor.opacity(0.15) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3 * cs)
                                            .stroke(localSubdivision == sub ? accentColor.opacity(0.3) : CanopyColors.bloomPanelBorder.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left: Probability
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("PROBABILITY")

                        paramSlider(label: "DENS", value: $localDensity, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitSeqConfig { $0.density = localDensity }
                        } onDrag: { pushSeqConfigToEngine() }

                        paramSlider(label: "FOCS", value: $localFocus, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitSeqConfig { $0.focus = localFocus }
                        } onDrag: { pushSeqConfigToEngine() }
                    }
                    .frame(maxWidth: .infinity)

                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right: Evolution
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("EVOLUTION")

                        paramSlider(label: "DRFT", value: $localDrift, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitSeqConfig { $0.drift = localDrift }
                        } onDrag: { pushSeqConfigToEngine() }

                        paramSlider(label: "MEMO", value: $localMemory, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitSeqConfig { $0.memory = localMemory }
                        } onDrag: { pushSeqConfigToEngine() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 360 * cs)
        .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = sporeSeqConfig else { return }
        localSubdivision = config.subdivision
        localDensity = config.density
        localFocus = config.focus
        localDrift = config.drift
        localMemory = config.memory
        localRange = config.rangeOctaves
    }

    // MARK: - Toggle

    private func toggleSporeSeq() {
        guard let nodeID = projectState.selectedNodeID else { return }
        if sporeSeqConfig != nil {
            // Disable
            projectState.updateNode(id: nodeID) { node in
                node.sporeSeqConfig = nil
            }
            // Stop the sequencer on the audio thread
            AudioEngine.shared.graph.unit(for: nodeID)?.commandBuffer.push(.sporeSeqStop)
        } else {
            // Enable with defaults
            let config = SporeSeqConfig()
            projectState.updateNode(id: nodeID) { node in
                node.sporeSeqConfig = config
            }
            syncFromModel()
            pushSeqConfigToEngine()
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor.opacity(0.7))
    }

    private func paramSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
                              format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 38 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
                let filledWidth = max(0, min(width, width * fraction))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                        .frame(height: 8 * cs)

                    RoundedRectangle(cornerRadius: 3 * cs)
                        .fill(accentColor.opacity(0.5))
                        .frame(width: filledWidth, height: 8 * cs)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let frac = Double(max(0, min(1, drag.location.x / width)))
                            value.wrappedValue = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                            onDrag()
                        }
                        .onEnded { _ in
                            onCommit()
                        }
                )
            }
            .frame(height: 8 * cs)

            Text(format(value.wrappedValue))
                .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 40 * cs, alignment: .trailing)
        }
    }

    // MARK: - Commit Helpers

    private func commitSeqConfig(_ transform: (inout SporeSeqConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            var config = node.sporeSeqConfig ?? SporeSeqConfig()
            transform(&config)
            node.sporeSeqConfig = config
        }
        pushSeqConfigToEngine()
    }

    private func pushSeqConfigToEngine() {
        guard let nodeID = projectState.selectedNodeID,
              let node = node,
              let config = node.sporeSeqConfig else { return }
        let key = node.scaleOverride ?? node.key
        AudioEngine.shared.configureSporeSeq(config, key: key, nodeID: nodeID)
    }
}
