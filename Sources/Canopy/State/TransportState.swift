import Foundation
import Combine

/// Observable transport state that bridges the audio engine's sequencer
/// to the SwiftUI layer. Playhead reads beat position directly from the
/// audio engine via TimelineView — no polling needed here.
class TransportState: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var bpm: Double = 120

    /// The node whose beat position is displayed in the UI.
    var focusedNodeID: UUID?

    init() {}

    /// Toggle play/stop.
    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    /// Start all sequencers.
    func startPlayback() {
        isPlaying = true
        AudioEngine.shared.setMasterBusBPM(bpm)
        AudioEngine.shared.startAllSequencers(bpm: bpm)
    }

    /// Stop all sequencers and reset.
    func stopPlayback() {
        isPlaying = false
        AudioEngine.shared.stopAllSequencers()
    }

    /// Update BPM (live, while playing).
    func updateBPM(_ newBPM: Double) {
        bpm = max(20, min(300, newBPM))
        AudioEngine.shared.setMasterBusBPM(bpm)
        if isPlaying {
            AudioEngine.shared.setAllSequencersBPM(bpm)
        }
    }
}
