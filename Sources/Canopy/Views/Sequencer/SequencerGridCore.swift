import SwiftUI

// MARK: - Supporting Types

/// Represents an active drag-to-extend operation on a note span.
struct SpanDragState: Equatable {
    let pitch: Int
    let startStep: Int
    var currentEndStep: Int
}

/// All parameters needed to render the sequencer grid.
struct GridRenderContext {
    let pitches: [Int]
    let activeColumns: Int
    let displayColumns: Int
    let fontSize: CGFloat
    let isArpActive: Bool
    let hasEuclidean: Bool
    let arpPitches: Set<Int>
    let lookup: [Int: NoteEvent]
    let continuations: Set<Int>
    let stepVelocities: [Int: Double]
    var playheadStep: Int
    var pulse: CGFloat
    let spanDragState: SpanDragState?
    let notes: [NoteEvent]
    let showVelocityRow: Bool
}

// MARK: - Grid Core

/// Shared sequencer grid geometry, rendering, and hit-testing.
/// Used by ForestPitchedPanel (circle pattern), FocusSequencerView (Focus grid), and DrumSequencerPanel.
enum SequencerGridCore {

    // MARK: Geometry

    /// Number of character columns for the ASCII grid.
    /// Layout: ║····║····║····║ — separators every 4 steps plus edges.
    static func gridCharCols(for displayColumns: Int) -> Int {
        displayColumns + (displayColumns / 4) + 1
    }

    /// Map from step index to character column.
    static func stepToCharCol(for displayColumns: Int) -> [Int] {
        (0..<displayColumns).map { step in
            let group = step / 4
            return group + 1 + step
        }
    }

    /// Reverse map: character column → step index (nil for separator columns).
    static func charColToStep(displayColumns: Int) -> [Int?] {
        let charCols = gridCharCols(for: displayColumns)
        let fwd = stepToCharCol(for: displayColumns)
        var map = [Int?](repeating: nil, count: charCols)
        for (step, col) in fwd.enumerated() {
            if col < charCols { map[col] = step }
        }
        return map
    }

    /// Character cell width derived from font size.
    static func cellWidth(fontSize: CGFloat) -> CGFloat { fontSize * 0.78 }

    /// Character cell (row) height derived from font size.
    static func cellHeight(fontSize: CGFloat) -> CGFloat { fontSize * 1.9 }

    // MARK: Pitch Helpers

    /// Visible pitch list, highest first. When scale-aware, filters to in-scale pitches.
    static func visiblePitches(baseNote: Int, rowCount: Int, key: MusicalKey, scaleAware: Bool) -> [Int] {
        if scaleAware {
            var pitches: [Int] = []
            var p = baseNote
            while pitches.count < rowCount && p <= 127 {
                let pc = ((p % 12) - key.root.semitone + 12) % 12
                if key.mode.intervals.contains(pc) {
                    pitches.append(p)
                }
                p += 1
            }
            return pitches.reversed()
        } else {
            return ((0..<rowCount).map { baseNote + $0 }).reversed()
        }
    }

    // MARK: Draw Primitives

    static func drawChar(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .regular, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    static func drawCharBold(_ context: GraphicsContext, _ char: String, at point: CGPoint, size fontSize: CGFloat, color: Color) {
        context.draw(
            Text(char).font(.system(size: fontSize, weight: .bold, design: .monospaced)).foregroundColor(color),
            at: point, anchor: .center
        )
    }

    // MARK: Note Helpers

    /// Build O(1) lookup: key = pitch * 1000 + step → NoteEvent.
    static func buildNoteLookup(notes: [NoteEvent]) -> [Int: NoteEvent] {
        var dict = [Int: NoteEvent]()
        dict.reserveCapacity(notes.count)
        for event in notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            let key = event.pitch &* 1000 &+ step
            dict[key] = event
        }
        return dict
    }

    /// Build set of (pitch, step) keys that are span continuations (not the note start cell).
    static func buildSpanContinuationSet(notes: [NoteEvent], spanDragState: SpanDragState?) -> Set<Int> {
        let sd = NoteSequence.stepDuration
        var set = Set<Int>()
        for note in notes {
            let startStep = Int(round(note.startBeat / sd))
            let endStep: Int
            if let drag = spanDragState, drag.pitch == note.pitch && drag.startStep == startStep {
                endStep = drag.currentEndStep
            } else {
                endStep = max(startStep + 1, Int(round((note.startBeat + note.duration) / sd)))
            }
            for s in (startStep + 1)..<endStep {
                set.insert(note.pitch &* 1000 &+ s)
            }
        }
        return set
    }

    /// Pre-compute max velocity per step for the velocity row.
    static func buildStepVelocities(notes: [NoteEvent]) -> [Int: Double] {
        var dict = [Int: Double]()
        for event in notes {
            let step = Int(round(event.startBeat / NoteSequence.stepDuration))
            if let existing = dict[step] {
                if event.velocity > existing { dict[step] = event.velocity }
            } else {
                dict[step] = event.velocity
            }
        }
        return dict
    }

    /// Find nearest valid step for a character column (skipping separators).
    static func nearestStep(forCharCol charCol: Int, reverseMap: [Int?], maxStep: Int) -> Int {
        if let step = reverseMap[charCol] { return min(step, maxStep - 1) }
        for offset in 1..<reverseMap.count {
            let left = charCol - offset
            if left >= 0, let step = reverseMap[left] { return min(step, maxStep - 1) }
            let right = charCol + offset
            if right < reverseMap.count, let step = reverseMap[right] { return min(step, maxStep - 1) }
        }
        return 0
    }

    // MARK: Canvas Dimensions

    /// Compute the expected canvas size for a grid render context.
    static func canvasSize(for rc: GridRenderContext) -> CGSize {
        let cw = cellWidth(fontSize: rc.fontSize)
        let rh = cellHeight(fontSize: rc.fontSize)
        let charCols = gridCharCols(for: rc.displayColumns)
        let extraRows = 2 + (rc.showVelocityRow ? 1 : 0) // top border + bottom border + optional vel
        let totalRows = rc.pitches.count + extraRows
        return CGSize(width: CGFloat(charCols) * cw, height: CGFloat(totalRows) * rh)
    }

    // MARK: Grid Rendering

    /// Draw the complete sequencer grid into a Canvas GraphicsContext.
    static func drawGrid(_ context: GraphicsContext, rc: GridRenderContext) {
        let cw = cellWidth(fontSize: rc.fontSize)
        let rh = cellHeight(fontSize: rc.fontSize)
        let charCols = gridCharCols(for: rc.displayColumns)
        let colMap = stepToCharCol(for: rc.displayColumns)
        let reverseMap = charColToStep(displayColumns: rc.displayColumns)
        let pitchRowCount = rc.pitches.count
        let isPlaying = rc.playheadStep >= 0

        let euclideanGreen = Color(red: 0.2, green: 0.7, blue: 0.4)
        let arpCyan = Color(red: 0.2, green: 0.7, blue: 0.8)
        let borderColor = CanopyColors.chromeText.opacity(0.15)

        // === Top border row ===
        let topY = rh / 2
        for charCol in 0..<charCols {
            let x = CGFloat(charCol) * cw + cw / 2
            let stepIdx = reverseMap[charCol]
            let ch: String
            if charCol == 0 {
                ch = "╔"
            } else if charCol == charCols - 1 {
                ch = "╗"
            } else if stepIdx == nil {
                ch = "╦"
            } else {
                ch = "═"
            }
            drawChar(context, ch, at: CGPoint(x: x, y: topY), size: rc.fontSize, color: borderColor)
        }

        // === Pitch rows ===
        for (rowIdx, pitch) in rc.pitches.enumerated() {
            let y = CGFloat(rowIdx + 1) * rh + rh / 2

            for charCol in 0..<charCols {
                let x = CGFloat(charCol) * cw + cw / 2
                let stepIdx = reverseMap[charCol]

                if stepIdx == nil {
                    // Separator column: ║
                    let isPlayheadAdj = isPlaying && {
                        let phCol = colMap[rc.playheadStep]
                        return charCol == phCol - 1 || charCol == phCol + 1
                    }()
                    let sepColor = isPlayheadAdj
                        ? CanopyColors.glowColor.opacity(0.3 * Double(rc.pulse))
                        : borderColor
                    drawChar(context, "║", at: CGPoint(x: x, y: y), size: rc.fontSize, color: sepColor)
                } else if let step = stepIdx {
                    let enabled = step < rc.activeColumns
                    let isPlayhead = step == rc.playheadStep
                    let noteEvent = enabled ? rc.lookup[pitch &* 1000 &+ step] : nil
                    let isActive = noteEvent != nil
                    let isContinuation = rc.continuations.contains(pitch &* 1000 &+ step)
                    let velocity = noteEvent?.velocity ?? 0.8
                    let probability = noteEvent?.probability ?? 1.0
                    let ratchetCount = noteEvent?.ratchetCount ?? 1
                    let dimFactor: Double = enabled ? 1.0 : 0.25

                    let char: String
                    let color: Color

                    if isContinuation {
                        char = "─"
                        let baseCol: Color = rc.isArpActive ? arpCyan : (rc.hasEuclidean ? euclideanGreen : CanopyColors.gridCellActive)
                        color = isPlayhead
                            ? CanopyColors.glowColor.opacity(Double(rc.pulse))
                            : baseCol.opacity(0.4 * dimFactor)
                    } else if isActive {
                        if ratchetCount > 1 {
                            char = "╪"
                        } else if velocity < 0.3 {
                            char = "░"
                        } else if velocity < 0.6 {
                            char = "▒"
                        } else if velocity < 0.85 {
                            char = "▓"
                        } else {
                            char = "█"
                        }
                        let baseCol: Color = rc.isArpActive ? arpCyan : (rc.hasEuclidean ? euclideanGreen : CanopyColors.gridCellActive)
                        color = isPlayhead
                            ? CanopyColors.glowColor.opacity(Double(rc.pulse))
                            : baseCol.opacity((probability * 0.8 + 0.2) * dimFactor)
                    } else {
                        char = "·"
                        let arpDim = rc.arpPitches.contains(pitch) ? 0.08 : 0.0
                        color = isPlayhead
                            ? CanopyColors.glowColor.opacity(0.4 * Double(rc.pulse))
                            : CanopyColors.chromeText.opacity((enabled ? 0.15 : 0.06) + arpDim)
                    }

                    drawChar(context, char, at: CGPoint(x: x, y: y), size: rc.fontSize, color: color)
                }
            }
        }

        // === Bottom border row ===
        let borderY = CGFloat(pitchRowCount + 1) * rh + rh / 2
        for charCol in 0..<charCols {
            let x = CGFloat(charCol) * cw + cw / 2
            let stepIdx = reverseMap[charCol]
            let ch: String
            if charCol == 0 {
                ch = "╚"
            } else if charCol == charCols - 1 {
                ch = "╝"
            } else if stepIdx == nil {
                ch = "╩"
            } else {
                ch = "═"
            }
            drawChar(context, ch, at: CGPoint(x: x, y: borderY), size: rc.fontSize, color: borderColor)
        }

        // === Velocity row (optional) ===
        if rc.showVelocityRow {
            let velY = CGFloat(pitchRowCount + 2) * rh + rh / 2
            for step in 0..<rc.displayColumns {
                let charCol = colMap[step]
                let x = CGFloat(charCol) * cw + cw / 2
                let enabled = step < rc.activeColumns
                let vel = enabled ? (rc.stepVelocities[step] ?? 0) : 0.0
                let dimFactor: Double = enabled ? 1.0 : 0.25

                let ch: String
                if vel <= 0 { ch = " " }
                else if vel < 0.15 { ch = "▁" }
                else if vel < 0.30 { ch = "▂" }
                else if vel < 0.45 { ch = "▃" }
                else if vel < 0.60 { ch = "▄" }
                else if vel < 0.75 { ch = "▅" }
                else if vel < 0.90 { ch = "▆" }
                else { ch = "▇" }

                let velColor = CanopyColors.glowColor.opacity((vel > 0 ? 0.5 : 0.1) * dimFactor)
                drawChar(context, ch, at: CGPoint(x: x, y: velY), size: rc.fontSize, color: velColor)
            }
        }

        // === Drag handles on sustained notes ===
        let sd = NoteSequence.stepDuration
        let handleBaseColor: Color = rc.isArpActive
            ? Color(red: 0.2, green: 0.7, blue: 0.8)
            : CanopyColors.gridCellActive
        for note in rc.notes {
            let startStep = Int(round(note.startBeat / sd))
            let endStep: Int
            if let drag = rc.spanDragState, drag.pitch == note.pitch && drag.startStep == startStep {
                endStep = drag.currentEndStep
            } else {
                endStep = max(startStep + 1, Int(round((note.startBeat + note.duration) / sd)))
            }
            guard endStep - startStep > 1 else { continue }
            guard let rowIdx = rc.pitches.firstIndex(of: note.pitch) else { continue }
            let visibleEnd = min(endStep, rc.activeColumns)
            guard visibleEnd > startStep else { continue }
            let handleStep = visibleEnd - 1
            let handleCharCol = colMap[min(handleStep, rc.displayColumns - 1)]
            let hx = CGFloat(handleCharCol) * cw + cw / 2
            let hy = CGFloat(rowIdx + 1) * rh + rh / 2
            drawCharBold(context, "┃", at: CGPoint(x: hx + cw * 0.45, y: hy), size: rc.fontSize, color: handleBaseColor.opacity(0.8))
        }
    }
}

// MARK: - Sequencer Actions

/// Shared action methods for sequencer model mutations.
/// Used by ForestPitchedPanel (Forest) and FocusSequencerView (Focus).
enum SequencerActions {

    /// Resolve the active musical key for a node.
    static func resolveKey(projectState: ProjectState, nodeID: UUID) -> MusicalKey {
        guard let node = projectState.findNode(id: nodeID) else {
            return projectState.project.globalKey
        }
        if let override = node.scaleOverride { return override }
        if let tree = projectState.project.trees.first, let treeScale = tree.scale {
            return treeScale
        }
        return projectState.project.globalKey
    }

    /// Toggle a note on/off at a given pitch and step.
    static func toggleNote(projectState: ProjectState, nodeID: UUID, pitch: Int, step: Int) {
        let sd = NoteSequence.stepDuration
        let stepBeat = Double(step) * sd

        projectState.updateNode(id: nodeID) { node in
            if let existingIndex = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && Int(round($0.startBeat / sd)) == step
            }) {
                node.sequence.notes.remove(at: existingIndex)
            } else {
                let dur = node.sequence.arpConfig != nil
                    ? node.sequence.lengthInBeats - stepBeat
                    : NoteSequence.stepDuration
                let event = NoteEvent(
                    pitch: pitch,
                    velocity: 0.8,
                    startBeat: stepBeat,
                    duration: dur
                )
                node.sequence.notes.append(event)
            }
            node.sequence.euclidean = nil
        }

        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Commit a span drag: update note duration.
    static func commitSpanDrag(projectState: ProjectState, nodeID: UUID, pitch: Int, startStep: Int, newEndStep: Int) {
        let sd = NoteSequence.stepDuration

        projectState.updateNode(id: nodeID) { node in
            if let idx = node.sequence.notes.firstIndex(where: {
                $0.pitch == pitch && Int(round($0.startBeat / sd)) == startStep
            }) {
                let newDuration = Double(newEndStep - startStep) * sd
                node.sequence.notes[idx].duration = max(sd, newDuration)
            }
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Reload the audio engine sequence for a node.
    /// Applies pre-computed Forest transforms (FIFTH, INVERT, BLOOM, DENSITY, MIRROR, GATE, SWING)
    /// before sending events to the audio engine.
    static func reloadSequence(projectState: ProjectState, nodeID: UUID) {
        guard let node = projectState.findNode(id: nodeID) else { return }
        let seq = node.sequence
        let key = resolveKey(projectState: projectState, nodeID: nodeID)

        let events = SequenceTransforms.transformedEvents(from: seq, key: key)

        let mutation = seq.mutation
        AudioEngine.shared.loadSequence(
            events, lengthInBeats: seq.lengthInBeats, nodeID: nodeID,
            direction: seq.playbackDirection ?? .forward,
            mutationAmount: mutation?.amount ?? 0,
            mutationRange: mutation?.range ?? 0,
            scaleRootSemitone: key.root.semitone,
            scaleIntervals: key.mode.intervals
        )

        if seq.arpConfig != nil {
            projectState.rebuildArpPool(for: nodeID)
        }
    }

    /// Commit global probability value.
    static func commitGlobalProbability(_ value: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.globalProbability = value
        }
        AudioEngine.shared.setGlobalProbability(value, nodeID: nodeID)
    }

    /// Commit mutation amount value.
    static func commitMutationAmount(_ amount: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.mutation == nil {
                node.sequence.mutation = MutationConfig(amount: amount, range: 1)
            } else {
                node.sequence.mutation?.amount = amount
            }
        }
        let key = resolveKey(projectState: projectState, nodeID: nodeID)
        let range = projectState.findNode(id: nodeID)?.sequence.mutation?.range ?? 1
        AudioEngine.shared.setMutation(
            amount: amount,
            range: range,
            rootSemitone: key.root.semitone,
            intervals: key.mode.intervals,
            nodeID: nodeID
        )
    }

    /// Change sequence length (step count).
    static func changeLength(to newStepCount: Int, projectState: ProjectState, nodeID: UUID) {
        let sd = NoteSequence.stepDuration
        let newLengthBeats = Double(newStepCount) * sd
        projectState.updateNode(id: nodeID) { node in
            node.sequence.notes.removeAll { $0.startBeat >= newLengthBeats }
            for i in 0..<node.sequence.notes.count {
                let note = node.sequence.notes[i]
                let endBeat = note.startBeat + note.duration
                if endBeat > newLengthBeats {
                    node.sequence.notes[i].duration = newLengthBeats - note.startBeat
                }
            }
            node.sequence.lengthInBeats = newLengthBeats
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set playback direction.
    static func setDirection(_ dir: PlaybackDirection, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.playbackDirection = dir == .forward ? nil : dir
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Apply euclidean pattern.
    static func applyEuclidean(pulses: Int, rotation: Int, wobble: Double = 0, projectState: ProjectState, nodeID: UUID) {
        let key = resolveKey(projectState: projectState, nodeID: nodeID)
        let config = EuclideanConfig(pulses: pulses, rotation: rotation, wobble: wobble)
        projectState.updateNode(id: nodeID) { node in
            SequenceFillService.applyEuclidean(
                sequence: &node.sequence,
                config: config,
                key: key,
                pitchRange: node.sequence.pitchRange
            )
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set wobble amount and regenerate the euclidean pattern at new step positions.
    static func setWobble(_ wobble: Double, projectState: ProjectState, nodeID: UUID) {
        guard let node = projectState.findNode(id: nodeID),
              let euc = node.sequence.euclidean else { return }
        applyEuclidean(pulses: euc.pulses, rotation: euc.rotation, wobble: wobble, projectState: projectState, nodeID: nodeID)
    }

    /// Random fill.
    static func randomFill(projectState: ProjectState, nodeID: UUID) {
        let key = resolveKey(projectState: projectState, nodeID: nodeID)
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.euclidean != nil {
                SequenceFillService.randomScaleFill(
                    sequence: &node.sequence,
                    key: key,
                    pitchRange: node.sequence.pitchRange
                )
            } else {
                SequenceFillService.randomFill(
                    sequence: &node.sequence,
                    key: key,
                    pitchRange: node.sequence.pitchRange,
                    density: 0.5
                )
            }
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set mutation range.
    static func setMutationRange(_ range: Int, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.mutation == nil {
                node.sequence.mutation = MutationConfig(amount: 0.1, range: range)
            } else {
                node.sequence.mutation?.range = range
            }
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set octave offset.
    static func setOctaveOffset(_ offset: Int, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.octaveOffset = offset == 0 ? nil : offset
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Freeze current mutations into the pattern.
    static func freezeMutation(nodeID: UUID) {
        AudioEngine.shared.freezeMutation(nodeID: nodeID)
    }

    /// Reset mutations back to original pattern.
    static func resetMutation(nodeID: UUID) {
        AudioEngine.shared.resetMutation(nodeID: nodeID)
    }

    // MARK: Arp Actions

    /// Set arp mode.
    static func setArpMode(_ mode: ArpMode, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.mode = mode
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    /// Set arp rate.
    static func setArpRate(_ rate: ArpRate, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.rate = rate
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    /// Set arp octave range.
    static func setArpOctave(_ octave: Int, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.octaveRange = octave
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    /// Commit arp gate length.
    static func commitArpGate(_ gateLength: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.arpConfig?.gateLength = gateLength
        }
        projectState.rebuildArpPool(for: nodeID)
    }

    /// Toggle arp on/off. Caller should syncSeqFromModel after.
    static func toggleArp(projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            if node.sequence.arpConfig != nil {
                node.sequence.arpConfig = nil
            } else {
                node.sequence.arpConfig = ArpConfig()
                let len = node.sequence.lengthInBeats
                for i in 0..<node.sequence.notes.count {
                    let note = node.sequence.notes[i]
                    let remaining = len - note.startBeat
                    if note.duration < remaining {
                        node.sequence.notes[i].duration = remaining
                    }
                }
            }
        }
        if let node = projectState.findNode(id: nodeID) {
            if node.sequence.arpConfig != nil {
                projectState.rebuildArpPool(for: nodeID)
            } else {
                projectState.disableArp(for: nodeID)
            }
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    // MARK: - Forest Sequencer Actions

    /// Set circle-of-fifths rotation.
    static func setFifthRotation(_ rotation: Int, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.fifthRotation = rotation == 0 ? nil : rotation
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set bloom (note extension) amount.
    static func setBloomAmount(_ amount: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.bloomAmount = amount > 0 ? amount : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Toggle melodic inversion.
    static func toggleInvert(projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            let wasOn = node.sequence.invertEnabled ?? false
            node.sequence.invertEnabled = wasOn ? nil : true
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set inversion pivot note.
    static func setInvertPivot(_ pivot: Int, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.invertPivot = pivot
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set pattern density.
    static func setDensity(_ density: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.density = density < 1.0 ? density : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Toggle retrograde (mirror).
    static func toggleMirror(projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            let wasOn = node.sequence.mirrorEnabled ?? false
            node.sequence.mirrorEnabled = wasOn ? nil : true
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set phase drift rate.
    static func setDriftRate(_ rate: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.driftRate = rate > 0 ? rate : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set humanize amount.
    static func setHumanize(_ amount: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.humanize = amount > 0 ? amount : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set swing amount.
    static func setSwing(_ amount: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.swing = amount > 0 ? amount : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

    /// Set gate length.
    static func setGateLength(_ length: Double, projectState: ProjectState, nodeID: UUID) {
        projectState.updateNode(id: nodeID) { node in
            node.sequence.gateLength = length < 1.0 ? length : nil
        }
        reloadSequence(projectState: projectState, nodeID: nodeID)
    }

}
