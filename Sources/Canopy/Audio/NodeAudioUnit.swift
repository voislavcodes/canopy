import AVFoundation
import os

/// Encapsulates a single tree node's audio subgraph:
/// AVAudioSourceNode (oscillator) → main mixer.
///
/// Volume and pan are handled inside the render callback to avoid
/// format conversion issues with intermediate AVAudioMixerNodes.
///
/// Owns its own VoiceManager, Sequencer, and AudioCommandRingBuffer.
/// The render callback is lock-free and self-contained.
final class NodeAudioUnit {
    let nodeID: UUID
    let sourceNode: AVAudioSourceNode
    let commandBuffer: AudioCommandRingBuffer

    /// Shared pointers for UI polling (written by audio thread, read by main thread).
    private let _currentBeat = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let _isPlaying = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    /// Pan value written from main thread, read from audio thread.
    /// -1.0 = full left, 0.0 = center, 1.0 = full right.
    private let _pan = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    var currentBeat: Double { _currentBeat.pointee }
    var isPlaying: Bool { _isPlaying.pointee }

    private static let logger = Logger(subsystem: "com.canopy", category: "NodeAudioUnit")

    init(nodeID: UUID, sampleRate: Double) {
        self.nodeID = nodeID
        self.commandBuffer = AudioCommandRingBuffer(capacity: 256)

        _currentBeat.initialize(to: 0)
        _isPlaying.initialize(to: false)
        _pan.initialize(to: 0)

        // Audio-thread owned state — captured by render closure
        var voices = VoiceManager(voiceCount: 8)
        var seq = Sequencer()
        var volume: Double = 0.8
        var detune: Double = 0
        let sr = sampleRate

        voices.configurePatch(
            waveform: 0, detune: 0,
            attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3,
            sampleRate: sr
        )

        let cmdBuffer = self.commandBuffer
        let beatPtr = self._currentBeat
        let playingPtr = self._isPlaying
        let panPtr = self._pan

        self.sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee
            // Equal-power pan law: L = cos(angle), R = sin(angle)
            // angle = (pan + 1) / 2 * pi/2
            let angle = Double((pan + 1) * 0.5) * .pi * 0.5
            let gainL = Float(cos(angle))
            let gainR = Float(sin(angle))

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

                    case .sequencerLoad(let events, let lengthInBeats,
                                        let direction, let mutationAmount, let mutationRange,
                                        let scaleRootSemitone, let scaleIntervals,
                                        let accumulatorConfig):
                        voices.allNotesOff()
                        seq.load(events: events, lengthInBeats: lengthInBeats,
                                 direction: direction,
                                 mutationAmount: mutationAmount, mutationRange: mutationRange,
                                 scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals,
                                 accumulatorConfig: accumulatorConfig)

                    case .sequencerSetGlobalProbability(let prob):
                        seq.globalProbability = prob

                    case .sequencerSetMutation(let amount, let range, let rootSemitone, let intervals):
                        seq.setMutation(amount: amount, range: range, rootSemitone: rootSemitone, intervals: intervals)

                    case .sequencerResetMutation:
                        seq.resetMutation()

                    case .sequencerFreezeMutation:
                        seq.freezeMutation()
                    }
                }

                // 2. Advance sequencer
                seq.advanceOneSample(sampleRate: sr, voices: &voices, detune: detune)

                // 3. Render all voices
                let sample = voices.renderSample(sampleRate: sr) * Float(volume)

                // 4. Write to output channels with pan
                if ablPointer.count >= 2 {
                    let bufL = ablPointer[0]
                    let bufR = ablPointer[1]
                    bufL.mData?.assumingMemoryBound(to: Float.self)[frame] = sample * gainL
                    bufR.mData?.assumingMemoryBound(to: Float.self)[frame] = sample * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        let buffer = ablPointer[buf]
                        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                    }
                }
            }

            // Update shared state for UI polling
            beatPtr.pointee = seq.currentBeat
            playingPtr.pointee = seq.isPlaying

            return noErr
        }
    }

    deinit {
        _currentBeat.deinitialize(count: 1)
        _currentBeat.deallocate()
        _isPlaying.deinitialize(count: 1)
        _isPlaying.deallocate()
        _pan.deinitialize(count: 1)
        _pan.deallocate()
    }

    // MARK: - Public API (main thread)

    func noteOn(pitch: Int, velocity: Double) {
        commandBuffer.push(.noteOn(pitch: pitch, velocity: velocity))
    }

    func noteOff(pitch: Int) {
        commandBuffer.push(.noteOff(pitch: pitch))
    }

    func allNotesOff() {
        commandBuffer.push(.allNotesOff)
    }

    func configurePatch(waveform: Int, detune: Double, attack: Double, decay: Double, sustain: Double, release: Double, volume: Double) {
        commandBuffer.push(.setPatch(
            waveform: waveform, detune: detune,
            attack: attack, decay: decay, sustain: sustain, release: release,
            volume: volume
        ))
    }

    func loadSequence(_ events: [SequencerEvent], lengthInBeats: Double,
                       direction: PlaybackDirection = .forward,
                       mutationAmount: Double = 0, mutationRange: Int = 0,
                       scaleRootSemitone: Int = 0, scaleIntervals: [Int] = [],
                       accumulatorConfig: AccumulatorConfig? = nil) {
        commandBuffer.push(.sequencerLoad(
            events: events, lengthInBeats: lengthInBeats,
            direction: direction,
            mutationAmount: mutationAmount, mutationRange: mutationRange,
            scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals,
            accumulatorConfig: accumulatorConfig))
    }

    func setGlobalProbability(_ probability: Double) {
        commandBuffer.push(.sequencerSetGlobalProbability(probability))
    }

    func setMutation(amount: Double, range: Int, rootSemitone: Int, intervals: [Int]) {
        commandBuffer.push(.sequencerSetMutation(amount: amount, range: range, rootSemitone: rootSemitone, intervals: intervals))
    }

    func resetMutation() {
        commandBuffer.push(.sequencerResetMutation)
    }

    func freezeMutation() {
        commandBuffer.push(.sequencerFreezeMutation)
    }

    func startSequencer(bpm: Double) {
        commandBuffer.push(.sequencerStart(bpm: bpm))
    }

    func stopSequencer() {
        commandBuffer.push(.sequencerStop)
    }

    func setSequencerBPM(_ bpm: Double) {
        commandBuffer.push(.sequencerSetBPM(bpm))
    }

    func setVolume(_ volume: Float) {
        // Volume is handled via setPatch in the render callback
    }

    func setPan(_ pan: Float) {
        _pan.pointee = max(-1, min(1, pan))
    }
}
