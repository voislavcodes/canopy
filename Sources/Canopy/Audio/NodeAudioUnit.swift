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

    init(nodeID: UUID, sampleRate: Double, isDrumKit: Bool = false, isWestCoast: Bool = false, isFlow: Bool = false, isTide: Bool = false, isSwarm: Bool = false,
         clockSamplePosition: UnsafeMutablePointer<Int64>, clockIsRunning: UnsafeMutablePointer<Bool>) {
        self.nodeID = nodeID
        self.commandBuffer = AudioCommandRingBuffer(capacity: 256)

        _currentBeat.initialize(to: 0)
        _isPlaying.initialize(to: false)
        _pan.initialize(to: 0)

        let cmdBuffer = self.commandBuffer
        let beatPtr = self._currentBeat
        let playingPtr = self._isPlaying
        let panPtr = self._pan

        if isSwarm {
            self.sourceNode = Self.makeSwarmSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        } else if isTide {
            self.sourceNode = Self.makeTideSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        } else if isFlow {
            self.sourceNode = Self.makeFlowSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        } else if isWestCoast {
            self.sourceNode = Self.makeWestCoastSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        } else if isDrumKit {
            self.sourceNode = Self.makeDrumKitSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        } else {
            self.sourceNode = Self.makeOscillatorSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning
            )
        }
    }

    // MARK: - Oscillator Render Path

    private static func makeOscillatorSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var voices = VoiceManager(voiceCount: 8)
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
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
                    seq.setBPM(bpm)

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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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

                case .setWestCoast:
                    break // ignored in oscillator path

                case .setFlow:
                    break // ignored in oscillator path

                case .setTide:
                    break // ignored in oscillator path

                case .setSwarm:
                    break // ignored in oscillator path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Branch once before the loop: modulated vs unmodulated path.
            // Zero overhead when no LFOs are routed to this node.
            if lfoBank.slotCount > 0 {
                // MODULATED PATH
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &voices, detune: detune)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod // reserved for future per-sample resonance modulation

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    var sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    // Per-node FX chain (empty chain = zero cost)
                    sample = fxChain.process(sample: sample, sampleRate: srF)

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
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &voices, detune: detune)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    var sample = filter.process(raw)

                    // Per-node FX chain (empty chain = zero cost)
                    sample = fxChain.process(sample: sample, sampleRate: srF)

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
            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            return noErr
        }
    }

    // MARK: - Drum Kit Render Path

    private static func makeDrumKitSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var drumKit = FMDrumKit.defaultKit()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
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
                    seq.setBPM(bpm)

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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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

                case .setWestCoast:
                    break // ignored in drum kit path

                case .setFlow:
                    break // ignored in drum kit path

                case .setTide:
                    break // ignored in drum kit path

                case .setSwarm:
                    break // ignored in drum kit path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Render loop — same LFO branching as oscillator path
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &drumKit, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    var sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &drumKit, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    var sample = filter.process(raw)

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            return noErr
        }
    }

    // MARK: - West Coast Render Path

    private static func makeWestCoastSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var westCoast = WestCoastVoiceManager()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
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
                    westCoast.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    westCoast.noteOff(pitch: pitch)

                case .allNotesOff:
                    westCoast.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)

                case .sequencerStop:
                    seq.stop()
                    westCoast.allNotesOff()

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals,
                                    let accumulatorConfig):
                    westCoast.allNotesOff()
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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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
                    break // ignored in west coast path

                case .setWestCoast(let primaryWaveform, let modulatorRatio, let modulatorFineTune,
                                   let fmDepth, let envToFM,
                                   let ringModMix,
                                   let foldAmount, let foldStages, let foldSymmetry, let modToFold,
                                   let lpgMode, let strike, let damp, let color,
                                   let rise, let fall, let funcShape, let funcLoop,
                                   let newVolume):
                    volume = newVolume
                    westCoast.configureWestCoast(
                        primaryWaveform: primaryWaveform, modulatorRatio: modulatorRatio,
                        modulatorFineTune: modulatorFineTune,
                        fmDepth: fmDepth, envToFM: envToFM,
                        ringModMix: ringModMix,
                        foldAmount: foldAmount, foldStages: foldStages,
                        foldSymmetry: foldSymmetry, modToFold: modToFold,
                        lpgMode: lpgMode, strike: strike, damp: damp, color: color,
                        rise: rise, fall: fall, funcShape: funcShape, funcLoop: funcLoop
                    )

                case .setFlow:
                    break // ignored in west coast path

                case .setTide:
                    break // ignored in west coast path

                case .setSwarm:
                    break // ignored in west coast path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Render loop — same LFO branching as other paths
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &westCoast, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = westCoast.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    var sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &westCoast, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = westCoast.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    var sample = filter.process(raw)

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            return noErr
        }
    }

    // MARK: - FLOW Render Path

    private static func makeFlowSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var flow = FlowVoiceManager()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
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
                    flow.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    flow.noteOff(pitch: pitch)

                case .allNotesOff:
                    flow.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)

                case .sequencerStop:
                    seq.stop()
                    flow.allNotesOff()

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals,
                                    let accumulatorConfig):
                    flow.allNotesOff()
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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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
                    break // ignored in flow path

                case .setWestCoast:
                    break // ignored in flow path

                case .setFlow(let current, let viscosity, let obstacle,
                              let channel, let density, let warmth, let newVolume):
                    volume = newVolume
                    flow.configureFlow(
                        current: current, viscosity: viscosity, obstacle: obstacle,
                        channel: channel, density: density, warmth: warmth
                    )

                case .setTide:
                    break // ignored in flow path

                case .setSwarm:
                    break // ignored in flow path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Render loop — same LFO branching as other paths
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &flow, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = flow.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    var sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &flow, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = flow.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    var sample = filter.process(raw)

                    sample = fxChain.process(sample: sample, sampleRate: srF)

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

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            return noErr
        }
    }

    // MARK: - SWARM Render Path

    private static func makeSwarmSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var swarm = SwarmVoiceManager()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
        var volume: Double = 0.7
        var volumeSmoothed: Double = 0.7
        let sr = sampleRate
        let srF = Float(sr)
        let volumeSmoothCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / sampleRate)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee

            // Drain command buffer
            while let cmd = cmdBuffer.pop() {
                switch cmd {
                case .noteOn(let pitch, let velocity):
                    swarm.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    swarm.noteOff(pitch: pitch)

                case .allNotesOff:
                    swarm.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)

                case .sequencerStop:
                    seq.stop()
                    swarm.allNotesOff()

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals,
                                    let accumulatorConfig):
                    swarm.allNotesOff()
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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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
                    break // ignored in swarm path

                case .setWestCoast:
                    break // ignored in swarm path

                case .setFlow:
                    break // ignored in swarm path

                case .setTide:
                    break // ignored in swarm path

                case .setSwarm(let gravity, let energy, let flock, let scatter,
                               let warmth, let newVolume):
                    volume = newVolume
                    swarm.configureSwarm(
                        gravity: Float(gravity), energy: Float(energy),
                        flock: Float(flock), scatter: Float(scatter),
                        warmth: Float(warmth)
                    )


                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Swarm is natively stereo — same pattern as TIDE
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &swarm, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = swarm.renderStereoSample(sampleRate: srF)
                    let volF = Float(volumeSmoothed)

                    var sampleL: Float
                    var sampleR: Float

                    if cutMod != 0 {
                        sampleL = filter.processWithCutoffMod(rawL * volF, cutoffMod: cutMod, sampleRate: sr)
                        sampleR = filter.processWithCutoffMod(rawR * volF, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sampleL = filter.process(rawL * volF)
                        sampleR = filter.process(rawR * volF)
                    }

                    sampleL = fxChain.process(sample: sampleL, sampleRate: srF)
                    sampleR = fxChain.process(sample: sampleR, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                        }
                    }
                }
            } else {
                // Equal-power pan law
                let angle = Double((pan + 1) * 0.5) * .pi * 0.5
                let gainL = Float(cos(angle))
                let gainR = Float(sin(angle))

                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &swarm, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = swarm.renderStereoSample(sampleRate: srF)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    sampleL = fxChain.process(sample: sampleL, sampleRate: srF)
                    sampleR = fxChain.process(sample: sampleR, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                        }
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            return noErr
        }
    }

    // MARK: - TIDE Render Path

    private static func makeTideSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>
    ) -> AVAudioSourceNode {
        var tide = TideVoiceManager()
        var seq = Sequencer()
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
        var volume: Double = 0.8
        var volumeSmoothed: Double = 0.8
        let sr = sampleRate
        let volumeSmoothCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / sampleRate)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee

            // Drain command buffer
            while let cmd = cmdBuffer.pop() {
                switch cmd {
                case .noteOn(let pitch, let velocity):
                    tide.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    tide.noteOff(pitch: pitch)

                case .allNotesOff:
                    tide.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    tide.setBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    tide.allNotesOff()

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    tide.setBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals,
                                    let accumulatorConfig):
                    tide.allNotesOff()
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

                case .sequencerSetArpPool(let pitches, let velocities, let startBeats, let endBeats):
                    seq.setArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats)

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
                    break // ignored in tide path

                case .setWestCoast:
                    break // ignored in tide path

                case .setFlow:
                    break // ignored in tide path

                case .setTide(let current, let pattern, let rate,
                              let rateSync, let rateDivisionBeats,
                              let depth, let warmth, let newVolume,
                              let funcShape, let funcAmount, let funcSkew, let funcCycles):
                    volume = newVolume
                    tide.configureTide(
                        current: current, pattern: pattern, rate: rate,
                        rateSync: rateSync, rateDivisionBeats: rateDivisionBeats,
                        depth: depth, warmth: warmth,
                        funcShape: funcShape, funcAmount: funcAmount,
                        funcSkew: funcSkew, funcCycles: funcCycles
                    )

                case .setSwarm:
                    break // ignored in tide path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Read tree clock once at top of callback
            let baseSample = clockPtr.pointee

            // Tide is natively stereo — render stereo directly
            if lfoBank.slotCount > 0 {
                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &tide, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = tide.renderStereoSample(sampleRate: sr)
                    let volF = Float(volumeSmoothed)

                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    if cutMod != 0 {
                        // Apply cutoff mod to both channels
                        sampleL = filter.processWithCutoffMod(rawL * volF, cutoffMod: cutMod, sampleRate: sr)
                        sampleR = filter.processWithCutoffMod(rawR * volF, cutoffMod: cutMod, sampleRate: sr)
                    }

                    sampleL = fxChain.process(sample: sampleL, sampleRate: srF)
                    sampleR = fxChain.process(sample: sampleR, sampleRate: srF)

                    // Apply pan modulation to stereo signal
                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                        }
                    }
                }
            } else {
                // Equal-power pan law
                let angle = Double((pan + 1) * 0.5) * .pi * 0.5
                let gainL = Float(cos(angle))
                let gainR = Float(sin(angle))

                for frame in 0..<Int(frameCount) {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &tide, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = tide.renderStereoSample(sampleRate: sr)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    sampleL = fxChain.process(sample: sampleL, sampleRate: srF)
                    sampleR = fxChain.process(sample: sampleR, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                        }
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

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

    func setArpPool(pitches: [Int], velocities: [Double], startBeats: [Double], endBeats: [Double]) {
        commandBuffer.push(.sequencerSetArpPool(pitches: pitches, velocities: velocities, startBeats: startBeats, endBeats: endBeats))
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

    func configureFlow(_ config: FlowConfig) {
        commandBuffer.push(.setFlow(
            current: config.current, viscosity: config.viscosity,
            obstacle: config.obstacle, channel: config.channel,
            density: config.density, warmth: config.warmth,
            volume: config.volume
        ))
    }

    func configureSwarm(_ config: SwarmConfig) {
        commandBuffer.push(.setSwarm(
            gravity: config.gravity, energy: config.energy,
            flock: config.flock, scatter: config.scatter,
            warmth: config.warmth, volume: config.volume
        ))
    }

    func configureTide(_ config: TideConfig) {
        let shapeInt: Int
        switch config.funcShape {
        case .off: shapeInt = 0
        case .sine: shapeInt = 1
        case .triangle: shapeInt = 2
        case .rampDown: shapeInt = 3
        case .rampUp: shapeInt = 4
        case .square: shapeInt = 5
        case .sAndH: shapeInt = 6
        }
        commandBuffer.push(.setTide(
            current: config.current, pattern: config.pattern,
            rate: config.rate,
            rateSync: config.rateSync, rateDivisionBeats: config.rateDivision.beats,
            depth: config.depth,
            warmth: config.warmth, volume: config.volume,
            funcShape: shapeInt, funcAmount: config.funcAmount,
            funcSkew: config.funcSkew, funcCycles: config.funcCycles
        ))
    }

    func setFXChain(_ chain: EffectChain) {
        commandBuffer.push(.setFXChain(chain))
    }

    func configureWestCoast(_ config: WestCoastConfig) {
        let wfInt: Int
        switch config.primaryWaveform {
        case .sine: wfInt = 0
        case .triangle: wfInt = 1
        }
        let lpgInt: Int
        switch config.lpgMode {
        case .filter: lpgInt = 0
        case .vca: lpgInt = 1
        case .both: lpgInt = 2
        }
        let shapeInt: Int
        switch config.funcShape {
        case .linear: shapeInt = 0
        case .exponential: shapeInt = 1
        case .logarithmic: shapeInt = 2
        }
        commandBuffer.push(.setWestCoast(
            primaryWaveform: wfInt, modulatorRatio: config.modulatorRatio,
            modulatorFineTune: config.modulatorFineTune,
            fmDepth: config.fmDepth, envToFM: config.envToFM,
            ringModMix: config.ringModMix,
            foldAmount: config.foldAmount, foldStages: config.foldStages,
            foldSymmetry: config.foldSymmetry, modToFold: config.modToFold,
            lpgMode: lpgInt, strike: config.strike, damp: config.damp, color: config.color,
            rise: config.rise, fall: config.fall, funcShape: shapeInt, funcLoop: config.funcLoop,
            volume: config.volume
        ))
    }
}
