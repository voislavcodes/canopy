import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState
    @StateObject private var canvasState = CanvasState()

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(projectState: projectState, transportState: transportState)

            // Canvas fills all remaining space — bloom UI (including keyboard) lives inside it
            CanopyCanvasView(
                projectState: projectState,
                canvasState: canvasState,
                transportState: transportState
            )
        }
        .background(CanopyColors.canvasBackground)
        .onAppear {
            setupSpacebarHandler()
        }
        .onChange(of: projectState.selectedNodeID) { _ in
            handleNodeSelectionChange()
        }
    }

    // MARK: - Node Selection Change

    private func handleNodeSelectionChange() {
        if transportState.isPlaying {
            transportState.stopPlayback()
        }
        AudioEngine.shared.allNotesOff()

        if let node = projectState.selectedNode {
            pushPatchToEngine(node.patch)
            loadSequenceToEngine(node)
        }
    }

    private func pushPatchToEngine(_ patch: SoundPatch) {
        if case .oscillator(let config) = patch.soundType {
            let waveformIndex: Int
            switch config.waveform {
            case .sine: waveformIndex = 0
            case .triangle: waveformIndex = 1
            case .sawtooth: waveformIndex = 2
            case .square: waveformIndex = 3
            case .noise: waveformIndex = 4
            }
            AudioEngine.shared.configurePatch(
                waveform: waveformIndex,
                detune: config.detune,
                attack: patch.envelope.attack,
                decay: patch.envelope.decay,
                sustain: patch.envelope.sustain,
                release: patch.envelope.release,
                volume: patch.volume
            )
        }
    }

    private func loadSequenceToEngine(_ node: Node) {
        let events = node.sequence.notes.map { event in
            SequencerEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: event.startBeat,
                endBeat: event.startBeat + event.duration
            )
        }
        AudioEngine.shared.loadSequence(events, lengthInBeats: node.sequence.lengthInBeats)
    }

    // MARK: - Keyboard Shortcut

    private func setupSpacebarHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 && !isEditingTextField() {
                transportState.togglePlayback()
                return nil
            }
            return event
        }
    }

    private func isEditingTextField() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
