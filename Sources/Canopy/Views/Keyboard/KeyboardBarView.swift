import SwiftUI

/// Persistent bottom bar with a compact piano keyboard.
/// Matches the mockup: gray/white keys with "play into focused node" label.
struct KeyboardBarView: View {
    @Binding var baseOctave: Int

    @State private var pressedNotes: Set<Int> = []

    private let whiteKeyWidth: CGFloat = 24
    private let whiteKeyHeight: CGFloat = 56
    private let blackKeyWidth: CGFloat = 15
    private let blackKeyHeight: CGFloat = 34
    private let octaveCount = 2

    private static let whiteKeyOffsets = [0, 2, 4, 5, 7, 9, 11]
    private static let blackKeyAfterWhite = [0, 2, 5, 7, 9]

    private func midiNote(octave: Int, semitone: Int) -> Int {
        (octave + 1) * 12 + semitone
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                // Octave down
                Button(action: { if baseOctave > 0 { baseOctave -= 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)

                // Piano keys
                keyboardView
                    .padding(.horizontal, 2)

                // Octave up
                Button(action: { if baseOctave < 7 { baseOctave += 1 } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText.opacity(0.5))
                        .frame(width: 24, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)
            }

            Text("play into focused node")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(CanopyColors.chromeText.opacity(0.35))
        }
    }

    private var keyboardView: some View {
        ZStack(alignment: .topLeading) {
            // White keys
            HStack(spacing: 1) {
                ForEach(0..<(octaveCount * 7), id: \.self) { index in
                    let octave = baseOctave + (index / 7)
                    let whiteIndex = index % 7
                    let semitone = Self.whiteKeyOffsets[whiteIndex]
                    let note = midiNote(octave: octave, semitone: semitone)
                    whiteKey(note: note)
                }
            }

            // Black keys
            HStack(spacing: 1) {
                ForEach(0..<(octaveCount * 7), id: \.self) { index in
                    let octave = baseOctave + (index / 7)
                    let whiteIndex = index % 7
                    let semitone = Self.whiteKeyOffsets[whiteIndex]

                    if Self.blackKeyAfterWhite.contains(semitone) {
                        ZStack {
                            Color.clear
                                .frame(width: whiteKeyWidth)
                            HStack(spacing: 0) {
                                Spacer()
                                blackKey(note: midiNote(octave: octave, semitone: semitone + 1))
                                    .offset(x: (whiteKeyWidth - blackKeyWidth) / 2 + 1)
                            }
                        }
                        .frame(width: whiteKeyWidth + 1)
                    } else {
                        Color.clear
                            .frame(width: whiteKeyWidth + 1, height: blackKeyHeight)
                    }
                }
            }
        }
    }

    private func whiteKey(note: Int) -> some View {
        let isPressed = pressedNotes.contains(note)
        return RoundedRectangle(cornerRadius: 2)
            .fill(isPressed
                  ? Color(red: 0.4, green: 0.6, blue: 0.45)
                  : Color(red: 0.55, green: 0.58, blue: 0.55))
            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressedNotes.contains(note) {
                            pressedNotes.insert(note)
                            AudioEngine.shared.noteOn(pitch: note, velocity: 0.8)
                        }
                    }
                    .onEnded { _ in
                        pressedNotes.remove(note)
                        AudioEngine.shared.noteOff(pitch: note)
                    }
            )
    }

    private func blackKey(note: Int) -> some View {
        let isPressed = pressedNotes.contains(note)
        return RoundedRectangle(cornerRadius: 2)
            .fill(isPressed
                  ? Color(red: 0.25, green: 0.4, blue: 0.3)
                  : Color(red: 0.25, green: 0.28, blue: 0.26))
            .frame(width: blackKeyWidth, height: blackKeyHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressedNotes.contains(note) {
                            pressedNotes.insert(note)
                            AudioEngine.shared.noteOn(pitch: note, velocity: 0.8)
                        }
                    }
                    .onEnded { _ in
                        pressedNotes.remove(note)
                        AudioEngine.shared.noteOff(pitch: note)
                    }
            )
    }
}
