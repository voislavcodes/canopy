import SwiftUI

/// Bloom-positioned piano keyboard — Canvas-based ASCII art rendering.
struct KeyboardBarView: View {
    @Environment(\.canvasScale) var cs
    @Binding var baseOctave: Int
    /// The currently selected node ID — keyboard plays into this node.
    var selectedNodeID: UUID?
    @ObservedObject var projectState: ProjectState
    var transportState: TransportState

    @State private var pressedNotes: Set<Int> = []
    @State private var activeGestureNote: Int? = nil

    private let octaveCount = 2
    private static let whiteKeyOffsets = [0, 2, 4, 5, 7, 9, 11]
    private static let blackKeyAfterWhite = [0, 2, 5, 7, 9]

    private let accentColor = Color(red: 0.4, green: 0.75, blue: 0.5)

    /// Combined pressed notes from mouse/touch and computer keyboard.
    private var allPressedNotes: Set<Int> {
        pressedNotes.union(projectState.computerKeyPressedNotes)
    }

    private func midiNote(octave: Int, semitone: Int) -> Int {
        (octave + 1) * 12 + semitone
    }

    private var scaleAwareEnabled: Bool {
        projectState.project.scaleAwareEnabled
    }

    private var resolvedKey: MusicalKey {
        guard let node = projectState.selectedNode else { return projectState.project.globalKey }
        if let override = node.scaleOverride { return override }
        if let tree = projectState.project.trees.first, let treeScale = tree.scale { return treeScale }
        return projectState.project.globalKey
    }

    private func isBlackKey(_ midiNote: Int) -> Bool {
        let pc = midiNote % 12
        return [1, 3, 6, 8, 10].contains(pc)
    }

    // MARK: - Key Geometry

    private struct KeyRect {
        let rect: CGRect
        let midiNote: Int
        let isBlack: Bool
    }

    private var kbHeight: CGFloat {
        8.5 * max(9, 10 * cs) * 1.35
    }

    var body: some View {
        VStack(spacing: 6 * cs) {
            HStack(spacing: 4 * cs) {
                ModuleSwapButton(
                    options: [("Keyboard", InputMode.keyboard), ("Pads", InputMode.padGrid)],
                    current: projectState.selectedNode?.inputMode ?? .keyboard,
                    onChange: { mode in
                        guard let nodeID = selectedNodeID else { return }
                        projectState.swapInput(nodeID: nodeID, to: mode)
                    }
                )
                Spacer()
            }
            HStack(spacing: 0) {
                Button(action: { if baseOctave > 0 { baseOctave -= 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10 * cs, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24 * cs, height: kbHeight)
                }
                .buttonStyle(.plain)

                if scaleAwareEnabled {
                    asciiFoldedKeyboardView
                } else {
                    asciiKeyboardView
                }

                Button(action: { if baseOctave < 7 { baseOctave += 1 } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10 * cs, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24 * cs, height: kbHeight)
                }
                .buttonStyle(.plain)
            }

            if selectedNodeID != nil {
                captureControlsView
            }
        }
        .padding(.top, 36 * cs)
        .padding(.horizontal, 12 * cs)
        .padding(.bottom, 10 * cs)
        .background(CanopyColors.bloomPanelBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10 * cs))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * cs)
                .stroke(CanopyColors.bloomPanelBorder.opacity(0.5), lineWidth: 1)
        )
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    // MARK: - Key Rect Computation

    private func standardKeyRects(canvasWidth: CGFloat, canvasHeight: CGFloat) -> [KeyRect] {
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let whiteKeyW = 4 * cellW
        let blackKeyW = 3 * cellW
        let blackKeyH = 4 * rowH  // rows 0-3 (top + 2 body + join)
        let whiteCount = octaveCount * 7

        // Which white-key-within-octave indices have a black key after them
        let blackAfterWhiteIdx: Set<Int> = [0, 1, 3, 4, 5]

        var rects: [KeyRect] = []

        // White keys — full height
        for i in 0..<whiteCount {
            let octave = baseOctave + (i / 7)
            let whiteIndex = i % 7
            let semitone = Self.whiteKeyOffsets[whiteIndex]
            let note = midiNote(octave: octave, semitone: semitone)
            rects.append(KeyRect(rect: CGRect(x: CGFloat(i) * whiteKeyW, y: 0, width: whiteKeyW, height: canvasHeight), midiNote: note, isBlack: false))
        }

        // Black keys — grid-aligned within the parent white key's interior columns
        for i in 0..<whiteCount {
            let octave = baseOctave + (i / 7)
            let whiteIndex = i % 7
            guard blackAfterWhiteIdx.contains(whiteIndex) else { continue }
            let semitone = Self.whiteKeyOffsets[whiteIndex]
            let note = midiNote(octave: octave, semitone: semitone + 1)
            let x = CGFloat(i * 4 + 1) * cellW  // col i*4+1
            rects.append(KeyRect(rect: CGRect(x: x, y: 0, width: blackKeyW, height: blackKeyH), midiNote: note, isBlack: true))
        }

        return rects
    }

    private func foldedKeyRects(canvasWidth: CGFloat, canvasHeight: CGFloat) -> [KeyRect] {
        let key = resolvedKey
        let low = midiNote(octave: baseOctave, semitone: 0)
        let high = midiNote(octave: baseOctave + octaveCount, semitone: 0) - 1
        let scaleNotes = key.notesInRange(low: low, high: high)
        guard !scaleNotes.isEmpty else { return [] }

        let keyW = canvasWidth / CGFloat(scaleNotes.count)
        var rects: [KeyRect] = []
        for (i, note) in scaleNotes.enumerated() {
            let x = CGFloat(i) * keyW
            rects.append(KeyRect(rect: CGRect(x: x, y: 0, width: keyW, height: canvasHeight), midiNote: note, isBlack: isBlackKey(note)))
        }
        return rects
    }

    private func hitTest(point: CGPoint, keyRects: [KeyRect]) -> Int? {
        // Check black keys first (they're appended after white keys in standard mode)
        for kr in keyRects.reversed() {
            if kr.isBlack && kr.rect.contains(point) { return kr.midiNote }
        }
        for kr in keyRects {
            if !kr.isBlack && kr.rect.contains(point) { return kr.midiNote }
        }
        return nil
    }

    // MARK: - Note On/Off Helpers

    private func startNote(_ note: Int?) {
        guard let note = note else { return }
        guard !pressedNotes.contains(note) else { return }
        pressedNotes.insert(note)
        activeGestureNote = note
        if let nodeID = selectedNodeID {
            AudioEngine.shared.noteOn(pitch: note, velocity: 0.8, nodeID: nodeID)
        }
        let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
        projectState.captureBuffer.noteOn(pitch: note, velocity: 0.8, atBeat: beat)
    }

    private func endNote(_ note: Int?) {
        guard let note = note else { return }
        pressedNotes.remove(note)
        if let nodeID = selectedNodeID {
            AudioEngine.shared.noteOff(pitch: note, nodeID: nodeID)
        }
        let beat = projectState.currentCaptureBeat(bpm: transportState.bpm)
        projectState.captureBuffer.noteOff(pitch: note, atBeat: beat)
    }

    // MARK: - Gesture

    private func keyboardGesture(keyRects: [KeyRect]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let hitNote = hitTest(point: drag.location, keyRects: keyRects)
                if activeGestureNote == nil {
                    startNote(hitNote)
                } else if hitNote != activeGestureNote {
                    endNote(activeGestureNote)
                    startNote(hitNote)
                }
            }
            .onEnded { _ in
                endNote(activeGestureNote)
                activeGestureNote = nil
            }
    }

    // MARK: - ASCII Standard Keyboard

    private var asciiKeyboardView: some View {
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let whiteKeyW = 4 * cellW
        let canvasW = CGFloat(octaveCount * 7) * whiteKeyW

        return GeometryReader { geo in
            let width = canvasW
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                Canvas { context, size in
                    let kRects = standardKeyRects(canvasWidth: width, canvasHeight: size.height)
                    drawStandardKeyboard(context: context, size: CGSize(width: width, height: size.height),
                                         keyRects: kRects,
                                         time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(width: width, height: kbHeight)
            .contentShape(Rectangle())
            .gesture(keyboardGesture(keyRects: standardKeyRects(canvasWidth: width, canvasHeight: kbHeight)))
        }
        .frame(width: canvasW, height: kbHeight)
    }

    /// Grid-based standard keyboard drawing. Rows 0-3 = black key zone, row 4 = join, rows 5-7 = white body, row 8 = white bottom.
    private func drawStandardKeyboard(context: GraphicsContext, size: CGSize, keyRects: [KeyRect], time: Double) {
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let pressed = allPressedNotes
        let pulse: CGFloat = 0.85 + 0.15 * CGFloat(sin(time * 6))

        let whiteCount = octaveCount * 7
        let numCols = whiteCount * 4 + 1  // 57 for 2 octaves
        let blackAfterIdx: Set<Int> = [0, 1, 3, 4, 5]  // within-octave white key indices

        // Build note arrays
        var whiteNotes: [Int] = []
        var hasBlack: [Bool] = []
        var blackNotes: [Int] = []
        for i in 0..<whiteCount {
            let oct = baseOctave + (i / 7)
            let wi = i % 7
            let semi = Self.whiteKeyOffsets[wi]
            whiteNotes.append(midiNote(octave: oct, semitone: semi))
            hasBlack.append(blackAfterIdx.contains(wi))
            blackNotes.append(midiNote(octave: oct, semitone: semi + 1))
        }

        // Helpers
        func colX(_ col: Int) -> CGFloat { CGFloat(col) * cellW + cellW / 2 }
        func rowY(_ row: Int) -> CGFloat { CGFloat(row) * rowH + rowH / 2 }
        func wKey(_ col: Int) -> Int { min(whiteCount - 1, col / 4) }

        let borderDim = CanopyColors.chromeText.opacity(0.3)
        let blackBorderDim = CanopyColors.chromeText.opacity(0.2)
        let whiteFill = Color(red: 0.52, green: 0.56, blue: 0.53)
        let blackFill = Color(red: 0.18, green: 0.2, blue: 0.19)

        // === Row 0: Black key tops ===
        for w in 0..<whiteCount where hasBlack[w] {
            let isP = pressed.contains(blackNotes[w])
            let bc = isP ? accentColor.opacity(0.8) : blackBorderDim
            let c = w * 4 + 1
            drawChar(context, "┌", at: CGPoint(x: colX(c), y: rowY(0)), size: fontSize, color: bc)
            drawChar(context, "─", at: CGPoint(x: colX(c+1), y: rowY(0)), size: fontSize, color: bc)
            drawChar(context, "┐", at: CGPoint(x: colX(c+2), y: rowY(0)), size: fontSize, color: bc)
        }

        // === Rows 1-3: Black key body ===
        for row in 1...3 {
            for w in 0..<whiteCount where hasBlack[w] {
                let isP = pressed.contains(blackNotes[w])
                let bc = isP ? accentColor.opacity(0.8) : blackBorderDim
                let fc = isP ? accentColor.opacity(Double(pulse) * 0.9) : blackFill
                let ch = isP ? "█" : "▓"
                let c = w * 4 + 1
                let y = rowY(row)
                drawChar(context, "│", at: CGPoint(x: colX(c), y: y), size: fontSize, color: bc)
                drawChar(context, ch, at: CGPoint(x: colX(c+1), y: y), size: fontSize, color: fc)
                drawChar(context, "│", at: CGPoint(x: colX(c+2), y: y), size: fontSize, color: bc)
            }
        }

        // === Row 4: Join row — black key bottoms meet white key tops ===
        for col in 0..<numCols {
            let w = wKey(col)
            let wPressed = pressed.contains(whiteNotes[w])
            let bc = wPressed ? accentColor.opacity(Double(pulse) * 0.7) : borderDim
            let ch: String
            if col == 0 {
                ch = "┌"
            } else if col == numCols - 1 {
                ch = "┐"
            } else if col % 4 == 0 {
                ch = "┬"
            } else {
                let inPos = col % 4  // 1, 2, or 3
                if hasBlack[w] && (inPos == 1 || inPos == 3) {
                    ch = "┴"
                } else {
                    ch = "─"
                }
            }
            drawChar(context, ch, at: CGPoint(x: colX(col), y: rowY(4)), size: fontSize, color: bc)
        }

        // === Rows 5-6: White key body with █ fill ===
        for row in 5...6 {
            let y = rowY(row)
            for col in 0..<numCols {
                let w = wKey(col)
                let isP = pressed.contains(whiteNotes[w])
                if col % 4 == 0 || col == numCols - 1 {
                    // Border column
                    drawChar(context, "│", at: CGPoint(x: colX(col), y: y), size: fontSize, color: borderDim)
                } else {
                    // Interior — always filled
                    if isP {
                        drawChar(context, "█", at: CGPoint(x: colX(col), y: y), size: fontSize, color: accentColor.opacity(Double(pulse) * 0.65))
                    } else {
                        drawChar(context, "█", at: CGPoint(x: colX(col), y: y), size: fontSize, color: whiteFill.opacity(0.4))
                    }
                }
            }
        }

        // === Row 7: White key bottom ===
        for col in 0..<numCols {
            let w = wKey(col)
            let isP = pressed.contains(whiteNotes[w])
            let bc = isP ? accentColor.opacity(Double(pulse) * 0.7) : borderDim
            let ch: String
            if col == 0 { ch = "└" }
            else if col == numCols - 1 { ch = "┘" }
            else if col % 4 == 0 { ch = "┴" }
            else { ch = "─" }
            drawChar(context, ch, at: CGPoint(x: colX(col), y: rowY(7)), size: fontSize, color: bc)
        }

        // === Octave labels ===
        let labelFontSize = fontSize * 0.75
        let labelCellW = labelFontSize * 0.62
        let labelY = rowY(7) + rowH * 0.85
        for w in 0..<whiteCount where whiteNotes[w] % 12 == 0 {
            let oct = (whiteNotes[w] / 12) - 1
            let cx = CGFloat(w * 4 + 2) * cellW + cellW / 2
            drawString(context, "C\(oct)", centerX: cx, y: labelY, cellW: labelCellW, fontSize: labelFontSize,
                       color: CanopyColors.chromeText.opacity(0.35))
        }
    }

    // MARK: - ASCII Folded Keyboard

    private var asciiFoldedKeyboardView: some View {
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let whiteKeyW = 4 * cellW
        let key = resolvedKey
        let low = midiNote(octave: baseOctave, semitone: 0)
        let high = midiNote(octave: baseOctave + octaveCount, semitone: 0) - 1
        let noteCount = max(1, key.notesInRange(low: low, high: high).count)
        let canvasW = CGFloat(noteCount) * whiteKeyW

        return GeometryReader { geo in
            let width = canvasW
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
                Canvas { context, size in
                    let kRects = foldedKeyRects(canvasWidth: width, canvasHeight: size.height)
                    drawFoldedKeyboard(context: context, size: CGSize(width: width, height: size.height),
                                       keyRects: kRects,
                                       time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(width: width, height: kbHeight)
            .contentShape(Rectangle())
            .gesture(keyboardGesture(keyRects: foldedKeyRects(canvasWidth: width, canvasHeight: kbHeight)))
        }
        .frame(width: canvasW, height: kbHeight)
    }

    private func drawFoldedKeyboard(context: GraphicsContext, size: CGSize, keyRects: [KeyRect], time: Double) {
        let fontSize: CGFloat = max(9, 10 * cs)
        let cellW: CGFloat = fontSize * 0.62
        let rowH: CGFloat = fontSize * 1.35
        let pressed = allPressedNotes
        let pulse: CGFloat = 0.85 + 0.15 * CGFloat(sin(time * 6))

        let whiteFill = Color(red: 0.52, green: 0.56, blue: 0.53)
        let blackFill = Color(red: 0.3, green: 0.33, blue: 0.31)
        let borderDim = CanopyColors.chromeText.opacity(0.3)

        // 6 body rows + top/bottom border + label = 8 rows
        let bodyRows = 5

        for kr in keyRects {
            let isP = pressed.contains(kr.midiNote)
            let cols = max(1, Int(kr.rect.width / cellW))
            let x0 = kr.rect.minX

            // Top border
            for col in 0..<cols {
                let x = x0 + CGFloat(col) * cellW + cellW / 2
                let ch: String
                if col == 0 { ch = "┌" }
                else if col == cols - 1 { ch = "┐" }
                else { ch = "─" }
                drawChar(context, ch, at: CGPoint(x: x, y: rowH / 2), size: fontSize, color: borderDim)
            }

            // Body rows — all filled with █
            for row in 1...bodyRows {
                let y = CGFloat(row) * rowH + rowH / 2
                drawChar(context, "│", at: CGPoint(x: x0 + cellW / 2, y: y), size: fontSize, color: borderDim)
                if cols > 1 {
                    drawChar(context, "│", at: CGPoint(x: x0 + CGFloat(cols - 1) * cellW + cellW / 2, y: y), size: fontSize, color: borderDim)
                }
                for col in 1..<max(1, cols - 1) {
                    let x = x0 + CGFloat(col) * cellW + cellW / 2
                    if isP {
                        drawChar(context, "█", at: CGPoint(x: x, y: y), size: fontSize, color: accentColor.opacity(Double(pulse) * 0.65))
                    } else if kr.isBlack {
                        drawChar(context, "▓", at: CGPoint(x: x, y: y), size: fontSize, color: blackFill.opacity(0.6))
                    } else {
                        drawChar(context, "█", at: CGPoint(x: x, y: y), size: fontSize, color: whiteFill.opacity(0.4))
                    }
                }
            }

            // Bottom border
            let bottomY = CGFloat(bodyRows + 1) * rowH + rowH / 2
            for col in 0..<cols {
                let x = x0 + CGFloat(col) * cellW + cellW / 2
                let ch: String
                if col == 0 { ch = "└" }
                else if col == cols - 1 { ch = "┘" }
                else { ch = "─" }
                drawChar(context, ch, at: CGPoint(x: x, y: bottomY), size: fontSize, color: borderDim)
            }

            // Note name
            let labelY = CGFloat(bodyRows + 2) * rowH + rowH / 2
            let labelFontSize = fontSize * 0.75
            let labelCellW = labelFontSize * 0.62
            drawString(context, MIDIUtilities.noteName(forNote: kr.midiNote),
                       centerX: x0 + kr.rect.width / 2, y: labelY,
                       cellW: labelCellW, fontSize: labelFontSize,
                       color: CanopyColors.chromeText.opacity(isP ? 0.7 : 0.4))
        }
    }

    // MARK: - Capture Controls

    private var captureControlsView: some View {
        let hasContent = !projectState.captureBuffer.isEmpty

        return HStack(spacing: 8) {
            // Capture button
            Button(action: {
                if projectState.capturePerformance() {
                    reloadSequenceAfterCapture()
                }
            }) {
                Circle()
                    .fill(hasContent
                          ? Color(red: 0.7, green: 0.2, blue: 0.2)
                          : Color(red: 0.3, green: 0.3, blue: 0.3))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            // Quantize strength
            Text("Q")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))

            Slider(value: $projectState.captureQuantizeStrength, in: 0...1)
                .frame(width: 60)
                .tint(Color(red: 0.4, green: 0.6, blue: 0.45))

            Text("\(Int(projectState.captureQuantizeStrength * 100))%")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                .frame(width: 28, alignment: .trailing)

            // Mode toggle
            HStack(spacing: 2) {
                modeButton(label: "R", mode: .replace)
                modeButton(label: "M", mode: .merge)
            }
        }
    }

    private func modeButton(label: String, mode: CaptureMode) -> some View {
        let isActive = projectState.captureMode == mode
        return Button(action: { projectState.captureMode = mode }) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? Color.white : CanopyColors.chromeText.opacity(0.4))
                .frame(width: 18, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive
                              ? Color(red: 0.3, green: 0.5, blue: 0.35)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - ASCII Drawing Primitives

    private func drawChar(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    private func drawCharBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

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

    private func reloadSequenceAfterCapture() {
        guard let node = projectState.selectedNode,
              let nodeID = projectState.selectedNodeID else { return }
        let seq = node.sequence
        let events = seq.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration,
                probability: event.probability,
                ratchetCount: event.ratchetCount
            )
        }
        let key = resolvedKey
        let mutation = seq.mutation
        AudioEngine.shared.loadSequence(
            events, lengthInBeats: seq.lengthInBeats, nodeID: nodeID,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals,
            accumulatorConfig: seq.accumulator
        )
    }
}
