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

    init(nodeID: UUID, sampleRate: Double, isDrumKit: Bool = false) {
        self.nodeID = nodeID
        self.commandBuffer = AudioCommandRingBuffer(capacity: 256)

        _currentBeat.initialize(to: 0)
        _isPlaying.initialize(to: false)
        _pan.initialize(to: 0)

        let cmdBuffer = self.commandBuffer
        let beatPtr = self._currentBeat
        let playingPtr = self._isPlaying
        let panPtr = self._pan

        if isDrumKit {
            self.sourceNode = Self.makeDrumKitSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate
            )
        } else {
            self.sourceNode = Self.makeOscillatorSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate
            )
        }
    }

    // MARK: - Oscillator Render Path

    private static func makeOscillatorSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double
    ) -> AVAudioSourceNode {
        var voices = VoiceManager(voiceCount: 8)
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var volume: Double = 0.8
        var volumeSmoothed: Double = 0.8
        var detune: Double = 0
        let sr = sampleRate
        let volumeSmoothCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / sampleRate)

        voices.configurePatch(
            waveform: 0, detune: 0,
            attack: 0.01, decay: 0.1, sustain: 0.7, release: 0.3,
            sampleRate: sr
        )

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee
            // Equal-power pan law: L = cos(angle), R = sin(angle)
            // angle = (pan + 1) / 2 * pi/2
            let angle = Double((pan + 1) * 0.5) * .pi * 0.5
            let gainL = Float(cos(angle))
            let gainR = Float(sin(angle))

            // 1. Drain command ring buffer ONCE per callback (not per-sample).
            //    Commands arrive at human-interaction rates (~10/sec). Draining
            //    once per callback (~86/sec at 512 samples) is more than enough.
            //    This also ensures associated-value payloads (heap arrays in
            //    .sequencerLoad) go out of scope here — not inside the hot loop.
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

                case .sequencerSetArp(let active, let samplesPerStep, let gateLength, let mode):
                    seq.setArpConfig(active: active, samplesPerStep: samplesPerStep,
                                     gateLength: gateLength, mode: mode)

                case .sequencerSetArpPool(let pitches, let velocities):
                    seq.setArpPool(pitches: pitches, velocities: velocities)

                case .setFilter(let enabled, let cutoff, let reso):
                    filter.enabled = enabled
                    filter.cutoffHz = cutoff
                    filter.resonance = reso
                    filter.updateCoefficients(sampleRate: sr)

                case .setLFOSlot(let slotIndex, let enabled, let waveform,
                                 let rateHz, let initialPhase, let depth, let parameter):
                    lfoBank.configureSlot(slotIndex, enabled: enabled, waveform: waveform,
                                          rateHz: rateHz, initialPhase: initialPhase,
                                          depth: depth, parameter: parameter)

                case .setLFOSlotCount(let count):
                    lfoBank.slotCount = count

                case .setDrumVoice:
                    break // ignored in oscillator path
                }
            }

            // Branch once before the loop: modulated vs unmodulated path.
            // Zero overhead when no LFOs are routed to this node.
            if lfoBank.slotCount > 0 {
                // MODULATED PATH
                for frame in 0..<Int(frameCount) {
                    seq.advanceOneSample(sampleRate: sr, receiver: &voices, detune: detune)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod // reserved for future per-sample resonance modulation

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        let bufL = ablPointer[0]
                        let bufR = ablPointer[1]
                        bufL.mData?.assumingMemoryBound(to: Float.self)[frame] = sample * modGainL
                        bufR.mData?.assumingMemoryBound(to: Float.self)[frame] = sample * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            let buffer = ablPointer[buf]
                            buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                        }
                    }
                }
            } else {
                // UNMODIFIED PATH (existing behavior, zero LFO overhead)
                for frame in 0..<Int(frameCount) {
                    seq.advanceOneSample(sampleRate: sr, receiver: &voices, detune: detune)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

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
            }

            // Update shared state for UI polling
            beatPtr.pointee = seq.currentBeat
            playingPtr.pointee = seq.isPlaying

            return noErr
        }
    }

    // MARK: - Drum Kit Render Path

    private static func makeDrumKitSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double
    ) -> AVAudioSourceNode {
        var drumKit = FMDrumKit.defaultKit()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var volume: Double = 0.8
        var volumeSmoothed: Double = 0.8
        let sr = sampleRate
        let volumeSmoothCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / sampleRate)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee
            let angle = Double((pan + 1) * 0.5) * .pi * 0.5
            let gainL = Float(cos(angle))
            let gainR = Float(sin(angle))

            // Drain command buffer
            while let cmd = cmdBuffer.pop() {
                switch cmd {
                case .noteOn(let pitch, let velocity):
                    drumKit.trigger(pitch: pitch, velocity: velocity)

                case .noteOff:
                    break // drums are one-shot

                case .allNotesOff:
                    drumKit.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)

                case .sequencerStop:
                    seq.stop()
                    drumKit.allNotesOff()

                case .sequencerSetBPM(let bpm):
                    seq.bpm = bpm

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals,
                                    let accumulatorConfig):
                    drumKit.allNotesOff()
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

                case .sequencerSetArp(let active, let samplesPerStep, let gateLength, let mode):
                    seq.setArpConfig(active: active, samplesPerStep: samplesPerStep,
                                     gateLength: gateLength, mode: mode)

                case .sequencerSetArpPool(let pitches, let velocities):
                    seq.setArpPool(pitches: pitches, velocities: velocities)

                case .setFilter(let enabled, let cutoff, let reso):
                    filter.enabled = enabled
                    filter.cutoffHz = cutoff
                    filter.resonance = reso
                    filter.updateCoefficients(sampleRate: sr)

                case .setLFOSlot(let slotIndex, let enabled, let waveform,
                                 let rateHz, let initialPhase, let depth, let parameter):
                    lfoBank.configureSlot(slotIndex, enabled: enabled, waveform: waveform,
                                          rateHz: rateHz, initialPhase: initialPhase,
                                          depth: depth, parameter: parameter)

                case .setLFOSlotCount(let count):
                    lfoBank.slotCount = count

                case .setDrumVoice(let index, let carrierFreq, let modulatorRatio,
                                   let fmDepth, let noiseMix, let ampDecay,
                                   let pitchEnvAmount, let pitchDecay, let level):
                    drumKit.configureVoice(index: index, carrierFreq: carrierFreq,
                                          modulatorRatio: modulatorRatio, fmDepth: fmDepth,
                                          noiseMix: noiseMix, ampDecay: ampDecay,
                                          pitchEnvAmount: pitchEnvAmount, pitchDecay: pitchDecay,
                                          level: level)
                }
            }

            // Render loop — same LFO branching as oscillator path
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.advanceOneSample(sampleRate: sr, receiver: &drumKit, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sample * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sample * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                        }
                    }
                }
            } else {
                for frame in 0..<Int(frameCount) {
                    seq.advanceOneSample(sampleRate: sr, receiver: &drumKit, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sample * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sample * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                        }
                    }
                }
            }

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

    func configureFilter(enabled: Bool, cutoff: Double, resonance: Double) {
        commandBuffer.push(.setFilter(enabled: enabled, cutoff: cutoff, resonance: resonance))
    }

    func configureLFOSlot(_ slotIndex: Int, enabled: Bool, waveform: Int,
                           rateHz: Double, initialPhase: Double, depth: Double, parameter: Int) {
        commandBuffer.push(.setLFOSlot(
            slotIndex: slotIndex, enabled: enabled, waveform: waveform,
            rateHz: rateHz, initialPhase: initialPhase, depth: depth, parameter: parameter
        ))
    }

    func setLFOSlotCount(_ count: Int) {
        commandBuffer.push(.setLFOSlotCount(count))
    }

    func setArpConfig(active: Bool, samplesPerStep: Int, gateLength: Double, mode: ArpMode) {
        commandBuffer.push(.sequencerSetArp(active: active, samplesPerStep: samplesPerStep,
                                            gateLength: gateLength, mode: mode))
    }

    func setArpPool(pitches: [Int], velocities: [Double]) {
        commandBuffer.push(.sequencerSetArpPool(pitches: pitches, velocities: velocities))
    }

    func configureDrumVoice(index: Int, config: DrumVoiceConfig) {
        commandBuffer.push(.setDrumVoice(
            index: index, carrierFreq: config.carrierFreq,
            modulatorRatio: config.modulatorRatio, fmDepth: config.fmDepth,
            noiseMix: config.noiseMix, ampDecay: config.ampDecay,
            pitchEnvAmount: config.pitchEnvAmount, pitchDecay: config.pitchDecay,
            level: config.level
        ))
    }
}
