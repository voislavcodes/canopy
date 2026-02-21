import Foundation

/// 8-voice polyphonic manager for the TIDE engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as FlowVoiceManager.
struct TideVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (TideVoice, TideVoice, TideVoice, TideVoice,
                 TideVoice, TideVoice, TideVoice, TideVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    /// Sample rate stored from render callback — used by NoteReceiver methods.
    var sampleRate: Double = 48000

    /// WARM node-level state for inter-voice power sag.
    var warmNodeState: WarmNodeState = WarmNodeState()

    /// Cached imprint frames for pattern index 16. Set via setImprint().
    var imprintFrames: [TideFrame]?

    init() {
        voices = (TideVoice(), TideVoice(), TideVoice(), TideVoice(),
                  TideVoice(), TideVoice(), TideVoice(), TideVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique noise seeds per voice — decorrelates chaos patterns across voices.
        voices.0.noiseState = 0x1234_5678
        voices.1.noiseState = 0x8765_4321
        voices.2.noiseState = 0xDEAD_BEEF
        voices.3.noiseState = 0xCAFE_BABE
        voices.4.noiseState = 0xFACE_FEED
        voices.5.noiseState = 0xBAAD_F00D
        voices.6.noiseState = 0xD00D_BEAD
        voices.7.noiseState = 0xC0DE_F00D

        // Stagger initial tide positions so voices don't all start at the same spectral frame
        voices.0.position = 0.0
        voices.1.position = 0.37
        voices.2.position = 0.74
        voices.3.position = 1.11
        voices.4.position = 1.48
        voices.5.position = 1.85
        voices.6.position = 2.22
        voices.7.position = 2.59

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

    /// Set or clear imprint frames on all voices. When set, pattern index 16
    /// uses these frames instead of the built-in patterns.
    mutating func setImprint(_ frames: [TideFrame]?) {
        imprintFrames = frames
        voices.0.setImprintFrames(frames)
        voices.1.setImprintFrames(frames)
        voices.2.setImprintFrames(frames)
        voices.3.setImprintFrames(frames)
        voices.4.setImprintFrames(frames)
        voices.5.setImprintFrames(frames)
        voices.6.setImprintFrames(frames)
        voices.7.setImprintFrames(frames)
    }

    // MARK: - Voice Access Helpers
    //
    // CRITICAL: No voiceAt() that returns TideVoice by value.
    // Same reasoning as FlowVoiceManager — avoid CoW trigger.

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

    private mutating func allocateVoice(pitch: Int, velocity: Double, sampleRate: Double) {
        // First: reuse a voice already playing this pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch {
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Second: find an idle voice
        for i in 0..<Self.voiceCount {
            if !isVoiceActive(i) {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Third: steal the quietest voice
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

    /// Apply TIDE parameters to all 8 voices.
    mutating func configureTide(
        current: Double, pattern: Int, rate: Double,
        rateSync: Bool, rateDivisionBeats: Double,
        depth: Double, warmth: Double,
        funcShape: Int, funcAmount: Double, funcSkew: Double, funcCycles: Int
    ) {
        applyConfig(&voices.0, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.1, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.2, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.3, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.4, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.5, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.6, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
        applyConfig(&voices.7, current: current, pattern: pattern, rate: rate, rateSync: rateSync, rateDivisionBeats: rateDivisionBeats, depth: depth, warmth: warmth, funcShape: funcShape, funcAmount: funcAmount, funcSkew: funcSkew, funcCycles: funcCycles)
    }

    /// Update BPM on all voices (called when sequencer BPM changes).
    mutating func setBPM(_ bpm: Double) {
        voices.0.bpm = bpm
        voices.1.bpm = bpm
        voices.2.bpm = bpm
        voices.3.bpm = bpm
        voices.4.bpm = bpm
        voices.5.bpm = bpm
        voices.6.bpm = bpm
        voices.7.bpm = bpm
    }

    private func applyConfig(
        _ voice: inout TideVoice,
        current: Double, pattern: Int, rate: Double,
        rateSync: Bool, rateDivisionBeats: Double,
        depth: Double, warmth: Double,
        funcShape: Int, funcAmount: Double, funcSkew: Double, funcCycles: Int
    ) {
        voice.currentTarget = current
        voice.rateTarget = rate
        voice.rateSyncEnabled = rateSync
        voice.rateDivisionBeats = rateDivisionBeats
        voice.depthTarget = depth
        voice.warmthTarget = warmth
        voice.funcShapeRaw = funcShape
        voice.funcAmountTarget = funcAmount
        voice.funcSkewTarget = funcSkew
        voice.funcCycles = funcCycles
        if voice.patternIndex != pattern {
            voice.setPattern(pattern)
        }
    }

    /// Render one stereo sample: sum all 8 voices, then soft-limit once.
    mutating func renderStereoSample(sampleRate: Double) -> (Float, Float) {
        var mixL: Float = 0
        var mixR: Float = 0

        let (l0, r0) = voices.0.renderSample(sampleRate: sampleRate)
        let (l1, r1) = voices.1.renderSample(sampleRate: sampleRate)
        let (l2, r2) = voices.2.renderSample(sampleRate: sampleRate)
        let (l3, r3) = voices.3.renderSample(sampleRate: sampleRate)
        let (l4, r4) = voices.4.renderSample(sampleRate: sampleRate)
        let (l5, r5) = voices.5.renderSample(sampleRate: sampleRate)
        let (l6, r6) = voices.6.renderSample(sampleRate: sampleRate)
        let (l7, r7) = voices.7.renderSample(sampleRate: sampleRate)

        mixL = l0 + l1 + l2 + l3 + l4 + l5 + l6 + l7
        mixR = r0 + r1 + r2 + r3 + r4 + r5 + r6 + r7

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

        // Safety tanh at the sum (same approach as FlowVoiceManager)
        let outL = Float(tanh(Double(mixL) * 0.5) * 6.0)
        let outR = Float(tanh(Double(mixR) * 0.5) * 6.0)

        return (outL, outR)
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

extension TideVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
        // frequency parameter ignored — TideVoice computes its own from pitch
        allocateVoice(pitch: pitch, velocity: velocity, sampleRate: sampleRate)
    }

    mutating func noteOff(pitch: Int) {
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch && isVoiceActive(i) {
                releaseVoiceAt(i, sampleRate: sampleRate)
                return
            }
        }
    }

    mutating func renderSample(sampleRate: Double) -> Float {
        // NoteReceiver requires mono — sum stereo to mono
        let (l, r) = renderStereoSample(sampleRate: sampleRate)
        return (l + r) * 0.5
    }
}
