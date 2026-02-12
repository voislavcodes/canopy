import SwiftUI

struct MainContentView: View {
    @ObservedObject var projectState: ProjectState
    @ObservedObject var transportState: TransportState
    @StateObject private var canvasState = CanvasState()

    @State private var keyboardOctave: Int = 3

    private var hasSelection: Bool {
        projectState.selectedNodeID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(projectState: projectState, transportState: transportState)

            HStack(spacing: 0) {
                // Left bloom panel: synth controls
                if hasSelection {
                    SynthControlsPanel(projectState: projectState)
                        .transition(.move(edge: .leading))
                }

                // Center: canvas
                CanopyCanvasView(projectState: projectState, canvasState: canvasState)

                // Right bloom panel: step sequencer
                if hasSelection {
                    StepSequencerPanel(projectState: projectState, transportState: transportState)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasSelection)

            // Bottom: keyboard (always visible)
            KeyboardBarView(baseOctave: $keyboardOctave)
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
        // Stop sequencer and silence all notes when switching nodes
        if transportState.isPlaying {
            transportState.stopPlayback()
        }
        AudioEngine.shared.allNotesOff()

        // Configure audio engine with selected node's patch
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
            // Space bar — toggle playback (only when not editing text fields)
            if event.keyCode == 49 && !isEditingTextField() {
                transportState.togglePlayback()
                return nil // consume the event
            }
            return event
        }
    }

    private func isEditingTextField() -> Bool {
        // Check if first responder is a text field
        guard let firstResponder = NSApp.keyWindow?.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
