import Foundation

/// 8-voice polyphonic manager for the FLOW engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as WestCoastVoiceManager.
struct FlowVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (FlowVoice, FlowVoice, FlowVoice, FlowVoice,
                 FlowVoice, FlowVoice, FlowVoice, FlowVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    /// Sample rate stored from render callback — used by NoteReceiver methods.
    var sampleRate: Double = 48000

    /// WARM node-level state for inter-voice power sag.
    var warmNodeState: WarmNodeState = WarmNodeState()

    /// Imprint harmonic amplitudes (64 values). When set, beginNote uses these
    /// instead of the default 1/harmonic^1.5 falloff. Stored as a tuple for
    /// audio-thread safety (no heap, no CoW).
    var imprintAmplitudes: (Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float)?

    init() {
        voices = (FlowVoice(), FlowVoice(), FlowVoice(), FlowVoice(),
                  FlowVoice(), FlowVoice(), FlowVoice(), FlowVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique noise seeds per voice — decorrelates turbulence across voices.
        voices.0.noiseState = 0x1234_5678
        voices.1.noiseState = 0x8765_4321
        voices.2.noiseState = 0xDEAD_BEEF
        voices.3.noiseState = 0xCAFE_BABE
        voices.4.noiseState = 0xFACE_FEED
        voices.5.noiseState = 0xBAAD_F00D
        voices.6.noiseState = 0xD00D_BEAD
        voices.7.noiseState = 0xC0DE_F00D

        // WARM: unique analog tolerance per voice
        WarmProcessor.seedVoice(&voices.0.warmState, voiceIndex: 0)
        WarmProcessor.seedVoice(&voices.1.warmState, voiceIndex: 1)
        WarmProcessor.seedVoice(&voices.2.warmState, voiceIndex: 2)
        WarmProcessor.seedVoice(&voices.3.warmState, voiceIndex: 3)
        WarmProcessor.seedVoice(&voices.4.warmState, voiceIndex: 4)
        WarmProcessor.seedVoice(&voices.5.warmState, voiceIndex: 5)
        WarmProcessor.seedVoice(&voices.6.warmState, voiceIndex: 6)
        WarmProcessor.seedVoice(&voices.7.warmState, voiceIndex: 7)
    }

    // MARK: - Imprint

    /// Set or clear imprint harmonic amplitudes. When set, new notes will use
    /// these amplitudes as baseAmp instead of the default harmonic falloff.
    mutating func setImprint(_ amplitudes: [Float]?) {
        guard let amps = amplitudes, amps.count >= 64 else {
            imprintAmplitudes = nil
            return
        }
        imprintAmplitudes = (
            amps[0],  amps[1],  amps[2],  amps[3],  amps[4],  amps[5],  amps[6],  amps[7],
            amps[8],  amps[9],  amps[10], amps[11], amps[12], amps[13], amps[14], amps[15],
            amps[16], amps[17], amps[18], amps[19], amps[20], amps[21], amps[22], amps[23],
            amps[24], amps[25], amps[26], amps[27], amps[28], amps[29], amps[30], amps[31],
            amps[32], amps[33], amps[34], amps[35], amps[36], amps[37], amps[38], amps[39],
            amps[40], amps[41], amps[42], amps[43], amps[44], amps[45], amps[46], amps[47],
            amps[48], amps[49], amps[50], amps[51], amps[52], amps[53], amps[54], amps[55],
            amps[56], amps[57], amps[58], amps[59], amps[60], amps[61], amps[62], amps[63]
        )
    }

    // MARK: - Voice Access Helpers
    //
    // CRITICAL: No voiceAt() that returns FlowVoice by value.
    // Copying a FlowVoice copies its [FlowPartial] array reference,
    // bumping the refcount to 2. If the copy is alive when triggerVoiceAt
    // mutates partials[], Swift triggers CoW — a heap allocation on the
    // audio thread. Instead, read specific properties directly from the tuple.

    /// Read isActive without copying the entire FlowVoice (avoids CoW on [FlowPartial]).
    private func isVoiceActive(_ i: Int) -> Bool {
        switch i {
        case 0: return voices.0.isActive
        case 1: return voices.1.isActive
        case 2: return voices.2.isActive
        case 3: return voices.3.isActive
        case 4: return voices.4.isActive
        case 5: return voices.5.isActive
        case 6: return voices.6.isActive
        case 7: return voices.7.isActive
        default: return false
        }
    }

    /// Read envelopeLevel without copying the entire FlowVoice.
    private func voiceEnvelopeLevel(_ i: Int) -> Float {
        switch i {
        case 0: return voices.0.envelopeLevel
        case 1: return voices.1.envelopeLevel
        case 2: return voices.2.envelopeLevel
        case 3: return voices.3.envelopeLevel
        case 4: return voices.4.envelopeLevel
        case 5: return voices.5.envelopeLevel
        case 6: return voices.6.envelopeLevel
        case 7: return voices.7.envelopeLevel
        default: return 0
        }
    }

    private func pitchAt(_ i: Int) -> Int {
        switch i {
        case 0: return pitches.0
        case 1: return pitches.1
        case 2: return pitches.2
        case 3: return pitches.3
        case 4: return pitches.4
        case 5: return pitches.5
        case 6: return pitches.6
        case 7: return pitches.7
        default: return -1
        }
    }

    private mutating func setPitch(_ i: Int, _ v: Int) {
        switch i {
        case 0: pitches.0 = v
        case 1: pitches.1 = v
        case 2: pitches.2 = v
        case 3: pitches.3 = v
        case 4: pitches.4 = v
        case 5: pitches.5 = v
        case 6: pitches.6 = v
        case 7: pitches.7 = v
        default: break
        }
    }

    // MARK: - Voice Stealing

    /// Allocate a voice: reuse same pitch → find idle → steal quietest.
    private mutating func allocateVoice(pitch: Int, velocity: Double, sampleRate: Double) {
        // First: reuse a voice already playing this pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch {
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Second: find an idle voice (reads Bool directly, no FlowVoice copy)
        for i in 0..<Self.voiceCount {
            if !isVoiceActive(i) {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the quietest voice (reads Float directly, no FlowVoice copy)
        var quietest = 0
        var lowestLevel = voiceEnvelopeLevel(0)
        for i in 1..<Self.voiceCount {
            let level = voiceEnvelopeLevel(i)
            if level < lowestLevel {
                lowestLevel = level
                quietest = i
            }
        }
        setPitch(quietest, pitch)
        triggerVoiceAt(quietest, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    private mutating func triggerVoiceAt(_ i: Int, pitch: Int, velocity: Double, sampleRate: Double) {
        // If imprint is active, pass pointer to tuple storage for audio-thread-safe access
        if let _ = imprintAmplitudes {
            withUnsafePointer(to: &imprintAmplitudes!) { tuplePtr in
                tuplePtr.withMemoryRebound(to: Float.self, capacity: FlowVoice.partialCount) { ptr in
                    switch i {
                    case 0: voices.0.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 1: voices.1.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 2: voices.2.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 3: voices.3.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 4: voices.4.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 5: voices.5.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 6: voices.6.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    case 7: voices.7.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate, imprintAmplitudes: ptr)
                    default: break
                    }
                }
            }
        } else {
            switch i {
            case 0: voices.0.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 1: voices.1.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 2: voices.2.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 3: voices.3.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 4: voices.4.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 5: voices.5.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 6: voices.6.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            case 7: voices.7.trigger(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
            default: break
            }
        }
    }

    private mutating func releaseVoiceAt(_ i: Int, sampleRate: Double) {
        switch i {
        case 0: voices.0.release(sampleRate: sampleRate)
        case 1: voices.1.release(sampleRate: sampleRate)
        case 2: voices.2.release(sampleRate: sampleRate)
        case 3: voices.3.release(sampleRate: sampleRate)
        case 4: voices.4.release(sampleRate: sampleRate)
        case 5: voices.5.release(sampleRate: sampleRate)
        case 6: voices.6.release(sampleRate: sampleRate)
        case 7: voices.7.release(sampleRate: sampleRate)
        default: break
        }
    }

    // MARK: - Bulk Configuration

    /// Apply FLOW parameters to all 8 voices.
    mutating func configureFlow(
        current: Double, viscosity: Double, obstacle: Double,
        channel: Double, density: Double, warmth: Double,
        filter: Double, filterMode: Int, width: Double,
        attack: Double, decay: Double
    ) {
        applyConfig(&voices.0, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.1, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.2, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.3, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.4, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.5, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.6, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
        applyConfig(&voices.7, current: current, viscosity: viscosity, obstacle: obstacle, channel: channel, density: density, warmth: warmth, filter: filter, filterMode: filterMode, width: width, attack: attack, decay: decay)
    }

    private func applyConfig(
        _ voice: inout FlowVoice,
        current: Double, viscosity: Double, obstacle: Double,
        channel: Double, density: Double, warmth: Double,
        filter: Double, filterMode: Int, width: Double,
        attack: Double, decay: Double
    ) {
        voice.currentTarget = current
        voice.viscosityTarget = viscosity
        voice.obstacleTarget = obstacle
        voice.channelTarget = channel
        voice.densityTarget = density
        voice.warmthTarget = warmth
        voice.filterTarget = filter
        voice.filterModeParam = filterMode
        voice.widthTarget = width
        voice.attackTarget = attack
        voice.decayTarget = decay
    }

    /// Render one stereo sample: sum all 8 voices, then soft-limit once.
    /// Single tanh at the sum — NOT per-voice. Per-voice tanh creates odd harmonics
    /// that intermodulate when summed, producing distortion that scales with voice count.
    /// One tanh on the sum gracefully handles any number of voices without volume pumping.
    mutating func renderStereoSample(sampleRate: Double) -> (Float, Float) {
        let (l0, r0) = voices.0.renderStereoSample(sampleRate: sampleRate)
        let (l1, r1) = voices.1.renderStereoSample(sampleRate: sampleRate)
        let (l2, r2) = voices.2.renderStereoSample(sampleRate: sampleRate)
        let (l3, r3) = voices.3.renderStereoSample(sampleRate: sampleRate)
        let (l4, r4) = voices.4.renderStereoSample(sampleRate: sampleRate)
        let (l5, r5) = voices.5.renderStereoSample(sampleRate: sampleRate)
        let (l6, r6) = voices.6.renderStereoSample(sampleRate: sampleRate)
        let (l7, r7) = voices.7.renderStereoSample(sampleRate: sampleRate)

        var mixL = l0 + l1 + l2 + l3 + l4 + l5 + l6 + l7
        var mixR = r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7

        // Clear pitch assignments for voices that finished
        if !voices.0.isActive && pitches.0 != -1 { pitches.0 = -1 }
        if !voices.1.isActive && pitches.1 != -1 { pitches.1 = -1 }
        if !voices.2.isActive && pitches.2 != -1 { pitches.2 = -1 }
        if !voices.3.isActive && pitches.3 != -1 { pitches.3 = -1 }
        if !voices.4.isActive && pitches.4 != -1 { pitches.4 = -1 }
        if !voices.5.isActive && pitches.5 != -1 { pitches.5 = -1 }
        if !voices.6.isActive && pitches.6 != -1 { pitches.6 = -1 }
        if !voices.7.isActive && pitches.7 != -1 { pitches.7 = -1 }

        // WARM: inter-voice power sag (before safety tanh)
        let warmLevel = Float(voices.0.warmthParam)
        (mixL, mixR) = WarmProcessor.applyPowerSag(&warmNodeState, sampleL: mixL, sampleR: mixR, warm: warmLevel)

        // Two-stage output: gentle tanh tames peaks, then linear gain boosts volume.
        let outL = Float(tanh(Double(mixL) * 0.4) * 7.99)
        let outR = Float(tanh(Double(mixR) * 0.4) * 7.99)
        return (outL, outR)
    }

    /// Render one mono sample (NoteReceiver compatibility).
    mutating func renderSample(sampleRate: Double) -> Float {
        let (l, r) = renderStereoSample(sampleRate: sampleRate)
        return (l + r) * 0.5
    }

    /// Kill all voices immediately.
    mutating func allNotesOff() {
        voices.0.kill()
        voices.1.kill()
        voices.2.kill()
        voices.3.kill()
        voices.4.kill()
        voices.5.kill()
        voices.6.kill()
        voices.7.kill()
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)
    }
}

// MARK: - NoteReceiver Conformance

extension FlowVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // frequency parameter ignored — FlowVoice computes its own from pitch
        allocateVoice(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        // Release all voices playing this pitch (reads Bool directly, no FlowVoice copy)
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && isVoiceActive(i) {
                releaseVoiceAt(i, sampleRate: sampleRate)
                return
            }
        }
    }
}
