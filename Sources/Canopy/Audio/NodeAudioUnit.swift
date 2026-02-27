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

    /// Fade state for click-free removal. 0 = normal, 1 = fading out, 2 = faded out.
    private let _fadeState = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// Monotonic clock offset — each unit's local time = globalClock - startOffset.
    /// Set on transitions so new units see beat 0 without resetting the global clock.
    private let _startOffset = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    /// Global sample at which to auto-stop + auto-fade (0 = disabled).
    /// Set during stageNextTree so the audio thread stops at the LCM boundary
    /// without waiting for the main thread. Prevents beat-0 re-triggers.
    private let _deactivateAtSample = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    /// Global sample at which to start sequencer + fade-in (Int64.max = no pending activation).
    /// Set during stageNextTree so the audio thread activates at the exact sample.
    private let _activateAtSample = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    /// BPM to use when activation fires (0 = not set).
    private let _activateBPM = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    var currentBeat: Double { _currentBeat.pointee }
    var isPlaying: Bool { _isPlaying.pointee }

    private static let logger = Logger(subsystem: "com.canopy", category: "NodeAudioUnit")

    /// Shared pointers for orbit body angles (written by audio thread, read by main thread for visualization).
    private let _orbitBodyAngles = UnsafeMutablePointer<(Float, Float, Float, Float, Float, Float)>.allocate(capacity: 1)

    var orbitBodyAngles: (Float, Float, Float, Float, Float, Float) { _orbitBodyAngles.pointee }

    init(nodeID: UUID, sampleRate: Double, isDrumKit: Bool = false, isWestCoast: Bool = false, isFlow: Bool = false, isTide: Bool = false, isSwarm: Bool = false, isQuake: Bool = false, isSpore: Bool = false, isFuse: Bool = false, isVolt: Bool = false, isSchmynth: Bool = false,
         clockSamplePosition: UnsafeMutablePointer<Int64>, clockIsRunning: UnsafeMutablePointer<Bool>) {
        self.nodeID = nodeID
        self.commandBuffer = AudioCommandRingBuffer(capacity: 256)

        _currentBeat.initialize(to: 0)
        _isPlaying.initialize(to: false)
        _pan.initialize(to: 0)
        _orbitBodyAngles.initialize(to: (0, 0, 0, 0, 0, 0))
        _fadeState.initialize(to: 0)
        _startOffset.initialize(to: 0)
        _deactivateAtSample.initialize(to: 0)
        _activateAtSample.initialize(to: Int64.max)
        _activateBPM.initialize(to: 0)

        let cmdBuffer = self.commandBuffer
        let beatPtr = self._currentBeat
        let playingPtr = self._isPlaying
        let panPtr = self._pan
        let orbitAnglesPtr = self._orbitBodyAngles
        let fadeStatePtr = self._fadeState
        let startOffsetPtr = self._startOffset
        let deactivateAtSamplePtr = self._deactivateAtSample
        let activateAtSamplePtr = self._activateAtSample
        let activateBPMPtr = self._activateBPM

        if isSchmynth {
            self.sourceNode = Self.makeSchmynthSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isVolt {
            self.sourceNode = Self.makeVoltSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isFuse {
            self.sourceNode = Self.makeFuseSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isSpore {
            self.sourceNode = Self.makeSporeSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isQuake {
            self.sourceNode = Self.makeQuakeSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, orbitAnglesPtr: orbitAnglesPtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isSwarm {
            self.sourceNode = Self.makeSwarmSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isTide {
            self.sourceNode = Self.makeTideSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isFlow {
            self.sourceNode = Self.makeFlowSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isWestCoast {
            self.sourceNode = Self.makeWestCoastSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else if isDrumKit {
            self.sourceNode = Self.makeDrumKitSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        } else {
            self.sourceNode = Self.makeOscillatorSourceNode(
                cmdBuffer: cmdBuffer, beatPtr: beatPtr, playingPtr: playingPtr,
                panPtr: panPtr, fadeStatePtr: fadeStatePtr, sampleRate: sampleRate,
                clockPtr: clockSamplePosition, clockRunning: clockIsRunning,
                startOffsetPtr: startOffsetPtr,
                deactivateAtSamplePtr: deactivateAtSamplePtr,
                activateAtSamplePtr: activateAtSamplePtr,
                activateBPMPtr: activateBPMPtr
            )
        }
    }

    // MARK: - Oscillator Render Path

    private static func makeOscillatorSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    voices.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &voices, detune: detune)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    voices.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setFlowImprint:
                    break // ignored in oscillator path

                case .setTideImprint:
                    break // ignored in oscillator path

                case .setSwarmImprint:
                    break // ignored in oscillator path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in oscillator path

                case .setOrbit:
                    break // ignored in oscillator path

                case .useOrbitSequencer:
                    break // ignored in oscillator path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in oscillator path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2  // fade-in
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Branch once before the loop: modulated vs unmodulated path.
            // Zero overhead when no LFOs are routed to this node.
            if lfoBank.slotCount > 0 {
                // MODULATED PATH — active range only
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &voices, detune: detune)
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

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                // UNMODIFIED PATH — active range only
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &voices, detune: detune)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &voices, detune: detune)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = voices.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            // Update shared state for UI polling
            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - Drum Kit Render Path

    private static func makeDrumKitSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    drumKit.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &drumKit, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    drumKit.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setFlowImprint:
                    break // ignored in drum kit path

                case .setTideImprint:
                    break // ignored in drum kit path

                case .setSwarmImprint:
                    break // ignored in drum kit path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in drum kit path

                case .setOrbit:
                    break // ignored in drum kit path

                case .useOrbitSequencer:
                    break // ignored in drum kit path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in drum kit path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &drumKit, detune: 0)
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

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &drumKit, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &drumKit, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = drumKit.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - Quake Render Path

    private static func makeQuakeSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        orbitAnglesPtr: UnsafeMutablePointer<(Float, Float, Float, Float, Float, Float)>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
    ) -> AVAudioSourceNode {
        var quake = QuakeVoiceManager.defaultKit()
        var seq = Sequencer()
        var orbit = OrbitSequencer()
        var useOrbit = false
        var orbitLengthInBeats: Double = 4
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
                    quake.trigger(pitch: pitch, velocity: velocity)

                case .noteOff:
                    break // drums are one-shot

                case .allNotesOff:
                    quake.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    orbit.start(bpm: bpm, lengthInBeats: orbitLengthInBeats)
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    orbit.stop()
                    quake.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &quake, detune: 0)
                    orbit.stop()

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    orbit.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    quake.allNotesOff()
                    orbitLengthInBeats = lengthInBeats
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setQuakeVoice(let idx, let mass, let surface, let force, let sustain):
                    quake.configureVoice(index: idx, mass: mass, surface: surface, force: force, sustain: sustain)

                case .setQuakeVolume(let vol):
                    volume = vol

                case .setOrbit(let grav, let bodies, let tens, let dens):
                    orbit.configure(gravity: grav, bodyCount: bodies, tension: tens, density: dens)

                case .useOrbitSequencer(let use):
                    useOrbit = use

                case .setDrumVoice:
                    break // ignored in quake path

                case .setWestCoast:
                    break // ignored in quake path

                case .setFlow:
                    break // ignored in quake path

                case .setTide:
                    break // ignored in quake path

                case .setSwarm:
                    break // ignored in quake path

                case .setFlowImprint:
                    break // ignored in quake path

                case .setTideImprint:
                    break // ignored in quake path

                case .setSwarmImprint:
                    break // ignored in quake path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in quake path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            let srF = Float(sr)
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                if useOrbit {
                    playingPtr.pointee = orbit.isPlaying
                    beatPtr.pointee = orbit.currentBeat
                } else {
                    beatPtr.pointee = seq.currentBeat
                    playingPtr.pointee = seq.isPlaying
                }
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                orbit.start(bpm: bpm, lengthInBeats: orbitLengthInBeats)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    let frameSample = baseSample + Int64(frame)
                    if useOrbit {
                        orbit.tickQuake(globalSample: frameSample, sampleRate: sr, receiver: &quake)
                    } else {
                        seq.tick(globalSample: frameSample, sampleRate: sr, receiver: &quake, detune: 0)
                    }
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = quake.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                for frame in range.activeStart..<range.activeEnd {
                    let frameSample = baseSample + Int64(frame)
                    if useOrbit {
                        orbit.tickQuake(globalSample: frameSample, sampleRate: sr, receiver: &quake)
                    } else {
                        seq.tick(globalSample: frameSample, sampleRate: sr, receiver: &quake, detune: 0)
                    }

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = quake.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &quake, detune: 0)
                orbit.stop()
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = quake.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            if useOrbit {
                playingPtr.pointee = orbit.isPlaying
                beatPtr.pointee = orbit.currentBeat
                orbitAnglesPtr.pointee = orbit.bodyAngles
            } else {
                playingPtr.pointee = seq.isPlaying
                beatPtr.pointee = seq.currentBeat
            }

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - West Coast Render Path

    private static func makeWestCoastSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    westCoast.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &westCoast, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    westCoast.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setFlowImprint:
                    break // ignored in west coast path

                case .setTideImprint:
                    break // ignored in west coast path

                case .setSwarmImprint:
                    break // ignored in west coast path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in west coast path

                case .setOrbit:
                    break // ignored in west coast path

                case .useOrbitSequencer:
                    break // ignored in west coast path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in west coast path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            westCoast.sampleRate = sr
            let srF = Float(sr)

            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &westCoast, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = westCoast.renderSample(sampleRate: sr) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &westCoast, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = westCoast.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &westCoast, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = westCoast.renderSample(sampleRate: sr) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - FLOW Render Path

    private static func makeFlowSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    flow.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &flow, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    flow.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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
                              let channel, let density, let warmth, let newVolume,
                              let filterVal, let filterMode, let width,
                              let attack, let decay):
                    volume = newVolume
                    flow.configureFlow(
                        current: current, viscosity: viscosity, obstacle: obstacle,
                        channel: channel, density: density, warmth: warmth,
                        filter: filterVal, filterMode: filterMode, width: width,
                        attack: attack, decay: decay
                    )

                case .setFlowImprint(let amplitudes):
                    flow.setImprint(amplitudes)

                case .setTide:
                    break // ignored in flow path

                case .setTideImprint:
                    break // ignored in flow path

                case .setSwarm:
                    break // ignored in flow path

                case .setSwarmImprint:
                    break // ignored in flow path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in flow path

                case .setOrbit:
                    break // ignored in flow path

                case .useOrbitSequencer:
                    break // ignored in flow path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in flow path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            flow.sampleRate = sr
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // FLOW is natively stereo — same pattern as SWARM/TIDE
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &flow, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = flow.renderStereoSample(sampleRate: sr)
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

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &flow, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = flow.renderStereoSample(sampleRate: sr)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &flow, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            let tailAngle = Double((pan + 1) * 0.5) * .pi * 0.5
            let tailGainL = Float(cos(tailAngle))
            let tailGainR = Float(sin(tailAngle))
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let (rawL, rawR) = flow.renderStereoSample(sampleRate: sr)
                let volF = Float(volumeSmoothed)
                var sampleL = filter.process(rawL * volF)
                var sampleR = filter.process(rawR * volF)
                (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * tailGainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * tailGainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - SWARM Render Path

    private static func makeSwarmSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    swarm.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &swarm, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    swarm.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setSwarmImprint(let positions, let amplitudes):
                    swarm.setImprint(positions: positions, amplitudes: amplitudes)

                case .setFlowImprint:
                    break // ignored in swarm path

                case .setTideImprint:
                    break // ignored in swarm path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in swarm path

                case .setOrbit:
                    break // ignored in swarm path

                case .useOrbitSequencer:
                    break // ignored in swarm path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in swarm path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            swarm.sampleRate = srF

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Swarm is natively stereo — same pattern as TIDE
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
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

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &swarm, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = swarm.renderStereoSample(sampleRate: srF)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &swarm, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            let tailAngle = Double((pan + 1) * 0.5) * .pi * 0.5
            let tailGainL = Float(cos(tailAngle))
            let tailGainR = Float(sin(tailAngle))
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let (rawL, rawR) = swarm.renderStereoSample(sampleRate: srF)
                let volF = Float(volumeSmoothed)
                var sampleL = filter.process(rawL * volF)
                var sampleR = filter.process(rawR * volF)
                (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * tailGainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * tailGainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - TIDE Render Path

    private static func makeTideSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
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
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    tide.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &tide, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    tide.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    tide.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setTideImprint(let frames):
                    tide.setImprint(frames)

                case .setFlowImprint:
                    break // ignored in tide path

                case .setSwarm:
                    break // ignored in tide path

                case .setSwarmImprint:
                    break // ignored in tide path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in tide path

                case .setOrbit:
                    break // ignored in tide path

                case .useOrbitSequencer:
                    break // ignored in tide path

                case .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale, .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in tide path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            tide.sampleRate = sr
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                tide.setBPM(bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Tide is natively stereo — render stereo directly
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
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

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &tide, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = tide.renderStereoSample(sampleRate: sr)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &tide, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            let tailAngle = Double((pan + 1) * 0.5) * .pi * 0.5
            let tailGainL = Float(cos(tailAngle))
            let tailGainR = Float(sin(tailAngle))
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let (rawL, rawR) = tide.renderStereoSample(sampleRate: sr)
                let volF = Float(volumeSmoothed)
                var sampleL = filter.process(rawL * volF)
                var sampleR = filter.process(rawR * volF)
                (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * tailGainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * tailGainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - SPORE Render Path

    private static func makeSporeSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
    ) -> AVAudioSourceNode {
        var spore = SporeVoiceManager()
        var seq = Sequencer()
        var sporeSeq = SporeSequencerState()
        var useSporeSeq = false
        var filter = MoogLadderFilter()
        var lfoBank = LFOBank()
        var fxChain = EffectChain()
        var volume: Double = 0.7
        var volumeSmoothed: Double = 0.7
        let sr = sampleRate
        let volumeSmoothCoeff = 1.0 - exp(-2.0 * .pi * 200.0 / sampleRate)

        return AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let pan = panPtr.pointee

            // Drain command buffer
            while let cmd = cmdBuffer.pop() {
                switch cmd {
                case .noteOn(let pitch, let velocity):
                    spore.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    spore.noteOff(pitch: pitch)

                case .allNotesOff:
                    spore.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    spore.setBPM(bpm)
                    fxChain.updateBPM(bpm)
                    if useSporeSeq {
                        sporeSeq.start(bpm: bpm)
                    }

                case .sequencerStop:
                    seq.stop()
                    sporeSeq.stop()
                    spore.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &spore, detune: 0)
                    sporeSeq.stop()

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    sporeSeq.bpm = bpm
                    spore.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    spore.allNotesOff()
                    spore.setScale(rootSemitone: scaleRootSemitone, intervals: scaleIntervals)
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setSpore(let density, let form, let focus, let snap, let size,
                               let chirp, let bias, let evolve, let sync,
                               let filter, let filterMode, let width,
                               let attack, let decay,
                               let warmth, let newVolume,
                               let funcShape, let funcRate, let funcAmount,
                               let funcSync, let funcDiv):
                    volume = newVolume
                    spore.configureSpore(
                        density: density, form: form, focus: focus, snap: snap, size: size,
                        chirp: chirp, bias: bias, evolve: evolve, sync: sync,
                        filter: filter, filterMode: filterMode, width: width,
                        attack: attack, decay: decay,
                        warmth: warmth,
                        funcShape: funcShape, funcRate: funcRate, funcAmount: funcAmount,
                        funcSync: funcSync, funcDiv: funcDiv
                    )

                case .setSporeImprint(let amplitudes):
                    spore.setImprint(amplitudes)

                case .setSporeSeq(let subdivision, let density, let focus, let drift,
                                  let memory, let rangeOctaves):
                    useSporeSeq = true
                    sporeSeq.configure(
                        subdivision: SporeSubdivision.from(tag: subdivision),
                        density: density, focus: focus, drift: drift,
                        memory: memory, rangeOctaves: rangeOctaves
                    )

                case .setSporeSeqScale(let rootSemitone, let intervals):
                    sporeSeq.setScale(rootSemitone: rootSemitone, intervals: intervals)
                    spore.setScale(rootSemitone: rootSemitone, intervals: intervals)

                case .sporeSeqStart(let bpm):
                    useSporeSeq = true
                    sporeSeq.start(bpm: bpm)

                case .sporeSeqStop:
                    sporeSeq.stop()

                case .setDrumVoice, .setWestCoast, .setFlow, .setTide, .setSwarm:
                    break // ignored in spore path

                case .setFlowImprint, .setTideImprint, .setSwarmImprint:
                    break // ignored in spore path

                case .setQuakeVoice, .setQuakeVolume:
                    break // ignored in spore path

                case .setOrbit:
                    break // ignored in spore path

                case .useOrbitSequencer:
                    break // ignored in spore path

                case .setFuse, .setVoltSlot, .setSchmynth:
                    break // ignored in spore path

                case .setFXChain(let chain):
                    fxChain = chain
                }
            }

            spore.sampleRate = sr
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying || sporeSeq.isRunning
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                spore.setBPM(bpm)
                if useSporeSeq { sporeSeq.start(bpm: bpm) }
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // SPORE is natively stereo
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    let frameSample = baseSample + Int64(frame)
                    seq.tick(globalSample: frameSample, sampleRate: sr, receiver: &spore, detune: 0)

                    // SPORE SEQ: generate probabilistic events
                    if useSporeSeq {
                        sporeSeq.process(sampleCount: 1, sampleRate: sr) { pitch, velocity in
                            spore.noteOn(pitch: pitch, velocity: velocity, frequency: 0)
                        }
                    }

                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = spore.renderStereoSample(sampleRate: sr)
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

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

                for frame in range.activeStart..<range.activeEnd {
                    let frameSample = baseSample + Int64(frame)
                    seq.tick(globalSample: frameSample, sampleRate: sr, receiver: &spore, detune: 0)

                    // SPORE SEQ: generate probabilistic events
                    if useSporeSeq {
                        sporeSeq.process(sampleCount: 1, sampleRate: sr) { pitch, velocity in
                            spore.noteOn(pitch: pitch, velocity: velocity, frequency: 0)
                        }
                    }

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let (rawL, rawR) = spore.renderStereoSample(sampleRate: sr)
                    let volF = Float(volumeSmoothed)
                    var sampleL = filter.process(rawL * volF)
                    var sampleR = filter.process(rawR * volF)

                    (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)

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

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &spore, detune: 0)
                sporeSeq.stop()
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            let tailAngle = Double((pan + 1) * 0.5) * .pi * 0.5
            let tailGainL = Float(cos(tailAngle))
            let tailGainR = Float(sin(tailAngle))
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let (rawL, rawR) = spore.renderStereoSample(sampleRate: sr)
                let volF = Float(volumeSmoothed)
                var sampleL = filter.process(rawL * volF)
                var sampleR = filter.process(rawR * volF)
                (sampleL, sampleR) = fxChain.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleL * tailGainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = sampleR * tailGainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (sampleL + sampleR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying || sporeSeq.isRunning
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
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
        _orbitBodyAngles.deinitialize(count: 1)
        _orbitBodyAngles.deallocate()
        _fadeState.deinitialize(count: 1)
        _fadeState.deallocate()
        _startOffset.deinitialize(count: 1)
        _startOffset.deallocate()
        _deactivateAtSample.deinitialize(count: 1)
        _deactivateAtSample.deallocate()
        _activateAtSample.deinitialize(count: 1)
        _activateAtSample.deallocate()
        _activateBPM.deinitialize(count: 1)
        _activateBPM.deallocate()
    }

    /// Number of buffers over which to fade out (~185ms at 512/44100).
    /// Long enough to avoid clicks, short enough to prevent audible chord overlap.
    static let fadeOutBuffers: Int32 = 16

    // MARK: - Sample-Precise Activation/Deactivation

    /// Compute the active frame range within a render buffer based on
    /// activation/deactivation timestamps. Returns frame bounds and flags
    /// indicating whether activation or deactivation should fire this buffer.
    ///
    /// Uses global time (not local) to avoid negative-baseSample confusion.
    @inline(__always)
    static func computeActiveRange(
        frameCount: Int,
        globalSample: Int64,
        activateAtSample: Int64,
        deactivateAtSample: Int64
    ) -> (activeStart: Int, activeEnd: Int,
          shouldActivate: Bool, shouldDeactivate: Bool,
          earlyReturn: Bool) {
        let bufferEnd = globalSample + Int64(frameCount)

        // Determine activation frame
        let activeStart: Int
        let shouldActivate: Bool
        if activateAtSample == Int64.max {
            // No pending activation — already active from frame 0
            activeStart = 0
            shouldActivate = false
        } else if activateAtSample >= bufferEnd {
            // Not yet — silence entire buffer
            return (0, 0, false, false, true)
        } else if activateAtSample <= globalSample {
            // Late staging — activate at frame 0
            activeStart = 0
            shouldActivate = true
        } else {
            // Activation within this buffer
            activeStart = Int(activateAtSample - globalSample)
            shouldActivate = true
        }

        // Determine deactivation frame
        let activeEnd: Int
        let shouldDeactivate: Bool
        if deactivateAtSample <= 0 {
            // No pending deactivation — active through entire buffer
            activeEnd = frameCount
            shouldDeactivate = false
        } else if deactivateAtSample <= globalSample {
            // Already past deactivation — silence
            return (0, 0, false, false, true)
        } else if deactivateAtSample < bufferEnd {
            // Deactivation within this buffer
            activeEnd = Int(deactivateAtSample - globalSample)
            shouldDeactivate = true
        } else {
            // Deactivation is beyond this buffer
            activeEnd = frameCount
            shouldDeactivate = false
        }

        // Ensure activeStart <= activeEnd
        let clampedEnd = max(activeStart, activeEnd)
        return (activeStart, clampedEnd, shouldActivate, shouldDeactivate, false)
    }

    /// Zero a range of frames in all channels of an audio buffer list.
    @inline(__always)
    static func zeroFrames(_ abl: UnsafeMutableAudioBufferListPointer, range: Range<Int>) {
        guard !range.isEmpty else { return }
        for buf in 0..<abl.count {
            guard let data = abl[buf].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in range {
                data[frame] = 0
            }
        }
    }

    /// Request a multi-buffer fade-out. The render callback will ramp to zero
    /// over ~185ms (16 buffers) then output silence until removed.
    func requestFadeOut() {
        let current = _fadeState.pointee
        // Don't re-trigger if already fading (>0) or faded out (-1)
        if current == 0 {
            _fadeState.pointee = Self.fadeOutBuffers
        }
    }

    /// Whether the fade-out has completed (safe to disconnect or stop).
    var isFadedOut: Bool {
        _fadeState.pointee == -1
    }

    /// Reset fade state to normal after a faded stop, so next play outputs audio.
    func resetFade() {
        _fadeState.pointee = 0
    }

    /// Request a one-buffer fade-in. The render callback will ramp from zero
    /// to full volume over the next buffer, then switch to normal output.
    /// Used during forest transitions so new units don't pop in at full volume.
    func requestFadeIn() {
        _fadeState.pointee = -2
    }

    /// Apply buffer-level fade for click-free transitions. Called at the end of
    /// every render callback, after all synthesis and FX processing.
    ///
    /// Fade state encoding:
    ///   0  = normal (no-op)
    ///  >0  = fade-out in progress (value = remaining buffers, counts down)
    ///  -1  = faded out (output zeros)
    ///  -2  = fade-in (ramp 0→1 over one buffer, then → 0)
    @inline(__always)
    static func applyFade(
        _ abl: UnsafeMutableAudioBufferListPointer,
        frameCount: UInt32,
        fadeState: UnsafeMutablePointer<Int32>
    ) {
        let state = fadeState.pointee
        guard state != 0 else { return }
        let frames = Int(frameCount)
        if state > 0 {
            // Multi-buffer fade-out: linear ramp across buffers
            let total = Float(fadeOutBuffers)
            let gainStart = Float(state) / total
            let gainEnd = Float(state - 1) / total
            let divisor = Float(max(1, frames - 1))
            for frame in 0..<frames {
                let t = Float(frame) / divisor
                let gain = gainStart + (gainEnd - gainStart) * t
                for buf in 0..<abl.count {
                    abl[buf].mData?.assumingMemoryBound(to: Float.self)[frame] *= gain
                }
            }
            let next = state - 1
            fadeState.pointee = next > 0 ? next : -1
        } else if state == -2 {
            // Fade-in: ramp 0→1 over one buffer, then normal
            let divisor = Float(max(1, frames - 1))
            for frame in 0..<frames {
                let gain = Float(frame) / divisor
                for buf in 0..<abl.count {
                    abl[buf].mData?.assumingMemoryBound(to: Float.self)[frame] *= gain
                }
            }
            fadeState.pointee = 0
        } else {
            // State -1: faded out, output zeros
            for buf in 0..<abl.count {
                memset(abl[buf].mData, 0, Int(abl[buf].mDataByteSize))
            }
        }
    }

    /// Set the monotonic clock offset so this unit's local time starts from zero
    /// at the given global clock sample. Called during tree transitions.
    func setClockStartOffset(_ offset: Int64) {
        _startOffset.pointee = offset
    }

    /// Set the global sample at which to auto-deactivate (stop + fade-out).
    /// 0 disables the mechanism. Used by stageNextTree to schedule
    /// a stop at the LCM boundary so the audio thread handles it
    /// without waiting for the main thread.
    func setDeactivateAtSample(_ sample: Int64) {
        _deactivateAtSample.pointee = sample
    }

    /// Schedule activation at a specific global sample with a given BPM.
    /// Writes BPM first, then sample (ordering for audio-thread read safety).
    /// Int64.max means no pending activation.
    func setActivation(atSample sample: Int64, bpm: Double) {
        _activateBPM.pointee = bpm
        _activateAtSample.pointee = sample
    }

    /// Read the clock start offset (needed by simplified activateStagedTree).
    var clockStartOffset: Int64 {
        _startOffset.pointee
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
                       scaleRootSemitone: Int = 0, scaleIntervals: [Int] = []) {
        commandBuffer.push(.sequencerLoad(
            events: events, lengthInBeats: lengthInBeats,
            direction: direction,
            mutationAmount: mutationAmount, mutationRange: mutationRange,
            scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals))
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

    /// Stop sequencer without killing voices — lets active notes ring out
    /// through their natural ADSR release. Used during forest transitions.
    func stopSequencerSoft() {
        commandBuffer.push(.sequencerStopSoft)
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
            volume: config.volume,
            filter: config.filter, filterMode: config.filterMode,
            width: config.width, attack: config.attack, decay: config.decay
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

    // MARK: - Imprint

    /// Push FLOW imprint amplitudes (64 values) or nil to clear.
    func configureFlowImprint(_ amplitudes: [Float]?) {
        commandBuffer.push(.setFlowImprint(amplitudes))
    }

    /// Push TIDE imprint frames or nil to clear.
    func configureTideImprint(_ frames: [TideFrame]?) {
        commandBuffer.push(.setTideImprint(frames))
    }

    /// Push SWARM imprint positions and amplitudes (64 each) or nil to clear.
    func configureSwarmImprint(positions: [Float]?, amplitudes: [Float]?) {
        commandBuffer.push(.setSwarmImprint(positions: positions, amplitudes: amplitudes))
    }

    func configureSpore(_ config: SporeConfig) {
        commandBuffer.push(.setSpore(
            density: config.density, form: config.form, focus: config.focus,
            snap: config.snap, size: config.size,
            chirp: config.chirp, bias: config.bias, evolve: config.evolve, sync: config.sync,
            filter: config.filter, filterMode: config.filterMode, width: config.width,
            attack: config.attack, decay: config.decay,
            warmth: config.warmth, volume: config.volume,
            funcShape: config.funcShape, funcRate: config.funcRate, funcAmount: config.funcAmount,
            funcSync: config.funcSync, funcDiv: config.funcDiv
        ))
        // Push imprint if present
        if config.spectralSource == .imprint, let imprint = config.imprint {
            commandBuffer.push(.setSporeImprint(imprint.harmonicAmplitudes))
        }
    }

    func configureSporeImprint(_ amplitudes: [Float]?) {
        commandBuffer.push(.setSporeImprint(amplitudes))
    }

    func configureSporeSeq(_ config: SporeSeqConfig, key: MusicalKey) {
        commandBuffer.push(.setSporeSeq(
            subdivision: config.subdivision.tag,
            density: config.density, focus: config.focus,
            drift: config.drift, memory: config.memory,
            rangeOctaves: config.rangeOctaves
        ))
        commandBuffer.push(.setSporeSeqScale(
            rootSemitone: key.root.semitone,
            intervals: key.mode.intervals
        ))
    }

    func configureQuake(_ config: QuakeConfig) {
        for i in 0..<min(config.voices.count, 8) {
            let v = config.voices[i]
            commandBuffer.push(.setQuakeVoice(
                index: i, mass: v.mass, surface: v.surface,
                force: v.force, sustain: v.sustain
            ))
        }
        commandBuffer.push(.setQuakeVolume(config.volume))
    }

    func configureQuakeVoice(index: Int, mass: Double, surface: Double, force: Double, sustain: Double) {
        commandBuffer.push(.setQuakeVoice(index: index, mass: mass, surface: surface, force: force, sustain: sustain))
    }

    func configureOrbit(_ config: OrbitConfig) {
        commandBuffer.push(.setOrbit(
            gravity: config.gravity, bodyCount: config.bodyCount,
            tension: config.tension, density: config.density
        ))
    }

    func setUseOrbitSequencer(_ useOrbit: Bool) {
        commandBuffer.push(.useOrbitSequencer(useOrbit))
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

    func configureFuse(_ config: FuseConfig) {
        commandBuffer.push(.setFuse(
            soul: config.soul, tune: config.tune, couple: config.couple,
            body: config.body, color: config.color, warm: config.warm,
            keyTracking: config.keyTracking, volume: config.volume
        ))
    }

    func configureSchmynth(_ config: SchmynthConfig) {
        commandBuffer.push(.setSchmynth(
            waveform: config.waveform, cutoff: config.cutoff, resonance: config.resonance,
            filterMode: config.filterMode, attack: config.attack, decay: config.decay,
            sustain: config.sustain, release: config.release,
            warm: config.warm, volume: config.volume
        ))
    }

    func configureVoltSlot(index: Int, _ config: VoltConfig) {
        let layerAInt: Int
        switch config.layerA {
        case .resonant: layerAInt = 0
        case .noise: layerAInt = 1
        case .metallic: layerAInt = 2
        case .tonal: layerAInt = 3
        }
        let layerBInt: Int
        if let b = config.layerB {
            switch b {
            case .resonant: layerBInt = 0
            case .noise: layerBInt = 1
            case .metallic: layerBInt = 2
            case .tonal: layerBInt = 3
            }
        } else {
            layerBInt = -1
        }
        commandBuffer.push(.setVoltSlot(
            index: index,
            layerA: layerAInt, layerB: layerBInt, mix: config.mix,
            resPitch: config.resPitch, resSweep: config.resSweep,
            resDecay: config.resDecay, resDrive: config.resDrive, resPunch: config.resPunch,
            resHarmonics: config.resHarmonics, resClick: config.resClick,
            resNoise: config.resNoise, resBody: config.resBody, resTone: config.resTone,
            noiseColor: config.noiseColor, noiseSnap: config.noiseSnap,
            noiseBody: config.noiseBody, noiseClap: config.noiseClap,
            noiseTone: config.noiseTone, noiseFilter: config.noiseFilter,
            metSpread: config.metSpread, metTune: config.metTune,
            metRing: config.metRing, metBand: config.metBand, metDensity: config.metDensity,
            tonPitch: config.tonPitch, tonFM: config.tonFM,
            tonShape: config.tonShape, tonBend: config.tonBend, tonDecay: config.tonDecay,
            warm: config.warm
        ))
    }

    // MARK: - SCHMYNTH Render Path

    private static func makeSchmynthSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
    ) -> AVAudioSourceNode {
        var schmynth = SchmynthVoiceManager()
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
                    schmynth.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    schmynth.noteOff(pitch: pitch)

                case .allNotesOff:
                    schmynth.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    schmynth.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &schmynth, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    schmynth.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setSchmynth(let waveform, let cutoff, let resonance, let filterMode,
                                  let attack, let decay, let sustain, let release,
                                  let warm, let newVolume):
                    volume = newVolume
                    schmynth.configure(
                        waveform: waveform, cutoff: Float(cutoff), resonance: Float(resonance),
                        filterMode: filterMode, attack: Float(attack), decay: Float(decay),
                        sustain: Float(sustain), release: Float(release), warm: Float(warm)
                    )

                case .setFXChain(let chain):
                    fxChain = chain

                case .setDrumVoice, .setWestCoast, .setFlow, .setTide, .setSwarm,
                     .setFlowImprint, .setTideImprint, .setSwarmImprint,
                     .setQuakeVoice, .setQuakeVolume, .setOrbit, .useOrbitSequencer,
                     .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale,
                     .sporeSeqStart, .sporeSeqStop, .setFuse, .setVoltSlot:
                    break // ignored in schmynth path
                }
            }

            schmynth.sampleRate = Float(sr)
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Render loop
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &schmynth, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = schmynth.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &schmynth, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = schmynth.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &schmynth, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = schmynth.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - FUSE Render Path

    private static func makeFuseSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
    ) -> AVAudioSourceNode {
        var fuse = FuseVoiceManager()
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
                    fuse.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    fuse.noteOff(pitch: pitch)

                case .allNotesOff:
                    fuse.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    fuse.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &fuse, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    fuse.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setFuse(let soul, let tune, let couple, let body, let color,
                              let warm, let keyTracking, let newVolume):
                    volume = newVolume
                    fuse.configure(
                        soul: Float(soul), tune: Float(tune), couple: Float(couple),
                        body: Float(body), color: Float(color), warm: Float(warm),
                        keyTracking: keyTracking
                    )

                case .setFXChain(let chain):
                    fxChain = chain

                case .setDrumVoice, .setWestCoast, .setFlow, .setTide, .setSwarm,
                     .setFlowImprint, .setTideImprint, .setSwarmImprint,
                     .setQuakeVoice, .setQuakeVolume, .setOrbit, .useOrbitSequencer,
                     .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale,
                     .sporeSeqStart, .sporeSeqStop, .setVoltSlot, .setSchmynth:
                    break // ignored in fuse path
                }
            }

            fuse.sampleRate = Float(sr)
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Render loop
            if lfoBank.slotCount > 0 {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &fuse, detune: 0)
                    let (volMod, panMod, cutMod, resMod) = lfoBank.tick(sampleRate: sr)
                    _ = resMod

                    let modVol = max(0.0, min(1.0, volume + volume * volMod))
                    volumeSmoothed += (modVol - volumeSmoothed) * volumeSmoothCoeff
                    let raw = fuse.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)

                    let sample: Float
                    if cutMod != 0 {
                        sample = filter.processWithCutoffMod(raw, cutoffMod: cutMod, sampleRate: sr)
                    } else {
                        sample = filter.process(raw)
                    }

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    let modPan = max(-1.0, min(1.0, Double(pan) + panMod))
                    let modAngle = (modPan + 1.0) * 0.5 * .pi * 0.5
                    let modGainL = Float(cos(modAngle))
                    let modGainR = Float(sin(modAngle))

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * modGainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * modGainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            } else {
                for frame in range.activeStart..<range.activeEnd {
                    seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &fuse, detune: 0)

                    volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                    let raw = fuse.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                    let sample = filter.process(raw)

                    let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                    if ablPointer.count >= 2 {
                        ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                        ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                    } else {
                        for buf in 0..<ablPointer.count {
                            ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                        }
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &fuse, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = fuse.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }

    // MARK: - VOLT Render Path

    private static func makeVoltSourceNode(
        cmdBuffer: AudioCommandRingBuffer,
        beatPtr: UnsafeMutablePointer<Double>,
        playingPtr: UnsafeMutablePointer<Bool>,
        panPtr: UnsafeMutablePointer<Float>,
        fadeStatePtr: UnsafeMutablePointer<Int32>,
        sampleRate: Double,
        clockPtr: UnsafeMutablePointer<Int64>,
        clockRunning: UnsafeMutablePointer<Bool>,
        startOffsetPtr: UnsafeMutablePointer<Int64>,
        deactivateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateAtSamplePtr: UnsafeMutablePointer<Int64>,
        activateBPMPtr: UnsafeMutablePointer<Double>
    ) -> AVAudioSourceNode {
        var volt = VoltVoiceManager()
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
                    volt.noteOn(pitch: pitch, velocity: velocity, frequency: 0)

                case .noteOff(let pitch):
                    volt.noteOff(pitch: pitch)

                case .allNotesOff:
                    volt.allNotesOff()

                case .setPatch(_, _, _, _, _, _, let newVolume):
                    volume = newVolume

                case .sequencerStart(let bpm):
                    seq.start(bpm: bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerStop:
                    seq.stop()
                    volt.allNotesOff()
                    filter.reset()

                case .sequencerStopSoft:
                    seq.stopSoft(receiver: &volt, detune: 0)

                // sequencerPrepareTransition/CancelTransition removed — audio-thread timestamps handle transitions

                case .sequencerSetBPM(let bpm):
                    seq.setBPM(bpm)
                    fxChain.updateBPM(bpm)

                case .sequencerLoad(let events, let lengthInBeats,
                                    let direction, let mutationAmount, let mutationRange,
                                    let scaleRootSemitone, let scaleIntervals):
                    volt.allNotesOff()
                    seq.load(events: events, lengthInBeats: lengthInBeats,
                             direction: direction,
                             mutationAmount: mutationAmount, mutationRange: mutationRange,
                             scaleRootSemitone: scaleRootSemitone, scaleIntervals: scaleIntervals)

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

                case .setVoltSlot(let index, let layerA, let layerB, let mix,
                              let resPitch, let resSweep, let resDecay, let resDrive, let resPunch,
                              let resHarmonics, let resClick, let resNoise,
                              let resBody, let resTone,
                              let noiseColor, let noiseSnap, let noiseBody,
                              let noiseClap, let noiseTone, let noiseFilter,
                              let metSpread, let metTune, let metRing, let metBand, let metDensity,
                              let tonPitch, let tonFM, let tonShape, let tonBend, let tonDecay,
                              let warm):
                    volt.configureSlot(
                        index: index,
                        layerA: layerA, layerB: layerB, mix: Float(mix),
                        resPitch: Float(resPitch), resSweep: Float(resSweep),
                        resDecay: Float(resDecay), resDrive: Float(resDrive), resPunch: Float(resPunch),
                        resHarmonics: Float(resHarmonics), resClick: Float(resClick),
                        resNoise: Float(resNoise), resBody: Float(resBody), resTone: Float(resTone),
                        noiseColor: Float(noiseColor), noiseSnap: Float(noiseSnap),
                        noiseBody: Float(noiseBody), noiseClap: Float(noiseClap),
                        noiseTone: Float(noiseTone), noiseFilter: Float(noiseFilter),
                        metSpread: Float(metSpread), metTune: Float(metTune),
                        metRing: Float(metRing), metBand: Float(metBand), metDensity: Float(metDensity),
                        tonPitch: Float(tonPitch), tonFM: Float(tonFM),
                        tonShape: Float(tonShape), tonBend: Float(tonBend), tonDecay: Float(tonDecay),
                        warm: Float(warm)
                    )

                case .setFXChain(let chain):
                    fxChain = chain

                case .setDrumVoice, .setWestCoast, .setFlow, .setTide, .setSwarm,
                     .setFlowImprint, .setTideImprint, .setSwarmImprint,
                     .setQuakeVoice, .setQuakeVolume, .setOrbit, .useOrbitSequencer,
                     .setSpore, .setSporeImprint, .setSporeSeq, .setSporeSeqScale,
                     .sporeSeqStart, .sporeSeqStop, .setFuse, .setSchmynth:
                    break // ignored in volt path
                }
            }

            volt.sampleRate = Float(sr)
            let srF = Float(sr)

            // Compute active frame range from activation/deactivation timestamps
            let globalSample = clockPtr.pointee
            let baseSample = globalSample - startOffsetPtr.pointee

            let range = Self.computeActiveRange(
                frameCount: Int(frameCount), globalSample: globalSample,
                activateAtSample: activateAtSamplePtr.pointee,
                deactivateAtSample: deactivateAtSamplePtr.pointee)

            if range.earlyReturn {
                Self.zeroFrames(ablPointer, range: 0..<Int(frameCount))
                beatPtr.pointee = seq.currentBeat
                playingPtr.pointee = seq.isPlaying
                Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
                return noErr
            }

            if range.shouldActivate {
                activateAtSamplePtr.pointee = Int64.max
                let bpm = activateBPMPtr.pointee
                seq.start(bpm: bpm)
                fxChain.updateBPM(bpm)
                fadeStatePtr.pointee = -2
            }

            Self.zeroFrames(ablPointer, range: 0..<range.activeStart)

            // Render loop
            for frame in range.activeStart..<range.activeEnd {
                seq.tick(globalSample: baseSample + Int64(frame), sampleRate: sr, receiver: &volt, detune: 0)

                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = volt.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                let sample = filter.process(raw)

                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)

                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            if range.shouldDeactivate {
                deactivateAtSamplePtr.pointee = 0
                seq.stopSoft(receiver: &volt, detune: 0)
                if fadeStatePtr.pointee == 0 { fadeStatePtr.pointee = Self.fadeOutBuffers }
            }

            // Voice-tail rendering for post-deactivation frames (release envelopes)
            for frame in range.activeEnd..<Int(frameCount) {
                volumeSmoothed += (volume - volumeSmoothed) * volumeSmoothCoeff
                let raw = volt.renderSampleFloat(sampleRate: Float(sr)) * Float(volumeSmoothed)
                let sample = filter.process(raw)
                let (fxL, fxR) = fxChain.processStereo(sampleL: sample, sampleR: sample, sampleRate: srF)
                if ablPointer.count >= 2 {
                    ablPointer[0].mData?.assumingMemoryBound(to: Float.self)[frame] = fxL * gainL
                    ablPointer[1].mData?.assumingMemoryBound(to: Float.self)[frame] = fxR * gainR
                } else {
                    for buf in 0..<ablPointer.count {
                        ablPointer[buf].mData?.assumingMemoryBound(to: Float.self)[frame] = (fxL + fxR) * 0.5
                    }
                }
            }

            playingPtr.pointee = seq.isPlaying
            beatPtr.pointee = seq.currentBeat

            Self.applyFade(ablPointer, frameCount: frameCount, fadeState: fadeStatePtr)
            return noErr
        }
    }
}
