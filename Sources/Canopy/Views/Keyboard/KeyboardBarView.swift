import SwiftUI

/// Persistent bottom bar with a 3-octave piano keyboard (C3–B5).
/// Octave shift buttons allow transposition. Sends noteOn/noteOff
/// to AudioEngine when keys are pressed/released.
struct KeyboardBarView: View {
    @Binding var baseOctave: Int // default 3 (C3)

    // Track currently pressed keys for visual feedback
    @State private var pressedNotes: Set<Int> = []

    private let whiteKeyWidth: CGFloat = 28
    private let whiteKeyHeight: CGFloat = 80
    private let blackKeyWidth: CGFloat = 18
    private let blackKeyHeight: CGFloat = 50

    // 3 octaves of white keys
    private let octaveCount = 3

    // Which semitone offsets within an octave are white keys
    private static let whiteKeyOffsets = [0, 2, 4, 5, 7, 9, 11]
    // Which semitone offsets have a black key to their right
    private static let blackKeyAfterWhite = [0, 2, 5, 7, 9] // C, D, F, G, A have sharps

    /// MIDI note number for a given semitone offset in a given octave
    private func midiNote(octave: Int, semitone: Int) -> Int {
        (octave + 1) * 12 + semitone // C4 = 60 when octave=4
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(CanopyColors.chromeBorder)

            HStack(spacing: 0) {
                // Octave down
                Button(action: { if baseOctave > 0 { baseOctave -= 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText)
                        .frame(width: 30, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)

                Text("C\(baseOctave)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)
                    .frame(width: 28)

                // Piano keys
                keyboardView

                Text("B\(baseOctave + octaveCount - 1)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(CanopyColors.chromeText)
                    .frame(width: 28)

                // Octave up
                Button(action: { if baseOctave < 7 { baseOctave += 1 } }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(CanopyColors.chromeText)
                        .frame(width: 30, height: whiteKeyHeight)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(height: whiteKeyHeight + 8)
            .background(CanopyColors.chromeBackground)
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

            // Black keys overlaid
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
        return Rectangle()
            .fill(isPressed ? Color(red: 0.7, green: 0.9, blue: 0.75) : Color(red: 0.9, green: 0.9, blue: 0.88))
            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
            .border(Color(red: 0.5, green: 0.5, blue: 0.48), width: 0.5)
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
        return Rectangle()
            .fill(isPressed ? Color(red: 0.3, green: 0.5, blue: 0.35) : Color(red: 0.12, green: 0.12, blue: 0.14))
            .frame(width: blackKeyWidth, height: blackKeyHeight)
            .cornerRadius(0, antialiased: false)
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
