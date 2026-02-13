import SwiftUI

/// Bloom-positioned piano keyboard.
/// Wrapped in the same panel styling as other bloom elements.
struct KeyboardBarView: View {
    @Environment(\.canvasScale) var cs
    @Binding var baseOctave: Int
    /// The currently selected node ID — keyboard plays into this node.
    var selectedNodeID: UUID?

    @State private var pressedNotes: Set<Int> = []

    private var whiteKeyWidth: CGFloat { 24 * cs }
    private var whiteKeyHeight: CGFloat { 56 * cs }
    private var blackKeyWidth: CGFloat { 15 * cs }
    private var blackKeyHeight: CGFloat { 34 * cs }
    private let octaveCount = 2

    private static let whiteKeyOffsets = [0, 2, 4, 5, 7, 9, 11]
    private static let blackKeyAfterWhite = [0, 2, 5, 7, 9]

    // Total width: 14 white keys * (24 + 1 spacing) - 1 + padding
    private var totalKeysWidth: CGFloat {
        CGFloat(octaveCount * 7) * (whiteKeyWidth + 1 * cs) - 1 * cs
    }

    private func midiNote(octave: Int, semitone: Int) -> Int {
        (octave + 1) * 12 + semitone
    }

    var body: some View {
        VStack(spacing: 6 * cs) {
            HStack(spacing: 0) {
                Button(action: { if baseOctave > 0 { baseOctave -= 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10 * cs, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24 * cs, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)

                // Piano — fixed-size container so ZStack layers stay together
                keyboardView
                    .frame(width: totalKeysWidth, height: whiteKeyHeight)
                    .clipped()

                Button(action: { if baseOctave < 7 { baseOctave += 1 } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10 * cs, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24 * cs, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)
            }

            Text("play into focused node")
                .font(.system(size: 11 * cs, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.35))
        }
        .padding(.horizontal, 12 * cs)
        .padding(.vertical, 10 * cs)
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

    private var keyboardView: some View {
        ZStack(alignment: .topLeading) {
            // White keys
            HStack(spacing: 1 * cs) {
                ForEach(0..<(octaveCount * 7), id: \.self) { index in
                    let octave = baseOctave + (index / 7)
                    let whiteIndex = index % 7
                    let semitone = Self.whiteKeyOffsets[whiteIndex]
                    let note = midiNote(octave: octave, semitone: semitone)
                    whiteKey(note: note)
                }
            }

            // Black keys overlaid
            HStack(spacing: 1 * cs) {
                ForEach(0..<(octaveCount * 7), id: \.self) { index in
                    let octave = baseOctave + (index / 7)
                    let whiteIndex = index % 7
                    let semitone = Self.whiteKeyOffsets[whiteIndex]

                    if Self.blackKeyAfterWhite.contains(semitone) {
                        ZStack {
                            Color.clear
                                .frame(width: whiteKeyWidth, height: blackKeyHeight)
                            blackKey(note: midiNote(octave: octave, semitone: semitone + 1))
                                .offset(x: (whiteKeyWidth + 1 * cs) / 2)
                        }
                        .frame(width: whiteKeyWidth + 1 * cs, height: blackKeyHeight)
                    } else {
                        Color.clear
                            .frame(width: whiteKeyWidth + 1 * cs, height: blackKeyHeight)
                    }
                }
            }
        }
    }

    private func whiteKey(note: Int) -> some View {
        let isPressed = pressedNotes.contains(note)
        return RoundedRectangle(cornerRadius: 2 * cs)
            .fill(isPressed
                  ? Color(red: 0.4, green: 0.6, blue: 0.45)
                  : Color(red: 0.55, green: 0.58, blue: 0.55))
            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressedNotes.contains(note) {
                            pressedNotes.insert(note)
                            if let nodeID = selectedNodeID {
                                AudioEngine.shared.noteOn(pitch: note, velocity: 0.8, nodeID: nodeID)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressedNotes.remove(note)
                        if let nodeID = selectedNodeID {
                            AudioEngine.shared.noteOff(pitch: note, nodeID: nodeID)
                        }
                    }
            )
    }

    private func blackKey(note: Int) -> some View {
        let isPressed = pressedNotes.contains(note)
        return RoundedRectangle(cornerRadius: 2 * cs)
            .fill(isPressed
                  ? Color(red: 0.25, green: 0.4, blue: 0.3)
                  : Color(red: 0.25, green: 0.28, blue: 0.26))
            .frame(width: blackKeyWidth, height: blackKeyHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressedNotes.contains(note) {
                            pressedNotes.insert(note)
                            if let nodeID = selectedNodeID {
                                AudioEngine.shared.noteOn(pitch: note, velocity: 0.8, nodeID: nodeID)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressedNotes.remove(note)
                        if let nodeID = selectedNodeID {
                            AudioEngine.shared.noteOff(pitch: note, nodeID: nodeID)
                        }
                    }
            )
    }
}
