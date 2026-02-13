import Foundation
import Combine

/// Observable transport state that bridges the audio engine's sequencer
/// to the SwiftUI layer. Polls currentBeat at ~30Hz for playhead display.
class TransportState: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var bpm: Double = 120
    @Published var currentBeat: Double = 0

    /// The node whose beat position is displayed in the UI.
    var focusedNodeID: UUID?

    private var pollTimer: Timer?

    init() {}

    /// Start polling the audio engine for the current beat position.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isPlaying, let nodeID = self.focusedNodeID {
                self.currentBeat = AudioEngine.shared.currentBeat(for: nodeID)
            }
        }
    }

    /// Stop polling.
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

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
        AudioEngine.shared.startAllSequencers(bpm: bpm)
        startPolling()
    }

    /// Stop all sequencers and reset.
    func stopPlayback() {
        isPlaying = false
        AudioEngine.shared.stopAllSequencers()
        currentBeat = 0
        stopPolling()
    }

    /// Update BPM (live, while playing).
    func updateBPM(_ newBPM: Double) {
        bpm = max(20, min(300, newBPM))
        if isPlaying {
            AudioEngine.shared.setAllSequencersBPM(bpm)
        }
    }
}
