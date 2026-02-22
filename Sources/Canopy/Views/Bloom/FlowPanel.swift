import SwiftUI

/// Bloom panel: FLOW engine controls.
/// 5 fluid dynamics parameters + volume/pan output section.
/// Uses same local-drag-state pattern as WestCoastPanel.
struct FlowPanel: View {
    @Environment(\.canvasScale) var cs
    @ObservedObject var projectState: ProjectState

    // MARK: - Local drag state

    // Fluid parameters
    @State private var localCurrent: Double = 0.2
    @State private var localViscosity: Double = 0.5
    @State private var localObstacle: Double = 0.3
    @State private var localChannel: Double = 0.5
    @State private var localDensity: Double = 0.5

    // Output
    @State private var localFilter: Double = 1.0
    @State private var localFilterMode: Int = 0
    @State private var localWidth: Double = 0.5
    @State private var localAttack: Double = 0.01
    @State private var localDecay: Double = 0.3
    @State private var localWarmth: Double = 0.3
    @State private var localVolume: Double = 0.8
    @State private var localPan: Double = 0.0

    // Fluid knob drag tracking
    @State private var activeKnob: Int? = nil
    @State private var dragStartValue: Double = 0

    private let filterModeLabels = ["LP", "BP", "HP"]

    // Imprint
    @StateObject private var imprintRecorder = ImprintRecorder()

    private var node: Node? { projectState.selectedNode }
    private var patch: SoundPatch? { node?.patch }

    private var flowConfig: FlowConfig? {
        guard let patch else { return nil }
        if case .flow(let config) = patch.soundType { return config }
        return nil
    }

    private let accentColor = CanopyColors.nodeFlow

    /// Compute Reynolds number from current parameters.
    private var reynoldsNumber: Double {
        let currentScaled = max(localCurrent * 10.0, 0.001)
        let viscosityScaled = max(localViscosity * 5.0, 0.001)
        let channelScaled = max(localChannel * 2.0, 0.001)
        let densityScaled = max(localDensity * 2.0, 0.001)
        return (currentScaled * densityScaled * channelScaled) / viscosityScaled
    }

    /// Compute approximate regime label from current parameters.
    private var regimeLabel: (String, Color) {
        let re = reynoldsNumber
        if re < 30 {
            return ("LAMINAR", Color(red: 0.3, green: 0.8, blue: 0.9))
        } else if re < 350 {
            return ("TRANSITION", Color(red: 0.9, green: 0.7, blue: 0.3))
        } else {
            return ("TURBULENT", Color(red: 0.9, green: 0.35, blue: 0.3))
        }
    }

    // MARK: - Streamline Schematic (ASCII)

    /// Reactive ASCII streamline field: fluid flowing through a channel past an obstacle.
    /// Characters morph from smooth (─) to wavy (∿) to chaotic (≈) based on Reynolds regime.
    private var flowSchematic: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { context, size in
                drawFlowSchematic(context: context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
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

    private func drawFlowSchematic(context: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width
        let h = size.height
        let wireColor = CanopyColors.chromeText
        let dimOp: CGFloat = 0.3

        // Font / grid sizing
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35

        // Parameters as CGFloat
        let current = CGFloat(localCurrent)
        let viscosity = CGFloat(localViscosity)
        let density = CGFloat(localDensity)
        let obstacle = CGFloat(localObstacle)
        let channel = CGFloat(localChannel)

        // Reynolds regime
        let re = reynoldsNumber
        let regime = regimeLabel

        // Grid dimensions
        let totalCols = Int(w / cellW) - 2  // leave margin
        let marginX = (w - CGFloat(totalCols) * cellW) / 2 + cellW / 2

        // Channel wall positions controlled by CHAN parameter
        // CHAN=0: walls at edges (wide). CHAN=1: walls squeeze inward (narrow)
        let maxStreamlines = 7
        let topMargin: CGFloat = 8 * cs
        let bottomMargin: CGFloat = rowH * 2.5  // room for regime label
        let availableH = h - topMargin - bottomMargin
        let wallSqueeze = channel * 0.4  // how much walls squeeze in (0-40%)
        let wallInsetY = availableH * wallSqueeze * 0.5
        let topWallY = topMargin + wallInsetY
        let bottomWallY = topMargin + availableH - wallInsetY
        let channelH = bottomWallY - topWallY

        // Visible streamline count: narrower channel = fewer streamlines
        let visibleStreamlines = max(3, Int(CGFloat(maxStreamlines) * (1.0 - wallSqueeze * 0.6)))
        let streamlineSpacing = channelH / CGFloat(visibleStreamlines + 1)

        // Obstacle position and size
        let obstacleCol = Int(Double(totalCols) * 0.35)
        let obstacleWidth = Int(obstacle * 4)  // 0 to 4 chars wide
        let obstacleCenterRow = visibleStreamlines / 2  // center streamline index

        // Scroll animation
        let scrollSpeed = 0.5 + Double(current) * 4.0
        let scrollPhase = fmod(time * scrollSpeed, Double(totalCols))

        // Vortex shedding animation
        let vortexFreq = 0.5 + (1.0 - Double(viscosity)) * 3.0

        // --- Draw channel walls ---
        for col in 0..<totalCols {
            let x = marginX + CGFloat(col) * cellW
            drawChar(context, "\u{2550}", at: CGPoint(x: x, y: topWallY), size: fontSize,
                     color: wireColor.opacity(dimOp))
            drawChar(context, "\u{2550}", at: CGPoint(x: x, y: bottomWallY), size: fontSize,
                     color: wireColor.opacity(dimOp))
        }

        // --- Draw streamlines ---
        for row in 0..<visibleStreamlines {
            let y = topWallY + streamlineSpacing * CGFloat(row + 1)
            let rowPhase = scrollPhase + Double(row) * 0.3

            // Distance from obstacle center (for wake intensity)
            let distFromObstCenter = abs(row - obstacleCenterRow)
            let proximityFactor = max(0.0, 1.0 - CGFloat(distFromObstCenter) / CGFloat(max(1, visibleStreamlines / 2)))

            // Density controls opacity
            let baseOpacity = 0.25 + density * 0.65

            for col in 0..<totalCols {
                let x = marginX + CGFloat(col) * cellW

                // Check if this cell is the obstacle
                let obstStart = obstacleCol - obstacleWidth / 2
                let obstEnd = obstacleCol + (obstacleWidth + 1) / 2
                if obstacleWidth > 0 && col >= obstStart && col < obstEnd {
                    // Only draw obstacle on rows near center
                    if distFromObstCenter <= 1 {
                        drawCharBold(context, "\u{2593}", at: CGPoint(x: x, y: y), size: fontSize,
                                     color: accentColor.opacity(0.7))
                    } else {
                        // Streamline diverts around obstacle — draw dash
                        let ch = streamlineChar(col: col, totalCols: totalCols, obstacleCol: obstacleCol,
                                                obstacleWidth: obstacleWidth, proximity: proximityFactor,
                                                re: re, rowPhase: rowPhase, vortexFreq: vortexFreq,
                                                viscosity: Double(viscosity), time: time, row: row)
                        drawChar(context, ch, at: CGPoint(x: x, y: y), size: fontSize,
                                 color: regime.1.opacity(baseOpacity))
                    }
                    continue
                }

                // Arrow at right edge
                if col == totalCols - 1 {
                    drawChar(context, "\u{2192}", at: CGPoint(x: x, y: y), size: fontSize,
                             color: accentColor.opacity(baseOpacity))
                    continue
                }

                // Select character based on regime + position relative to obstacle + wake
                let ch = streamlineChar(col: col, totalCols: totalCols, obstacleCol: obstacleCol,
                                        obstacleWidth: obstacleWidth, proximity: proximityFactor,
                                        re: re, rowPhase: rowPhase, vortexFreq: vortexFreq,
                                        viscosity: Double(viscosity), time: time, row: row)

                // Color: blend from accent (cyan) toward regime color in wake zone
                let isWake = col > obstacleCol && obstacleWidth > 0
                let wakeBlend = isWake ? min(1.0, proximityFactor * 0.6) : 0
                let charColor = wakeBlend > 0.1 ? regime.1 : accentColor
                let opacity = baseOpacity * (isWake && proximityFactor > 0.3 ? 1.0 : 0.85)

                drawChar(context, ch, at: CGPoint(x: x, y: y), size: fontSize,
                         color: charColor.opacity(opacity))
            }
        }

        // --- Regime label at bottom ---
        let labelY = bottomWallY + rowH * 1.2
        let reInt = Int(re)
        let labelText = "\(regime.0)  Re:\(reInt)"
        drawString(context, labelText, centerX: w * 0.5, y: labelY, cellW: cellW, fontSize: fontSize,
                   color: regime.1.opacity(0.7), bold: true)
    }

    /// Select the appropriate streamline character based on position, regime, and wake.
    private func streamlineChar(col: Int, totalCols: Int, obstacleCol: Int, obstacleWidth: Int,
                                proximity: CGFloat, re: Double, rowPhase: Double,
                                vortexFreq: Double, viscosity: Double, time: Double, row: Int) -> String {
        // Is this column downstream of the obstacle?
        let isDownstream = col > obstacleCol + obstacleWidth / 2
        let downstreamDist = isDownstream ? col - obstacleCol : 0

        // Wake length: low viscosity = long wake, high = short
        let wakeLength = Int((1.0 - viscosity) * Double(totalCols) * 0.5) + 3

        // Wake intensity: strong near obstacle, fading with distance
        let inWake = isDownstream && downstreamDist < wakeLength && obstacleWidth > 0
        let wakeFade = inWake ? max(0.0, 1.0 - Double(downstreamDist) / Double(wakeLength)) : 0.0
        let wakeIntensity = wakeFade * Double(proximity)

        // Animated phase for character cycling
        let phase = rowPhase + Double(col) * 0.15
        let vortexPhase = sin(time * vortexFreq + Double(row) * 1.2 + Double(col) * 0.3)
        let cycleIndex = Int(fmod(phase, 4.0))

        // Base regime characters
        if re < 30 {
            // LAMINAR: mostly smooth dashes, slight wave in wake
            if wakeIntensity > 0.3 {
                return vortexPhase > 0.3 ? "\u{223F}" : "\u{2500}"  // ∿ or ─
            }
            return "\u{2500}"  // ─
        } else if re < 350 {
            // TRANSITION: mix of dash and wave, more turbulent in wake
            let transitionChars = ["\u{2500}", "\u{223F}", "\u{2500}", "\u{223F}"]  // ─ ∿ ─ ∿
            let wakeChars = ["\u{223F}", "\u{2248}", "\u{223F}", "\u{223D}"]        // ∿ ≈ ∿ ∽
            if wakeIntensity > 0.3 {
                return wakeChars[cycleIndex % wakeChars.count]
            }
            return transitionChars[cycleIndex % transitionChars.count]
        } else {
            // TURBULENT: all chaotic, even more so in wake
            let turbChars = ["\u{2248}", "\u{223F}", "\u{2248}", "\u{223D}"]  // ≈ ∿ ≈ ∽
            if wakeIntensity > 0.3 && vortexPhase > 0 {
                return "\u{2248}"  // ≈ full chaos
            }
            return turbChars[cycleIndex % turbChars.count]
        }
    }

    // MARK: - Fluid Knobs (ASCII)

    private var fluidKnobs: some View {
        let knobHeight: CGFloat = 130 * cs

        return GeometryReader { geo in
            let knobW = geo.size.width / 3

            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let kW = size.width / 3
                    let values = [localCurrent, localViscosity, localDensity]

                    for i in 0..<3 {
                        let rect = CGRect(x: CGFloat(i) * kW, y: 0, width: kW, height: size.height)
                        let isActive = activeKnob == i

                        switch i {
                        case 0: drawCurrentKnob(context: context, rect: rect, value: values[i], time: time, active: isActive)
                        case 1: drawViscosityKnob(context: context, rect: rect, value: values[i], time: time, active: isActive)
                        case 2: drawDensityKnob(context: context, rect: rect, value: values[i], time: time, active: isActive)
                        default: break
                        }
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if activeKnob == nil {
                            let third = Int(drag.startLocation.x / knobW)
                            activeKnob = min(2, max(0, third))
                            dragStartValue = [localCurrent, localViscosity, localDensity][activeKnob!]
                        }
                        let delta = -drag.translation.height / (150 * cs)
                        let newVal = max(0, min(1, dragStartValue + Double(delta)))
                        switch activeKnob {
                        case 0: localCurrent = newVal
                        case 1: localViscosity = newVal
                        case 2: localDensity = newVal
                        default: break
                        }
                        pushConfigToEngine()
                    }
                    .onEnded { _ in
                        switch activeKnob {
                        case 0: commitConfig { $0.current = localCurrent }
                        case 1: commitConfig { $0.viscosity = localViscosity }
                        case 2: commitConfig { $0.density = localDensity }
                        default: break
                        }
                        activeKnob = nil
                    }
            )
        }
        .frame(height: knobHeight)
    }

    /// CURR knob — streamline fan: horizontal arrows that fan out and intensify with value.
    private func drawCurrentKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55
        let color = accentColor.opacity(op)

        // Visible rows: 1 at low, 3 at mid, 5 at high
        let visibleRows: Int
        if value < 0.25 { visibleRows = 1 }
        else if value < 0.55 { visibleRows = 3 }
        else { visibleRows = 5 }

        // Center row body length proportional to value, plus arrowheads
        let maxBodyLen = max(1, Int(value * 5.0) + 1)
        let headCount = value > 0.65 ? 2 : 1

        // Scroll animation phase
        let scrollSpeed = 0.5 + value * 3.0
        let scrollPhase = fmod(time * scrollSpeed, 20.0)

        let bodyChar = value > 0.6 ? "━" : "─"

        for i in 0..<visibleRows {
            let rowOffset = i - visibleRows / 2
            let y = artCenterY + CGFloat(rowOffset) * rowH

            // Taper: outer rows shorter
            let taper = abs(rowOffset)
            let bodyLen = max(1, maxBodyLen - taper)
            let totalChars = bodyLen + headCount

            let startX = centerX - CGFloat(totalChars) * cellW / 2 + cellW / 2

            for col in 0..<totalChars {
                let x = startX + CGFloat(col) * cellW
                let isHead = col >= bodyLen

                // Scroll: wave of brightness moving rightward
                let animPhase = fmod(scrollPhase + Double(col) * 0.6 + Double(i) * 0.4, 3.0)
                let animMod = 0.65 + 0.35 * sin(animPhase * .pi)

                if isHead {
                    drawCharBold(context, "→", at: CGPoint(x: x, y: y), size: fontSize,
                                 color: color.opacity(animMod))
                } else {
                    drawChar(context, bodyChar, at: CGPoint(x: x, y: y), size: fontSize,
                             color: color.opacity(animMod * 0.85))
                }
            }
        }

        // Label + value below art
        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "CURR", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(Int(value * 100))%", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    /// VISC knob — honey vessel: a beaker shape with fill level and drip.
    private func drawViscosityKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.2
        let centerX = rect.midX
        let artTopY = rect.minY + 4 * cs

        let op: CGFloat = active ? 1.0 : 0.55
        let vesselColor = accentColor.opacity(op * 0.5)
        let fillColor = accentColor.opacity(op)

        // Vessel: 5 chars wide, 4 inner rows
        let vesselW = 5
        let innerRows = 4
        let halfW = CGFloat(vesselW) * cellW / 2
        let leftX = centerX - halfW + cellW / 2

        // Top edge: ╭───╮
        let topY = artTopY
        drawChar(context, "╭", at: CGPoint(x: leftX, y: topY), size: fontSize, color: vesselColor)
        for i in 1..<(vesselW - 1) {
            drawChar(context, "─", at: CGPoint(x: leftX + CGFloat(i) * cellW, y: topY), size: fontSize, color: vesselColor)
        }
        drawChar(context, "╮", at: CGPoint(x: leftX + CGFloat(vesselW - 1) * cellW, y: topY), size: fontSize, color: vesselColor)

        // Fill level (bottom-up)
        let fillRows = max(0, Int(value * Double(innerRows) + 0.5))

        // Fill character density scales with value
        let fillChar: String
        if value < 0.25 { fillChar = "░" }
        else if value < 0.5 { fillChar = "▒" }
        else if value < 0.75 { fillChar = "▓" }
        else { fillChar = "█" }

        for row in 0..<innerRows {
            let y = topY + CGFloat(row + 1) * rowH
            let isFilled = row >= (innerRows - fillRows)

            // Walls
            drawChar(context, "│", at: CGPoint(x: leftX, y: y), size: fontSize, color: vesselColor)
            drawChar(context, "│", at: CGPoint(x: leftX + CGFloat(vesselW - 1) * cellW, y: y), size: fontSize, color: vesselColor)

            // Interior fill
            if isFilled {
                for i in 1..<(vesselW - 1) {
                    drawChar(context, fillChar, at: CGPoint(x: leftX + CGFloat(i) * cellW, y: y), size: fontSize, color: fillColor)
                }
            }
        }

        // Bottom edge: ╰─·─╯
        let bottomY = topY + CGFloat(innerRows + 1) * rowH
        drawChar(context, "╰", at: CGPoint(x: leftX, y: bottomY), size: fontSize, color: vesselColor)
        drawChar(context, "╯", at: CGPoint(x: leftX + CGFloat(vesselW - 1) * cellW, y: bottomY), size: fontSize, color: vesselColor)
        let midCol = vesselW / 2
        for i in 1..<(vesselW - 1) {
            if i == midCol {
                let dripTopChar = value > 0.5 ? fillChar : "·"
                drawChar(context, dripTopChar, at: CGPoint(x: leftX + CGFloat(i) * cellW, y: bottomY), size: fontSize, color: fillColor.opacity(0.8))
            } else {
                drawChar(context, "─", at: CGPoint(x: leftX + CGFloat(i) * cellW, y: bottomY), size: fontSize, color: vesselColor)
            }
        }

        // Drip below vessel (animated bob)
        if value > 0.1 {
            let dripY = bottomY + rowH
            let bob = CGFloat(sin(time * 1.5)) * 2 * cs
            let dripChar: String
            if value < 0.3 { dripChar = "·" }
            else if value < 0.6 { dripChar = "•" }
            else if value < 0.8 { dripChar = "▓" }
            else { dripChar = "█" }
            drawChar(context, dripChar, at: CGPoint(x: centerX, y: dripY + bob), size: fontSize,
                     color: fillColor.opacity(0.6))
        }

        // Label + value
        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "VISC", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(Int(value * 100))%", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    /// DENS knob — particle cloud: dot matrix that fills from sparse to packed.
    private func drawDensityKnob(context: GraphicsContext, rect: CGRect, value: Double, time: Double, active: Bool) {
        let fontSize: CGFloat = max(9, 11 * cs)
        let cellW: CGFloat = fontSize * 0.65
        let rowH: CGFloat = fontSize * 1.3
        let centerX = rect.midX
        let artCenterY = rect.minY + rect.height * 0.38

        let op: CGFloat = active ? 1.0 : 0.55
        let color = accentColor.opacity(op)

        // 5×5 character grid
        let gridSize = 5
        let gridStartX = centerX - CGFloat(gridSize) * cellW / 2 + cellW / 2
        let gridStartY = artCenterY - CGFloat(gridSize) * rowH / 2 + rowH / 2

        // Shimmer tick (changes ~8 times/sec, kept small)
        let shimmerTick = Int(fmod(time * 8, 1000))

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let x = gridStartX + CGFloat(col) * cellW
                let y = gridStartY + CGFloat(row) * rowH

                // Chebyshev distance from center — center fills first
                let dx = abs(col - gridSize / 2)
                let dy = abs(row - gridSize / 2)
                let dist = max(dx, dy)

                let threshold = Double(dist) * 0.25 + 0.08
                if value < threshold { continue }

                // Char intensity based on how far past threshold
                let intensity = min(1.0, (value - threshold) / 0.3)
                let ch: String
                if intensity < 0.25 { ch = "·" }
                else if intensity < 0.5 { ch = "•" }
                else if intensity < 0.75 { ch = "●" }
                else { ch = "█" }

                // Shimmer: occasional char flicker
                let cellHash = (row * 7 + col + shimmerTick) % 11
                let shimmer = cellHash == 0 && value > 0.25
                let finalCh: String
                if shimmer {
                    if intensity < 0.5 { finalCh = intensity < 0.25 ? "•" : "·" }
                    else { finalCh = intensity < 0.75 ? "●" : "▓" }
                } else {
                    finalCh = ch
                }

                drawChar(context, finalCh, at: CGPoint(x: x, y: y), size: fontSize,
                         color: color.opacity(0.55 + intensity * 0.45))
            }
        }

        // Label + value
        let labelFontSize = fontSize * 0.8
        let labelCellW = labelFontSize * 0.62
        let labelY = rect.maxY - 22 * cs
        drawString(context, "DENS", centerX: centerX, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                   color: CanopyColors.chromeText.opacity(active ? 0.8 : 0.5), bold: true)
        let valueY = labelY + labelFontSize * 1.3
        drawString(context, "\(Int(value * 100))%", centerX: centerX, y: valueY, cellW: labelCellW,
                   fontSize: labelFontSize * 0.9,
                   color: CanopyColors.chromeText.opacity(active ? 0.7 : 0.4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * cs) {
            // Header
            HStack {
                Text("FLOW")
                    .font(.system(size: 13 * cs, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)

                ImprintButton(
                    recorder: imprintRecorder,
                    accentColor: accentColor,
                    onImprint: { imprint in
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = imprint
                            $0.spectralSource = .imprint
                        }
                        AudioEngine.shared.configureFlowImprint(imprint.harmonicAmplitudes, nodeID: nodeID)
                    },
                    onClear: {
                        guard let nodeID = projectState.selectedNodeID else { return }
                        commitConfig {
                            $0.imprint = nil
                            $0.spectralSource = .default
                        }
                        AudioEngine.shared.configureFlowImprint(nil, nodeID: nodeID)
                    },
                    hasImprint: flowConfig?.spectralSource == .imprint
                )

                Spacer()

                ModuleSwapButton(
                    options: [("Oscillator", "osc"), ("FM Drum", "drum"), ("Quake", "quake"), ("West Coast", "west"), ("Flow", "flow"), ("Tide", "tide"), ("Swarm", "swarm"), ("Spore", "spore"), ("Fuse", "fuse")],
                    current: "flow",
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
                        } else if type == "tide" {
                            projectState.swapEngine(nodeID: nodeID, to: .tide(TideConfig()))
                        } else if type == "swarm" {
                            projectState.swapEngine(nodeID: nodeID, to: .swarm(SwarmConfig()))
                        } else if type == "spore" {
                            projectState.swapEngine(nodeID: nodeID, to: .spore(SporeConfig()))
                        } else if type == "fuse" {
                            projectState.swapEngine(nodeID: nodeID, to: .fuse(FuseConfig()))
                        }
                    }
                )
            }

            // Spectral silhouette when imprinted
            if let imprint = flowConfig?.imprint, flowConfig?.spectralSource == .imprint {
                SpectralSilhouetteView(values: imprint.harmonicAmplitudes, accentColor: accentColor)
            }

            if flowConfig != nil {
                // ASCII streamline schematic hero
                flowSchematic
                    .frame(height: 160 * cs)
                    .background(
                        RoundedRectangle(cornerRadius: 4 * cs)
                            .fill(Color.black.opacity(0.3))
                    )

                HStack(alignment: .top, spacing: 10 * cs) {
                    // Left column: Fluid
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("FLUID")

                        fluidKnobs
                    }
                    .frame(maxWidth: .infinity)

                    // Vertical divider
                    CanopyColors.bloomPanelBorder.opacity(0.3)
                        .frame(width: 1)

                    // Right column: Geometry + Output
                    VStack(alignment: .leading, spacing: 8 * cs) {
                        sectionLabel("GEOMETRY")

                        paramSlider(label: "OBST", value: $localObstacle, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.obstacle = localObstacle }
                        } onDrag: { pushConfigToEngine() }

                        paramSlider(label: "CHAN", value: $localChannel, range: 0...1,
                                    format: { "\(Int($0 * 100))%" }) {
                            commitConfig { $0.channel = localChannel }
                        } onDrag: { pushConfigToEngine() }

                        sectionDivider

                        outputSection
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
        guard let config = flowConfig else { return }
        localCurrent = config.current
        localViscosity = config.viscosity
        localObstacle = config.obstacle
        localChannel = config.channel
        localDensity = config.density
        localFilter = config.filter
        localFilterMode = config.filterMode
        localWidth = config.width
        localAttack = config.attack
        localDecay = config.decay
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

            paramSlider(label: "FILT", value: $localFilter, range: 0...1,
                        format: { filterDisplayText($0) }) {
                commitConfig { $0.filter = localFilter }
            } onDrag: { pushConfigToEngine() }

            filterModeSelector

            paramSlider(label: "WDTH", value: $localWidth, range: 0...1,
                        format: { "\(Int($0 * 100))%" }) {
                commitConfig { $0.width = localWidth }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "ATK", value: $localAttack, range: 0...1,
                        format: { attackDisplayText($0) }) {
                commitConfig { $0.attack = localAttack }
            } onDrag: { pushConfigToEngine() }

            paramSlider(label: "DCY", value: $localDecay, range: 0...1,
                        format: { decayDisplayText($0) }) {
                commitConfig { $0.decay = localDecay }
            } onDrag: { pushConfigToEngine() }

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

    // MARK: - Filter Mode Selector

    private var filterModeSelector: some View {
        HStack(spacing: 3 * cs) {
            Text("    ")
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .frame(width: 38 * cs, alignment: .trailing)

            ForEach(0..<3, id: \.self) { mode in
                Button(action: {
                    localFilterMode = mode
                    commitConfig { $0.filterMode = mode }
                    pushConfigToEngine()
                }) {
                    Text(filterModeLabels[mode])
                        .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                        .foregroundColor(localFilterMode == mode ? accentColor : CanopyColors.chromeText.opacity(0.35))
                        .padding(.horizontal, 5 * cs)
                        .padding(.vertical, 2 * cs)
                        .background(
                            RoundedRectangle(cornerRadius: 3 * cs)
                                .fill(localFilterMode == mode ? accentColor.opacity(0.15) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
                              logarithmic: Bool = false,
                              format: @escaping (Double) -> String,
                              onCommit: @escaping () -> Void, onDrag: @escaping () -> Void) -> some View {
        HStack(spacing: 4 * cs) {
            Text(label)
                .font(.system(size: 8 * cs, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 38 * cs, alignment: .trailing)

            GeometryReader { geo in
                let width = geo.size.width
                let fraction: CGFloat = logarithmic
                    ? CGFloat((log(value.wrappedValue) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
                    : CGFloat((value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound))
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

            Text(format(value.wrappedValue))
                .font(.system(size: 8 * cs, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.6))
                .frame(width: 40 * cs, alignment: .trailing)
        }
    }

    // MARK: - Display Helpers

    private func filterDisplayText(_ v: Double) -> String {
        if v >= 0.99 { return "BYP" }
        let hz = 200.0 * pow(80.0, v)
        if hz < 1000 { return "\(Int(hz))Hz" }
        return String(format: "%.1fk", hz / 1000.0)
    }

    private func attackDisplayText(_ v: Double) -> String {
        let ms = 0.001 * pow(500.0, v) * 1000
        if ms < 10 { return String(format: "%.1fms", ms) }
        if ms < 1000 { return "\(Int(ms))ms" }
        return String(format: "%.1fs", ms / 1000.0)
    }

    private func decayDisplayText(_ v: Double) -> String {
        let ms = 0.05 * pow(100.0, v) * 1000
        if ms < 1000 { return "\(Int(ms))ms" }
        return String(format: "%.1fs", ms / 1000.0)
    }

    // MARK: - Commit Helpers

    private func commitConfig(_ transform: (inout FlowConfig) -> Void) {
        guard let nodeID = projectState.selectedNodeID else { return }
        projectState.updateNode(id: nodeID) { node in
            if case .flow(var config) = node.patch.soundType {
                transform(&config)
                node.patch.soundType = .flow(config)
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
        let config = FlowConfig(
            current: localCurrent,
            viscosity: localViscosity,
            obstacle: localObstacle,
            channel: localChannel,
            density: localDensity,
            warmth: localWarmth,
            volume: localVolume,
            pan: localPan,
            filter: localFilter,
            filterMode: localFilterMode,
            width: localWidth,
            attack: localAttack,
            decay: localDecay
        )
        AudioEngine.shared.configureFlow(config, nodeID: nodeID)
    }
}
