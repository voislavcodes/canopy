import SwiftUI

/// Bloom panel: TIDE spectral sequencing synthesizer controls.
/// 4 spectral parameters + pattern selector + output section.
/// Uses same local-drag-state pattern as FlowPanel.
struct TidePanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Spectral parameters
    @State private var localCurrent: Double = 0.4
    @State private var localPattern: Int = 0
    @State private var localRate: Double = 0.3
    @State private var localRateSync: Bool = false
    @State private var localRateDivision: TideRateDivision = .oneBar
    @State private var localDepth: Double = 0.6

    // Function generator
    @State private var localFuncShape: TideFuncShape = .off
    @State private var localFuncAmount: Double = 0.0
    @State private var localFuncSkew: Double = 0.5
    @State private var localFuncCycles: Int = 1

    // Output
    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    // Imprint
    @StateObject private var imprintRecorder = ImprintRecorder()

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var tideConfig: TideConfig? {
        guard let patch else { return nil }
        if case .tide(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeTide

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("TIDE")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ImprintButton(
                    recorder: imprintRecorder,
                    accentColor: accentColor,
                    onImprint: { imprint in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        let frames = SpectralImprint.tideFrames(from: imprint.spectralFrames)
                        // Set localPattern BEFORE commitConfig so pushConfigToEngine
                        // sends pattern 16 in the .setTide command.
                        localPattern = TidePatterns.imprintPatternIndex
                        commitConfig {
                            $0.imprint = imprint
                            $0.pattern = TidePatterns.imprintPatternIndex
                        }
                        AudioEngine.shared.configureTideImprint(frames, nodeID: nodeID)
                    },
                    onClear: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        // Set localPattern BEFORE commitConfig so pushConfigToEngine
                        // sends pattern 0 in the .setTide command.
                        localPattern = 0
                        commitConfig {
                            $0.imprint = nil
                            if $0.pattern == TidePatterns.imprintPatternIndex {
                                $0.pattern = 0
                            }
                        }
                        AudioEngine.shared.configureTideImprint(nil, nodeID: nodeID)
                    },
                    hasImprint: tideConfig?.imprint != nil
                )

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse"), ("Volt", "volt")],
                    current: "tide",
                    onChange: { type in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        if type == "osc" {
                            projectState.swapEngine(nodeID: nodeID, to: .oscillator(OscillatorConfig()))
                        } else if type == "drum" {
                            projectState.swapEngine(nodeID: nodeID, to: .drumKit(DrumKitConfig()))
                        } else if type == "quake" {
                            projectState.swapEngine(nodeID: nodeID, to: .quake(QuakeConfig()))
                        } else if type == "west" {
                            projectState.swapEngine(nodeID: nodeID, to: .westCoast(WestCoastConfig()))
                        } else if type == "flow" {
                            projectState.swapEngine(nodeID: nodeID, to: .flow(FlowConfig()))
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        } else if type == "spore" {
                            projectState.swapEngine(nodeID: nodeID, to: .spore(SporeConfig()))
                        } else if type == "fuse" {
                            projectState.swapEngine(nodeID: nodeID, to: .fuse(FuseConfig()))
                        } else if type == "volt" {
                            projectState.swapEngine(nodeID: nodeID, to: .volt(VoltConfig()))
                        }
                    }
                )
            }

            // Spectral silhouette when imprinted
            if let imprint = tideConfig?.imprint {
                SpectralSilhouetteView(
                    values: imprint.spectralFrames.first ?? [],
                    accentColor: accentColor
                )
            }

            if tideConfig != nil {
                // Pattern selector
                patternSelector

                // Two-column layout: ASCII spectrum schematic + controls
                HStack(alignment: .top, spacing: 0) {
                    // Left: ASCII spectrum schematic
                    spectrumSchematic
                        .frame(width: 130 * cs, height: 260 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 4 * cs)
                                .fill(Color.black.opacity(0.3))
                        )

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)
                        .padding(.horizontal, 6 * cs)

                    // Right: existing controls
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        // Spectral parameters
                        VStack(alignment: .leading, spacing: 8 * cs) {
                            sectionLabel("SPECTRAL")

                            paramSlider(label: "CURR", value: $localCurrent, range: 0...1,
                                        format: { "\(Int($0 * 100))%" }) {
                                commitConfig { $0.current = localCurrent }
                            } onDrag: { pushConfigToEngine() }

                            rateControl

                            paramSlider(label: "DPTH", value: $localDepth, range: 0...1,
                                        format: { "\(Int($0 * 100))%" }) {
                                commitConfig { $0.depth = localDepth }
                            } onDrag: { pushConfigToEngine() }
                        }

                        sectionDivider

                        // Function generator
                        funcGenSection

                        sectionDivider

                        // Output section
                        outputSection
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 36 * cs)
        .padding([.leading, .bottom, .trailing], 14 * cs)
        .frame(width: 480 * cs)
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

    // MARK: - Pattern Selector

    /// Max pattern index for chevron navigation (excludes imprint slot unless active).
    private var navigablePatternCount: Int {
        tideConfig?.imprint != nil ? TidePatterns.patternCount : TidePatterns.patternCount - 1
    }

    private var patternSelector: some View {
        HStack(spacing: 6 * cs) {
            Button(action: {
                localPattern = (localPattern - 1 + navigablePatternCount) % navigablePatternCount
                commitConfig { $0.pattern = localPattern }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10 * cs, weight: .bold))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .buttonStyle(.plain)

            Text(TidePatterns.names[localPattern])
                .font(.system(size: 11 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeTextBright)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4 * cs)
                .background(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .fill(accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4 * cs)
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                )

            Button(action: {
                localPattern = (localPattern + 1) % navigablePatternCount
                commitConfig { $0.pattern = localPattern }
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10 * cs, weight: .bold))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rate Control (free / synced)

    private var rateControl: some View {
        VStack(spacing: 4 * cs) {
            // Sync toggle row
            HStack(spacing: 4 * cs) {
                Text("RATE")
                    .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                    .frame(width: 38 * cs, alignment: .trailing)

                Button(action: {
                    localRateSync.toggle()
                    commitConfig {
                        $0.rateSync = localRateSync
                    }
                }) {
                    Text(localRateSync ? "SYNC" : "FREE")
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localRateSync ? accentColor : CanopyColors.chromeText.opacity(0.6))
                        .padding(.horizontal, 6 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localRateSync ? accentColor.opacity(0.15) : CanopyColors.bloomPanelBorder.opacity(0.2))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(localRateSync ? accentColor.opacity(0.5) : CanopyColors.bloomPanelBorder.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            if localRateSync {
                // Beat division selector
                rateDivisionSelector
            } else {
                // Free-running rate slider
                paramSlider(label: "", value: $localRate, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.rate = localRate }
                } onDrag: { pushConfigToEngine() }
            }
        }
    }

    private var rateDivisionSelector: some View {
        HStack(spacing: 3 * cs) {
            ForEach(TideRateDivision.allCases, id: \.self) { division in
                let isSelected = localRateDivision == division
                Button(action: {
                    localRateDivision = division
                    commitConfig { $0.rateDivision = division }
                }) {
                    Text(division.displayName)
                        .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Function Generator Section

    private var funcGenSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("FUNC")

            // Shape selector: row of small buttons
            HStack(spacing: 3 * cs) {
                ForEach(TideFuncShape.allCases, id: \.self) { shape in
                    let isSelected = localFuncShape == shape
                    Button(action: {
                        localFuncShape = shape
                        commitConfig { $0.funcShape = shape }
                    }) {
                        Text(funcShapeLabel(shape))
                            .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .frame(height: 18 * cs)
                            .background(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3 * cs)
                                    .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Show AMT, SKEW, CYCLES only when shape is active
            if localFuncShape != .off {
                paramSlider(label: "AMT", value: $localFuncAmount, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.funcAmount = localFuncAmount }
                } onDrag: { pushConfigToEngine() }

                paramSlider(label: "SKEW", value: $localFuncSkew, range: 0...1,
                            format: { "\(Int($0 * 100))%" }) {
                    commitConfig { $0.funcSkew = localFuncSkew }
                } onDrag: { pushConfigToEngine() }

                // Cycles picker
                HStack(spacing: 3 * cs) {
                    Text("CYC")
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 38 * cs, alignment: .trailing)

                    ForEach([1, 2, 4, 8, 16], id: \.self) { count in
                        let isSelected = localFuncCycles == count
                        Button(action: {
                            localFuncCycles = count
                            commitConfig { $0.funcCycles = count }
                        }) {
                            Text("\(count)x")
                                .font(.system(size: 7 * cs, weight: .bold, design: .monospaced))
                                .foregroundColor(isSelected ? .white : CanopyColors.chromeText.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .frame(height: 18 * cs)
                                .background(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .fill(isSelected ? accentColor.opacity(0.5) : accentColor.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3 * cs)
                                        .stroke(isSelected ? accentColor.opacity(0.8) : accentColor.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func funcShapeLabel(_ shape: TideFuncShape) -> String {
        switch shape {
        case .off: return "OFF"
        case .sine: return "SIN"
        case .triangle: return "TRI"
        case .rampDown: return "\u{2193}"
        case .rampUp: return "\u{2191}"
        case .square: return "SQ"
        case .sAndH: return "S&H"
        }
    }

    // MARK: - Spectrum Schematic (ASCII)

    /// Frequency labels for the 16 bands (high to low for display: top = 16kHz, bottom = 75Hz).
    private static let bandLabels: [String] = [
        "16k", "10k", "7k5", "4k7", "3k0", "1k9", "1k2", "750",
        "475", "300", "190", "120", " 75", "   ", "   ", "   "
    ]

    /// Waveform character for CURRENT parameter: ∿→△→╱→⊓→≈
    private func sourceChar(for current: Double) -> String {
        switch current {
        case ..<0.2:  return "\u{223F}"  // ∿ sine
        case ..<0.4:  return "\u{25B3}"  // △ triangle
        case ..<0.6:  return "\u{2571}"  // ╱ saw
        case ..<0.8:  return "\u{2293}"  // ⊓ square
        default:      return "\u{2248}"  // ≈ noise
        }
    }

    /// Func gen shape character for schematic display.
    private func funcSchematicChar(_ shape: TideFuncShape) -> String? {
        switch shape {
        case .off:      return nil
        case .sine:     return "\u{223F}"  // ∿
        case .triangle: return "\u{25B3}"  // △
        case .rampDown: return "\u{2572}"  // ╲
        case .rampUp:   return "\u{2571}"  // ╱
        case .square:   return "\u{2293}"  // ⊓
        case .sAndH:    return "\u{2715}"  // ✕
        }
    }

    /// Reactive ASCII spectrum display: 16 horizontal bars animated by pattern frames.
    private var spectrumSchematic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                drawTideSchematic(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    /// Draw a single monospaced character at a grid position with color.
    private func drawChar(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    /// Draw a bold monospaced character.
    private func drawCharBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    /// Draw a string of monospaced characters, each cell = cellW wide, centered on startX.
    private func drawString(_ context: GraphicsContext, _ str: String, centerX: CGFloat, y: CGFloat, cellW: CGFloat, fontSize: CGFloat, color: Color, bold: Bool = false) {
        let chars = Array(str)
        let totalW = CGFloat(chars.count) * cellW
        let startX = centerX - totalW / 2 + cellW / 2
        for (i, ch) in chars.enumerated() {
            let x = startX + CGFloat(i) * cellW
            if bold {
                drawCharBold(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color)
            } else {
                drawChar(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize, color: color)
            }
        }
    }

    private func drawTideSchematic(context: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width
        let h = size.height
        let wireColor = CanopyColors.chromeText
        let dimOp: CGFloat = 0.3

        let depth = CGFloat(localDepth)

        // Font / grid sizing
        let fontSize: CGFloat = max(8, 9 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35

        // Bar chars: space → ░ → ▒ → ▓ → █
        let barChars: [Character] = [" ", "\u{2591}", "\u{2591}", "\u{2592}", "\u{2592}", "\u{2593}", "\u{2593}", "\u{2588}", "\u{2588}"]
        let maxBarChars = 8

        // Compute per-band levels from pattern frames
        var bandLevels = [Float](repeating: 0.3, count: 16)

        if TidePatterns.isChaos(localPattern) {
            // Procedural: sin-based with band spread
            let speed: Float = localPattern == 15 ? 3.0 : 1.0  // Storm faster than Wanderer
            for band in 0..<16 {
                let phase = Float(time) * speed + Float(band) * 0.4
                let raw = (sin(phase) * 0.5 + 0.5) * 0.8 + 0.1
                // Add hash noise for Storm
                let noise: Float = localPattern == 15 ? sin(phase * 7.3 + Float(band) * 2.1) * 0.2 : 0
                bandLevels[band] = max(0, min(1, raw + noise))
            }
        } else if TidePatterns.isImprint(localPattern) {
            // Imprint: flat mid-level bars (actual data is audio-thread only)
            for band in 0..<16 {
                bandLevels[band] = 0.4 + sin(Float(band) * 0.5 + Float(time) * 0.3) * 0.15
            }
        } else if let frames = TidePatterns.frames(for: localPattern), !frames.isEmpty {
            // Deterministic pattern: interpolate between frames
            let rateHz = 0.05 + localRate * 2.0
            let pos = fmod(time * rateHz, Double(frames.count))
            let idx = Int(pos) % frames.count
            let nextIdx = (idx + 1) % frames.count
            let frac = Float(pos - floor(pos))

            for band in 0..<16 {
                let a = TideFrame.level(frames[idx], at: band)
                let b = TideFrame.level(frames[nextIdx], at: band)
                let raw = a + (b - a) * frac
                // Depth controls contrast: low depth = uniform, high = full range
                let floor: Float = 0.15
                bandLevels[band] = floor + (raw - floor) * Float(depth)
            }
        }

        // --- Draw 16 spectrum bars (top = band 15 = 16kHz, bottom = band 0 = 75Hz) ---
        let topMargin: CGFloat = 6 * cs
        let bandAreaH = h - topMargin - rowH * 4  // Leave room for source indicator at bottom
        let bandRowH = bandAreaH / 16

        // Show labels for key frequencies (every other + edges)
        let labeledBands: Set<Int> = [0, 2, 4, 6, 8, 10, 12, 14, 15]

        for displayRow in 0..<16 {
            let band = 15 - displayRow  // top = highest freq
            let y = topMargin + CGFloat(displayRow) * bandRowH + bandRowH * 0.5
            let level = CGFloat(bandLevels[band])

            // Frequency label (left side)
            if labeledBands.contains(displayRow) && displayRow < Self.bandLabels.count {
                let label = Self.bandLabels[displayRow]
                let labelX = cellW * 2.5
                drawString(context, label, centerX: labelX, y: y, cellW: cellW, fontSize: fontSize,
                           color: wireColor.opacity(dimOp))
            }

            // Bar: starts after label area
            let barStartX = cellW * 5
            let filledCount = Int(level * CGFloat(maxBarChars))

            for col in 0..<maxBarChars {
                let x = barStartX + CGFloat(col) * cellW
                if col < filledCount {
                    // Pick bar char based on position within filled range
                    let charIdx: Int
                    if filledCount > 0 {
                        let normalizedPos = Float(col) / Float(max(1, filledCount - 1))
                        charIdx = min(barChars.count - 1, Int(normalizedPos * Float(barChars.count - 1)) + 1)
                    } else {
                        charIdx = 0
                    }
                    let ch = barChars[charIdx]
                    let opacity = 0.4 + level * 0.6
                    drawCharBold(context, String(ch), at: CGPoint(x: x, y: y), size: fontSize,
                                 color: accentColor.opacity(opacity))
                } else {
                    // Empty space — dim dot
                    drawChar(context, "\u{00B7}", at: CGPoint(x: x, y: y), size: fontSize,
                             color: wireColor.opacity(0.1))
                }
            }
        }

        // --- Source indicator ---
        let srcY = h - rowH * 2.5
        let srcRuleY = srcY - rowH * 0.4

        // Horizontal rule: ── src ──
        drawString(context, "\u{2500}\u{2500} src \u{2500}\u{2500}", centerX: w * 0.5, y: srcRuleY,
                   cellW: cellW, fontSize: fontSize, color: wireColor.opacity(dimOp))

        // Waveform morph char
        let srcChar = sourceChar(for: localCurrent)
        drawCharBold(context, srcChar, at: CGPoint(x: w * 0.5, y: srcY + rowH * 0.3),
                     size: fontSize * 1.4, color: accentColor.opacity(0.8))

        // --- Func gen indicator (between spectrum and source) ---
        if let funcChar = funcSchematicChar(localFuncShape) {
            let funcY = srcRuleY - rowH * 1.0
            let funcOp = 0.3 + localFuncAmount * 0.7
            drawCharBold(context, funcChar, at: CGPoint(x: w * 0.5, y: funcY),
                         size: fontSize * 1.1, color: accentColor.opacity(funcOp))
        }
    }

    // MARK: - Sync

    private func syncFromModel() {
        guard let config = tideConfig else { return }
        localCurrent = config.current
        localPattern = config.pattern
        localRate = config.rate
        localRateSync = config.rateSync
        localRateDivision = config.rateDivision
        localDepth = config.depth
        localFuncShape = config.funcShape
        localFuncAmount = config.funcAmount
        localFuncSkew = config.funcSkew
        localFuncCycles = config.funcCycles
        localWarmth = config.warmth
        localVolume = config.volume
        localPan = config.pan
        guard let p = patch else { return }
        localVolume = p.volume
        localPan = p.pan
    }

    // MARK: - Section Divider

    private var sectionDivider: some View {
        Divider()
            .background(CanopyColors.bloomPanelBorder.opacity(0.3))
    }

    // MARK: - Output Section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5 * cs) {
            sectionLabel("OUTPUT")

            paramSlider(label: "WARM", value: $localWarmth, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.warmth = localWarmth }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "VOL", value: $localVolume, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitPatch { $0.volume = localVolume }
                commitConfig { $0.volume = localVolume }
            } onDrag: { pushConfigToEngine() }

            HStack(spacing: 4 * cs) {
                Text("L")
                    .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))

                panSlider

                Text("R")
                    .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText.opacity(0.4))
            }
        }
    }

    private var panSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat((localPan + 1) / 2)
            let indicatorX = max(0, min(width, width * fraction))

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3 * cs)
                    .fill(CanopyColors.bloomPanelBorder.opacity(0.3))
                    .frame(height: 8 * cs)

                Rectangle()
                    .fill(CanopyColors.chromeText.opacity(0.2))
                    .frame(width: 1, height: 8 * cs)
                    .position(x: width / 2, y: 4 * cs)

                Circle()
                    .fill(accentColor.opacity(0.8))
                    .frame(width: 10 * cs, height: 10 * cs)
                    .position(x: indicatorX, y: 4 * cs)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let frac = max(0, min(1, drag.location.x / width))
                        localPan = Double(frac) * 2 - 1
                        guard let nodeID = projectState.selectedNodeID else { return }
                        AudioEngine.shared.setNodePan(Float(localPan), nodeID: nodeID)
                    }
                    .onEnded { _ in
                        commitPatch { $0.pan = localPan }
                        commitConfig { $0.pan = localPan }
                    }
            )
        }
        .frame(height: 10 * cs)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * cs, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor.opacity(0.7))
    }

    // MARK: - Param Slider

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
                let fraction: CGFloat = CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
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

    private func commitConfig(_ transform: (inout TideConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .tide(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .tide(config)
            }
        }
        pushConfigToEngine()
    }

    private func commitPatch(_ transform: (inout SoundPatch) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            transform(&node.patch)
        }
    }

    private func pushConfigToEngine() {
        guard let nodeID = projectState.selectedNodeID else { return }
        let config = TideConfig(
            current: localCurrent,
            pattern: localPattern,
            rate: localRate,
            rateSync: localRateSync,
            rateDivision: localRateDivision,
            depth: localDepth,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan,
            funcShape: localFuncShape,
            funcAmount: localFuncAmount,
            funcSkew: localFuncSkew,
            funcCycles: localFuncCycles
        )
        AudioEngine.shared.configureTide(config, nodeID: nodeID)
    }
}
