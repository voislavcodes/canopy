import AVFoundation
import os

/// Central audio engine singleton. Manages the AVAudioEngine graph,
/// voice allocation, and sequencer timing.
///
/// Public API is called from the main thread. The render callback
/// runs on the audio thread and must be lock-free.
final class AudioEngine {
    static let shared = AudioEngine()

    private let logger = Logger(subsystem: "com.canopy", category: "AudioEngine")

    // AVAudioEngine graph
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // Lock-free command buffer: main thread → audio thread
    let commandBuffer = AudioCommandRingBuffer(capacity: 512)

    // Shared state for UI polling (written by audio thread, read by main thread)
    private let _currentBeat = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let _isPlaying = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    /// Current beat position, polled by UI at ~30Hz.
    var currentBeat: Double {
        _currentBeat.pointee
    }

    /// Whether the sequencer is currently playing (audio-thread truth).
    var isSequencerPlaying: Bool {
        _isPlaying.pointee
    }

    private var sampleRate: Double = 44100

    private init() {
        _currentBeat.initialize(to: 0)
        _isPlaying.initialize(to: false)
    }

    deinit {
        _currentBeat.deinitialize(count: 1)
        _currentBeat.deallocate()
        _isPlaying.deinitialize(count: 1)
        _isPlaying.deallocate()
    }

    // MARK: - Engine Lifecycle

    /// Start the audio engine. Call once at app launch.
    func start() {
        guard !engine.isRunning else { return }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outputFormat.sampleRate
        let sr = sampleRate

        // Audio-thread owned state — initialized here, captured by render closure
        var voices = VoiceManager()
        var seq = Sequencer()
        var volume: Double = 0.8
        var detune: Double = 0

        voices.configurePatch(
            waveform: 0, detune: 0,
            attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3,
            sampleRate: sr
        )

        let cmdBuffer = self.commandBuffer
        let beatPtr = self._currentBeat
        let playingPtr = self._isPlaying

        let srcNode = AVAudioSourceNode(format: outputFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            for frame in 0..<Int(frameCount) {
                // 1. Drain command ring buffer
                while let cmd = cmdBuffer.pop() {
                    switch cmd {
                    case .noteOn(let pitch, let velocity):
                        let freq = MIDIUtilities.detunedFrequency(
                            base: MIDIUtilities.frequency(forNote: pitch),
                            cents: detune
                        )
                        voices.noteOn(pitch: pitch, velocity: velocity, frequency: freq)

                    case .noteOff(let pitch):
                        voices.noteOff(pitch: pitch)

                    case .allNotesOff:
                        voices.allNotesOff()

                    case .setPatch(let waveform, let newDetune, let attack, let decay, let sustain, let release, let newVolume):
                        detune = newDetune
                        volume = newVolume
                        voices.configurePatch(
                            waveform: waveform, detune: newDetune,
                            attack: attack, decay: decay, sustain: sustain, release: release,
                            sampleRate: sr
                        )

                    case .sequencerStart(let bpm):
                        seq.start(bpm: bpm)

                    case .sequencerStop:
                        seq.stop()
                        voices.allNotesOff()

                    case .sequencerSetBPM(let bpm):
                        seq.bpm = bpm

                    case .sequencerLoad(let events, let lengthInBeats):
                        seq.load(events: events, lengthInBeats: lengthInBeats)
                    }
                }

                // 2. Advance sequencer (posts noteOn/noteOff into voices)
                seq.advanceOneSample(sampleRate: sr, voices: &voices, detune: detune)

                // 3. Render all voices
                let sample = voices.renderSample(sampleRate: sr) * Float(volume)

                // 4. Write to all output channels
                for buf in 0..<ablPointer.count {
                    let buffer = ablPointer[buf]
                    let data = buffer.mData?.assumingMemoryBound(to: Float.self)
                    data?[frame] = sample
                }
            }

            // Update shared state for UI polling
            beatPtr.pointee = seq.currentBeat
            playingPtr.pointee = seq.isPlaying

            return noErr
        }

        self.sourceNode = srcNode

        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            logger.info("Audio engine started at \(sr) Hz")
        } catch {
            logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Stop the audio engine.
    func stop() {
        engine.stop()
        logger.info("Audio engine stopped")
    }

    // MARK: - Public API (main thread)

    /// Send a note-on command to the audio thread.
    func noteOn(pitch: Int, velocity: Double = 0.8) {
        commandBuffer.push(.noteOn(pitch: pitch, velocity: velocity))
    }

    /// Send a note-off command to the audio thread.
    func noteOff(pitch: Int) {
        commandBuffer.push(.noteOff(pitch: pitch))
    }

    /// Release all sounding notes.
    func allNotesOff() {
        commandBuffer.push(.allNotesOff)
    }

    /// Update the sound patch on the audio thread.
    func configurePatch(waveform: Int, detune: Double, attack: Double, decay: Double, sustain: Double, release: Double, volume: Double) {
        commandBuffer.push(.setPatch(
            waveform: waveform, detune: detune,
            attack: attack, decay: decay, sustain: sustain, release: release,
            volume: volume
        ))
    }

    // MARK: - Sequencer Control (main thread, routed through ring buffer)

    /// Load a note sequence for playback.
    func loadSequence(_ events: [SequencerEvent], lengthInBeats: Double) {
        commandBuffer.push(.sequencerLoad(events: events, lengthInBeats: lengthInBeats))
    }

    /// Start the sequencer at the given BPM.
    func startSequencer(bpm: Double) {
        commandBuffer.push(.sequencerStart(bpm: bpm))
    }

    /// Stop the sequencer and silence all notes.
    func stopSequencer() {
        commandBuffer.push(.sequencerStop)
    }

    /// Update the sequencer BPM while playing.
    func setSequencerBPM(_ bpm: Double) {
        commandBuffer.push(.sequencerSetBPM(bpm))
    }
}
