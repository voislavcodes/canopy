import SwiftUI

/// Popover shown when tapping the "new" tree node. Offers VARIATE or START FRESH.
struct NewTreePopoverView: View {
    @ObservedObject var projectState: ProjectState
    let onDismiss: () -> Void

    @State private var step: NewTreeStep = .choose

    enum NewTreeStep {
        case choose
        case pickSource
        case pickVariation(sourceTree: NodeTree)
        case configureVariation(sourceTree: NodeTree, variation: VariationType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .choose:
                chooseView
            case .pickSource:
                sourcePickerView
            case .pickVariation(let source):
                VariationMenuView(
                    sourceTree: source,
                    onSelect: { variation in
                        step = .configureVariation(sourceTree: source, variation: variation)
                    },
                    onBack: { step = projectState.project.trees.count > 1 ? .pickSource : .choose }
                )
            case .configureVariation(let source, let variation):
                VariationConfigView(
                    sourceTree: source,
                    variation: variation,
                    projectState: projectState,
                    onApply: { finalVariation in
                        applyVariation(source: source, variation: finalVariation)
                    },
                    onBack: { step = .pickVariation(sourceTree: source) }
                )
            }
        }
        .frame(width: 240)
        .background(CanopyColors.bloomPanelBackground)
    }

    // MARK: - Choose: VARIATE vs START FRESH

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW TREE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Button(action: {
                let trees = projectState.project.trees
                if trees.count == 1, let source = trees.first, !source.rootNode.sequence.notes.isEmpty {
                    step = .pickVariation(sourceTree: source)
                } else if trees.count > 1 {
                    step = .pickSource
                } else {
                    // No trees with content — just start fresh
                    createFreshTree()
                }
            }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(CanopyColors.glowColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VARIATE")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeTextBright)
                        Text("Create from existing tree")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(CanopyColors.glowColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CanopyColors.glowColor.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            Button(action: { createFreshTree() }) {
                HStack(spacing: 8) {
                    Circle()
                        .stroke(CanopyColors.chromeText.opacity(0.3), lineWidth: 1)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("START FRESH")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeTextBright)
                        Text("Blank tree")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CanopyColors.chromeBorder.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    // MARK: - Source Tree Picker

    private var sourcePickerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { step = .choose }) {
                    Text("< back")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text("VARIATE FROM")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            ForEach(Array(projectState.project.trees.enumerated()), id: \.element.id) { index, tree in
                Button(action: { step = .pickVariation(sourceTree: tree) }) {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                            .frame(width: 18, alignment: .trailing)

                        Circle()
                            .fill(treeColor(tree))
                            .frame(width: 8, height: 8)

                        Text(tree.name.lowercased())
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeTextBright)
                            .lineLimit(1)

                        Spacer()

                        Text("\(tree.rootNode.sequence.notes.count) notes")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeText.opacity(0.3))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    // MARK: - Actions

    private func createFreshTree() {
        guard let tree = projectState.addTree() else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            projectState.selectTree(tree.id)
        }
        onDismiss()
    }

    private func applyVariation(source: NodeTree, variation: VariationType) {
        let scale = source.scale ?? projectState.project.globalKey
        let newTree = VariationService.apply(variation, to: source, scale: scale)
        guard projectState.project.trees.count < 8 else { return }
        projectState.project.trees.append(newTree)
        projectState.markDirty()
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) {
            // Selecting the new tree triggers handleTreeSelectionChange in MainContentView,
            // which rebuilds the audio graph automatically.
            projectState.selectTree(newTree.id)
        }
        onDismiss()
    }

    private func treeColor(_ tree: NodeTree) -> Color {
        if let pid = tree.rootNode.presetID, let preset = NodePreset.find(pid) {
            return CanopyColors.presetColor(preset.color)
        }
        return CanopyColors.nodeSeed
    }
}

// MARK: - Variation Menu (category grid)

struct VariationMenuView: View {
    let sourceTree: NodeTree
    let onSelect: (VariationType) -> Void
    let onBack: () -> Void

    private let categories: [(VariationCategory, [VariationItem])] = [
        (.pitch, [
            VariationItem(name: "Transpose", icon: "↕", variation: .transpose(semitones: 0)),
            VariationItem(name: "Invert", icon: "⇅", variation: .invert(pivot: 60)),
            VariationItem(name: "Fifth", icon: "V", variation: .fifth(targetRoot: .G)),
        ]),
        (.rhythm, [
            VariationItem(name: "Density", icon: "◆", variation: .density(amount: 1.0)),
            VariationItem(name: "Mirror", icon: "◇", variation: .mirror),
            VariationItem(name: "Rotate", icon: "⟳", variation: .rotate(steps: 0)),
            VariationItem(name: "Euclidean", icon: "⊛", variation: .euclideanRefill(hits: 4, steps: 16, rotation: 0)),
        ]),
        (.melody, [
            VariationItem(name: "Bloom", icon: "❋", variation: .bloom(amount: 0.5)),
            VariationItem(name: "Drift", icon: "≈", variation: .drift(ticks: 0)),
            VariationItem(name: "Scramble", icon: "⚄", variation: .scramble(seed: 1)),
        ]),
        (.character, [
            VariationItem(name: "Human", icon: "♡", variation: .human(amount: 0.5)),
            VariationItem(name: "Mutate", icon: "◎", variation: .mutate(amount: 0.3, range: 2)),
            VariationItem(name: "Surprise", icon: "✦", variation: .surprise(variations: [])),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBack) {
                    Text("< back")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text("VARIATION")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            ForEach(categories, id: \.0) { category, items in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.rawValue)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.35))
                        .padding(.leading, 2)

                    FlowLayout(spacing: 4) {
                        ForEach(items, id: \.name) { item in
                            variationButton(item)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func variationButton(_ item: VariationItem) -> some View {
        Button(action: { onSelect(item.variation) }) {
            HStack(spacing: 4) {
                Text(item.icon)
                    .font(.system(size: 11))
                Text(item.name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundColor(CanopyColors.chromeTextBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(CanopyColors.chromeBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct VariationItem {
    let name: String
    let icon: String
    let variation: VariationType
}

// MARK: - Variation Config View (parameter tuning + APPLY)

struct VariationConfigView: View {
    let sourceTree: NodeTree
    @State var variation: VariationType
    let projectState: ProjectState
    let onApply: (VariationType) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBack) {
                    Text("< back")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Text(variation.displayName.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            parameterControls

            // APPLY button
            Button(action: { onApply(variation) }) {
                Text("APPLY")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.glowColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(CanopyColors.glowColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(CanopyColors.glowColor.opacity(0.4), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    @ViewBuilder
    private var parameterControls: some View {
        switch variation {
        case .transpose(let semitones):
            paramSlider(label: "SEMITONES", value: Double(semitones), range: -12...12, step: 1) { v in
                variation = .transpose(semitones: Int(v))
            }

        case .invert(let pivot):
            paramSlider(label: "PIVOT NOTE", value: Double(pivot), range: 36...96, step: 1) { v in
                variation = .invert(pivot: Int(v))
            }

        case .fifth:
            fifthPicker

        case .density(let amount):
            paramSlider(label: "AMOUNT", value: amount, range: 0.25...2.0, step: 0.05) { v in
                variation = .density(amount: v)
            }

        case .mirror:
            Text("Reverses note order in time")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

        case .rotate(let steps):
            paramSlider(label: "STEPS", value: Double(steps), range: -8...8, step: 1) { v in
                variation = .rotate(steps: Int(v))
            }

        case .euclideanRefill(let hits, let steps, let rotation):
            paramSlider(label: "HITS", value: Double(hits), range: 1...16, step: 1) { v in
                variation = .euclideanRefill(hits: Int(v), steps: steps, rotation: rotation)
            }
            paramSlider(label: "STEPS", value: Double(steps), range: 4...32, step: 1) { v in
                variation = .euclideanRefill(hits: hits, steps: Int(v), rotation: rotation)
            }
            paramSlider(label: "ROTATION", value: Double(rotation), range: 0...15, step: 1) { v in
                variation = .euclideanRefill(hits: hits, steps: steps, rotation: Int(v))
            }

        case .bloom(let amount):
            paramSlider(label: "AMOUNT", value: amount, range: 0.1...2.0, step: 0.1) { v in
                variation = .bloom(amount: v)
            }

        case .drift(let ticks):
            paramSlider(label: "TICKS", value: ticks, range: -24...24, step: 0.5) { v in
                variation = .drift(ticks: v)
            }

        case .scramble(let seed):
            HStack {
                Text("SEED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                Spacer()
                Text("\(seed)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
                Button(action: {
                    variation = .scramble(seed: UInt64.random(in: 1...9999))
                }) {
                    Text("RE-ROLL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.glowColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(CanopyColors.glowColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }

        case .human(let amount):
            paramSlider(label: "AMOUNT", value: amount, range: 0.1...1.0, step: 0.05) { v in
                variation = .human(amount: v)
            }

        case .mutate(let amount, let range):
            paramSlider(label: "AMOUNT", value: amount, range: 0.1...1.0, step: 0.05) { v in
                variation = .mutate(amount: v, range: range)
            }
            paramSlider(label: "RANGE", value: Double(range), range: 1...7, step: 1) { v in
                variation = .mutate(amount: amount, range: Int(v))
            }

        case .engineSwap:
            engineSwapPicker

        case .surprise:
            Text("Pick random variations with musical parameters")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
        }
    }

    // MARK: - Parameter Slider

    private func paramSlider(label: String, value: Double, range: ClosedRange<Double>, step: Double, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
                Spacer()
                Text(step >= 1 ? "\(Int(value))" : String(format: "%.2f", value))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeTextBright)
            }
            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
            .tint(CanopyColors.glowColor)
        }
    }

    // MARK: - Fifth Picker (circle of fifths)

    private var fifthPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TARGET ROOT")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))

            FlowLayout(spacing: 3) {
                ForEach(PitchClass.allCases, id: \.self) { pitch in
                    let isSelected: Bool = {
                        if case .fifth(let root) = variation { return root == pitch }
                        return false
                    }()
                    Button(action: { variation = .fifth(targetRoot: pitch) }) {
                        Text(pitch.displayName)
                            .font(.system(size: 10, weight: isSelected ? .bold : .regular, design: .monospaced))
                            .foregroundColor(isSelected ? CanopyColors.glowColor : CanopyColors.chromeText.opacity(0.6))
                            .frame(width: 28, height: 22)
                            .background(isSelected ? CanopyColors.glowColor.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(
                                        isSelected ? CanopyColors.glowColor.opacity(0.4) : CanopyColors.chromeBorder.opacity(0.2),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Engine Swap Picker

    private var engineSwapPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ENGINE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.4))

            let engines: [(String, SoundType)] = [
                ("Sine", .oscillator(OscillatorConfig(waveform: .sine))),
                ("Saw", .oscillator(OscillatorConfig(waveform: .sawtooth))),
                ("Square", .oscillator(OscillatorConfig(waveform: .square))),
                ("Triangle", .oscillator(OscillatorConfig(waveform: .triangle))),
            ]

            FlowLayout(spacing: 3) {
                ForEach(engines, id: \.0) { name, soundType in
                    Button(action: { variation = .engineSwap(soundType: soundType) }) {
                        Text(name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(CanopyColors.chromeTextBright)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(CanopyColors.chromeBackground.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(CanopyColors.chromeBorder.opacity(0.3), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
