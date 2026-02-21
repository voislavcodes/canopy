import Foundation

/// 8-voice polyphonic manager for the SPORE engine.
/// Tuple storage for stack allocation — no ARC, no indirection on the audio thread.
/// Same pattern as FlowVoiceManager.
struct SporeVoiceManager {
    /// Voices stored as tuple for stack allocation (zero ARC on audio thread).
    var voices: (SporeVoice, SporeVoice, SporeVoice, SporeVoice,
                 SporeVoice, SporeVoice, SporeVoice, SporeVoice)

    /// MIDI pitch assigned to each voice (-1 = free).
    var pitches: (Int, Int, Int, Int, Int, Int, Int, Int)

    static let voiceCount = 8

    /// Sample rate stored from render callback.
    var sampleRate: Double = 48000

    /// Imprint harmonic amplitudes (64 values). When set, new notes use these
    /// as harmonic weights instead of the default 1/h falloff.
    var imprintAmplitudes: (Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float)?

    init() {
        voices = (SporeVoice(), SporeVoice(), SporeVoice(), SporeVoice(),
                  SporeVoice(), SporeVoice(), SporeVoice(), SporeVoice())
        pitches = (-1, -1, -1, -1, -1, -1, -1, -1)

        // Unique noise seeds per voice (Rule 10: decorrelate grain streams)
        voices.0.noiseState = 0x1234_5678; voices.0.setEvolveSeed(0xAAAA_1111)
        voices.1.noiseState = 0x8765_4321; voices.1.setEvolveSeed(0xBBBB_2222)
        voices.2.noiseState = 0xDEAD_BEEF; voices.2.setEvolveSeed(0xCCCC_3333)
        voices.3.noiseState = 0xCAFE_BABE; voices.3.setEvolveSeed(0xDDDD_4444)
        voices.4.noiseState = 0xFACE_FEED; voices.4.setEvolveSeed(0xEEEE_5555)
        voices.5.noiseState = 0xBAAD_F00D; voices.5.setEvolveSeed(0xFFFF_6666)
        voices.6.noiseState = 0xD00D_BEAD; voices.6.setEvolveSeed(0x1111_7777)
        voices.7.noiseState = 0xC0DE_F00D; voices.7.setEvolveSeed(0x2222_8888)
    }

    // MARK: - Imprint

    /// Set or clear imprint harmonic amplitudes. When set, new voices will use
    /// these as harmonic weights instead of the default 1/h falloff.
    mutating func setImprint(_ amplitudes: [Float]?) {
        guard let amps = amplitudes, amps.count >= 64 else {
            imprintAmplitudes = nil
            // Reset all voices to default weights
            resetHarmonicWeights(&voices.0)
            resetHarmonicWeights(&voices.1)
            resetHarmonicWeights(&voices.2)
            resetHarmonicWeights(&voices.3)
            resetHarmonicWeights(&voices.4)
            resetHarmonicWeights(&voices.5)
            resetHarmonicWeights(&voices.6)
            resetHarmonicWeights(&voices.7)
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
        // Apply to all voices
        applyImprintWeights(&voices.0, amps)
        applyImprintWeights(&voices.1, amps)
        applyImprintWeights(&voices.2, amps)
        applyImprintWeights(&voices.3, amps)
        applyImprintWeights(&voices.4, amps)
        applyImprintWeights(&voices.5, amps)
        applyImprintWeights(&voices.6, amps)
        applyImprintWeights(&voices.7, amps)
    }

    private func applyImprintWeights(_ voice: inout SporeVoice, _ amps: [Float]) {
        voice.useImprint = true
        withUnsafeMutablePointer(to: &voice.harmonicWeights) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: SporeVoice.harmonicCount) { p in
                for i in 0..<min(64, amps.count) {
                    p[i] = Double(amps[i])
                }
            }
        }
    }

    private func resetHarmonicWeights(_ voice: inout SporeVoice) {
        voice.useImprint = false
        withUnsafeMutablePointer(to: &voice.harmonicWeights) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: SporeVoice.harmonicCount) { p in
                for i in 0..<SporeVoice.harmonicCount {
                    p[i] = 1.0 / Double(i + 1)
                }
            }
        }
    }

    // MARK: - Voice Access Helpers

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
        // Reuse same pitch
        for i in 0..<Self.voiceCount {
            if pitchAt(i) == pitch {
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Find idle
        for i in 0..<Self.voiceCount {
            if !isVoiceActive(i) {
                setPitch(i, pitch)
                triggerVoiceAt(i, pitch: pitch, velocity: velocity, sampleRate: sampleRate)
                return
            }
        }

        // Steal quietest
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

    /// Apply SPORE parameters to all 8 voices.
    mutating func configureSpore(
        density: Double, focus: Double, grain: Double,
        evolve: Double, warmth: Double
    ) {
        applyConfig(&voices.0, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.1, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.2, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.3, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.4, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.5, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.6, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
        applyConfig(&voices.7, density: density, focus: focus, grain: grain, evolve: evolve, warmth: warmth)
    }

    private func applyConfig(
        _ voice: inout SporeVoice,
        density: Double, focus: Double, grain: Double,
        evolve: Double, warmth: Double
    ) {
        voice.densityTarget = density
        voice.focusTarget = focus
        voice.grainTarget = grain
        voice.evolveTarget = evolve
        voice.warmthTarget = warmth
    }

    /// Render one stereo sample: sum all 8 voices, then safety tanh.
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

        // Manager-level safety tanh (Rule 6): catches multi-voice sum peaks
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

extension SporeVoiceManager: NoteReceiver {
    mutating func noteOn(pitch: Int, velocity: Double, frequency: Double) {
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
        let (left, right) = renderStereoSample(sampleRate: sampleRate)
        return (left + right) * 0.5
    }
}
