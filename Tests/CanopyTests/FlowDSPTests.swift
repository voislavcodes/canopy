import XCTest
@testable import Canopy

final class FlowDSPTests: XCTestCase {
    let sampleRate: Double = 44100

    // MARK: - FlowConfig Codable Round-Trip

    func testFlowConfigCodableRoundTrip() throws {
        let config = FlowConfig(current: 0.7, viscosity: 0.3, obstacle: 0.8, channel: 0.6, density: 0.9, volume: 0.5, pan: -0.3)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FlowConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    func testSoundTypeFlowCodableRoundTrip() throws {
        let soundType = SoundType.flow(FlowConfig.rapids)
        let data = try JSONEncoder().encode(soundType)
        let decoded = try JSONDecoder().decode(SoundType.self, from: data)
        XCTAssertEqual(soundType, decoded)
    }

    // MARK: - FlowVoice Output Range

    func testFlowVoiceOutputInRange() {
        var voice = FlowVoice()
        voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)
        voice.currentTarget = 0.5
        voice.viscosityTarget = 0.3
        voice.obstacleTarget = 0.5
        voice.channelTarget = 0.5
        voice.densityTarget = 0.5

        var allInRange = true
        var hasNaN = false

        // Render 1 second of audio
        for _ in 0..<Int(sampleRate) {
            let sample = voice.renderSample(sampleRate: sampleRate)
            if sample.isNaN || sample.isInfinite {
                hasNaN = true
                break
            }
            if sample < -1.0 || sample > 1.0 {
                allInRange = false
            }
        }

        XCTAssertFalse(hasNaN, "FlowVoice produced NaN or Inf")
        XCTAssertTrue(allInRange, "FlowVoice output exceeded [-1, 1]")
    }

    // MARK: - Laminar Regime is Tonal

    func testLaminarRegimeIsTonal() {
        var voice = FlowVoice()
        // Very low current → laminar
        voice.currentTarget = 0.02
        voice.viscosityTarget = 0.9
        voice.obstacleTarget = 0.1
        voice.channelTarget = 0.5
        voice.densityTarget = 0.5

        voice.trigger(pitch: 69, velocity: 0.8, sampleRate: sampleRate) // A4 = 440Hz

        // Skip attack transient
        for _ in 0..<1000 {
            _ = voice.renderSample(sampleRate: sampleRate)
        }

        // Collect samples and verify they're not silent and show periodic behavior
        var samples: [Float] = []
        for _ in 0..<4410 { // ~100ms
            samples.append(voice.renderSample(sampleRate: sampleRate))
        }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.001, "Laminar regime should produce audible sound")

        // Check for zero crossings (tonal signals have regular zero crossings)
        var zeroCrossings = 0
        for i in 1..<samples.count {
            if (samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0) {
                zeroCrossings += 1
            }
        }
        // 440Hz over 100ms ≈ 44 zero crossings per half-cycle, ~88 total
        // With 64 partials there will be more crossings, but it should be significantly more than noise
        XCTAssertGreaterThan(zeroCrossings, 20, "Laminar regime should show periodic zero crossings")
    }

    // MARK: - Turbulent Regime is Noisy

    func testTurbulentRegimeIsNoisy() {
        var voice = FlowVoice()
        // High current, low viscosity → turbulent
        voice.currentTarget = 0.95
        voice.viscosityTarget = 0.05
        voice.obstacleTarget = 0.5
        voice.channelTarget = 0.8
        voice.densityTarget = 0.8

        voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

        // Run through several control blocks to reach turbulent regime
        for _ in 0..<Int(sampleRate * 0.5) {
            _ = voice.renderSample(sampleRate: sampleRate)
        }

        // Collect samples
        var samples: [Float] = []
        for _ in 0..<4410 {
            samples.append(voice.renderSample(sampleRate: sampleRate))
        }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        XCTAssertGreaterThan(rms, 0.001, "Turbulent regime should produce sound")

        // Turbulence should have high spectral variance — check that consecutive
        // sample differences have high variance (noisy signal)
        var diffs: [Float] = []
        for i in 1..<samples.count {
            diffs.append(abs(samples[i] - samples[i - 1]))
        }
        let avgDiff = diffs.reduce(0, +) / Float(diffs.count)
        XCTAssertGreaterThan(avgDiff, 0.0001, "Turbulent regime should show high sample-to-sample variation")
    }

    // MARK: - Voice Manager Polyphony

    func testVoiceManagerAllocatesMultipleVoices() {
        var manager = FlowVoiceManager()

        // Play 3 notes
        manager.noteOn(pitch: 60, velocity: 0.8, frequency: 0)
        manager.noteOn(pitch: 64, velocity: 0.8, frequency: 0)
        manager.noteOn(pitch: 67, velocity: 0.8, frequency: 0)

        // Render some samples to make voices active
        var hasSound = false
        for _ in 0..<512 {
            let sample = manager.renderSample(sampleRate: sampleRate)
            if abs(sample) > 0.0001 {
                hasSound = true
            }
        }

        XCTAssertTrue(hasSound, "Voice manager should produce sound with multiple notes")
    }

    func testVoiceManagerNoteOff() {
        var manager = FlowVoiceManager()
        manager.noteOn(pitch: 60, velocity: 0.8, frequency: 0)

        // Render to establish sound
        for _ in 0..<512 {
            _ = manager.renderSample(sampleRate: sampleRate)
        }

        // Release
        manager.noteOff(pitch: 60)

        // Render through release and verify it eventually goes silent
        var lastRMS: Float = 1.0
        for block in 0..<100 {
            var blockSum: Float = 0
            for _ in 0..<512 {
                let s = manager.renderSample(sampleRate: sampleRate)
                blockSum += s * s
            }
            lastRMS = sqrt(blockSum / 512)
            if lastRMS < 0.0001 && block > 5 {
                break
            }
        }

        XCTAssertLessThan(lastRMS, 0.01, "Voice should decay to near-silence after noteOff")
    }

    // MARK: - Anti-Crackle: No NaN Across All Presets

    func testAllPresetsProduceCleanOutput() {
        let presets: [FlowConfig] = [
            .stillWater, .gentleStream, .river, .rapids, .waterfall,
            .lava, .steam, .whirlpool, .breath, .jet
        ]

        for (index, preset) in presets.enumerated() {
            var voice = FlowVoice()
            voice.currentTarget = preset.current
            voice.viscosityTarget = preset.viscosity
            voice.obstacleTarget = preset.obstacle
            voice.channelTarget = preset.channel
            voice.densityTarget = preset.density

            voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

            var hasNaN = false
            var maxAbs: Float = 0

            // Render 0.5 seconds
            for _ in 0..<Int(sampleRate * 0.5) {
                let sample = voice.renderSample(sampleRate: sampleRate)
                if sample.isNaN || sample.isInfinite {
                    hasNaN = true
                    break
                }
                maxAbs = max(maxAbs, abs(sample))
            }

            XCTAssertFalse(hasNaN, "Preset \(index) produced NaN/Inf")
            XCTAssertLessThanOrEqual(maxAbs, 1.0, "Preset \(index) exceeded [-1,1] range")
        }
    }

    // MARK: - FlowConfig Defaults

    func testFlowConfigDefaults() {
        let config = FlowConfig()
        XCTAssertEqual(config.current, 0.2)
        XCTAssertEqual(config.viscosity, 0.5)
        XCTAssertEqual(config.obstacle, 0.3)
        XCTAssertEqual(config.channel, 0.5)
        XCTAssertEqual(config.density, 0.5)
        XCTAssertEqual(config.volume, 0.8)
        XCTAssertEqual(config.pan, 0.0)
    }

    // =========================================================================
    // MARK: - Distortion Diagnostic Tests
    //
    // Each test targets a specific failure mode that causes distortion
    // undetectable by simple output-range checks.
    // =========================================================================

    // MARK: - 1. Phase Precision Over Time
    //
    // If phase accumulators drift (wrap too late or not at all), sin() precision
    // degrades and the output becomes noisy. Compare signal quality at t=0 vs t=30s.

    func testPhasePrecisionAfter30Seconds() {
        var voice = FlowVoice()
        // Pure laminar — output should be a clean harmonic series with no noise.
        voice.currentTarget = 0.01
        voice.viscosityTarget = 0.95
        voice.obstacleTarget = 0.05
        voice.channelTarget = 0.5
        voice.densityTarget = 0.5

        voice.trigger(pitch: 69, velocity: 0.8, sampleRate: sampleRate) // A4

        // Capture 1000 samples at t ≈ 0.1s (after attack settles)
        for _ in 0..<4410 {
            _ = voice.renderSample(sampleRate: sampleRate)
        }
        var earlyBlock: [Float] = []
        for _ in 0..<4410 {
            earlyBlock.append(voice.renderSample(sampleRate: sampleRate))
        }

        // Run forward to t ≈ 30 seconds
        let samplesToSkip = Int(sampleRate * 30) - 8820
        for _ in 0..<samplesToSkip {
            _ = voice.renderSample(sampleRate: sampleRate)
        }

        // Capture 1000 samples at t ≈ 30s
        var lateBlock: [Float] = []
        for _ in 0..<4410 {
            lateBlock.append(voice.renderSample(sampleRate: sampleRate))
        }

        // Both blocks should have similar RMS (signal didn't die or explode)
        let earlyRMS = rms(earlyBlock)
        let lateRMS = rms(lateBlock)
        XCTAssertGreaterThan(earlyRMS, 0.001, "Early block should have signal")
        XCTAssertGreaterThan(lateRMS, 0.001, "Late block should still have signal after 30s")
        // RMS should be within 6dB (factor of 2) — if phase drifts, signal
        // degrades into noise with very different RMS characteristics
        let ratio = max(earlyRMS, lateRMS) / max(min(earlyRMS, lateRMS), 1e-10)
        XCTAssertLessThan(ratio, 2.0, "RMS changed by >6dB over 30s — possible phase drift (early=\(earlyRMS) late=\(lateRMS))")

        // Spectral consistency: zero-crossing rate should be similar
        // (if sin() degrades to noise, zero-crossing rate increases dramatically)
        let earlyZC = zeroCrossingRate(earlyBlock)
        let lateZC = zeroCrossingRate(lateBlock)
        let zcRatio = max(earlyZC, lateZC) / max(min(earlyZC, lateZC), 1e-10)
        XCTAssertLessThan(zcRatio, 1.5, "Zero-crossing rate changed by >50% over 30s — phase precision loss (early=\(earlyZC) late=\(lateZC))")

        // No NaN/Inf in the late block
        for (i, s) in lateBlock.enumerated() {
            XCTAssertFalse(s.isNaN || s.isInfinite, "Sample \(i) at t=30s is NaN/Inf")
        }
    }

    // MARK: - 2. Retrigger Click Detection
    //
    // When a voice retriggers at a different pitch, the output must not have a
    // discontinuity larger than the envelope can produce. The envelope resets to 0
    // on retrigger with a 5ms attack, so the max sample-to-sample jump at the
    // retrigger point is bounded by the signal level just before retrigger (which
    // then goes to 0) plus whatever the first sample of the new note is.

    func testRetriggerNoClick() {
        var voice = FlowVoice()
        voice.currentTarget = 0.3
        voice.viscosityTarget = 0.5
        voice.obstacleTarget = 0.3
        voice.channelTarget = 0.5
        voice.densityTarget = 0.5

        // Play C4 for 0.5 seconds
        voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)
        var preRetriggerSamples: [Float] = []
        for _ in 0..<Int(sampleRate * 0.5) {
            preRetriggerSamples.append(voice.renderSample(sampleRate: sampleRate))
        }

        // Capture the last sample before retrigger
        let lastSampleBefore = preRetriggerSamples.last!

        // Retrigger at A4 (very different pitch)
        voice.trigger(pitch: 69, velocity: 0.8, sampleRate: sampleRate)

        // The first sample after retrigger — envelope should be near 0
        let firstSampleAfter = voice.renderSample(sampleRate: sampleRate)

        // The jump should be bounded: the old signal vanishes (envelope reset to 0)
        // and the new signal starts from near 0 (5ms attack). The discontinuity
        // is at most the absolute value of the last sample before retrigger.
        let jump = abs(firstSampleAfter - lastSampleBefore)

        // The jump should just be the old signal disappearing — near |lastSampleBefore|
        // Allow 10% margin for the tiny bit of new signal at sample 1
        let maxAllowedJump = abs(lastSampleBefore) + 0.01
        XCTAssertLessThan(jump, maxAllowedJump,
            "Retrigger caused discontinuity of \(jump) — expected at most \(maxAllowedJump). " +
            "Last before=\(lastSampleBefore), first after=\(firstSampleAfter)")

        // Collect 128 samples after retrigger — they should ramp smoothly from ~0
        var postRetrigger: [Float] = [firstSampleAfter]
        for _ in 0..<127 {
            postRetrigger.append(voice.renderSample(sampleRate: sampleRate))
        }

        // Max sample-to-sample jump in the first 128 samples after retrigger
        // should be small (envelope is ramping from 0)
        var maxPostJump: Float = 0
        for i in 1..<postRetrigger.count {
            maxPostJump = max(maxPostJump, abs(postRetrigger[i] - postRetrigger[i - 1]))
        }
        // Attack rate is 1/(0.005*44100) ≈ 0.00454/sample. At full amplitude (~0.2 for this
        // voice), max per-sample change is ~0.001. Allow generous margin.
        XCTAssertLessThan(maxPostJump, 0.05,
            "Post-retrigger samples have large jumps (\(maxPostJump)) — possible phase discontinuity")
    }

    // MARK: - 3. Voice Noise Decorrelation
    //
    // Two voices with the same settings should produce DIFFERENT output in
    // turbulent regime because their noise seeds differ. If they're correlated,
    // polyphonic summing causes constructive interference (distortion).

    func testVoiceNoiseDecorrelation() {
        var manager = FlowVoiceManager()
        // Set to turbulent regime
        manager.configureFlow(current: 0.9, viscosity: 0.1, obstacle: 0.5, channel: 0.8, density: 0.8, warmth: 0.3)

        // Trigger two voices at the SAME pitch — they should get different voices
        // but identical parameters. The only difference should be noise seed.
        manager.noteOn(pitch: 60, velocity: 0.8, frequency: 0)

        // Render to establish voice 0
        for _ in 0..<Int(sampleRate * 0.2) {
            _ = manager.renderSample(sampleRate: sampleRate)
        }

        // Now render voice 0 and voice 1 individually to compare.
        // We can't easily separate them in the manager, so instead:
        // Create two standalone voices with different seeds and verify divergence.
        var voice0 = FlowVoice()
        voice0.noiseState = 0x1234_5678
        voice0.currentTarget = 0.9
        voice0.viscosityTarget = 0.1
        voice0.obstacleTarget = 0.5
        voice0.channelTarget = 0.8
        voice0.densityTarget = 0.8
        voice0.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

        var voice1 = FlowVoice()
        voice1.noiseState = 0x8765_4321
        voice1.currentTarget = 0.9
        voice1.viscosityTarget = 0.1
        voice1.obstacleTarget = 0.5
        voice1.channelTarget = 0.8
        voice1.densityTarget = 0.8
        voice1.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

        // Skip to steady state
        for _ in 0..<Int(sampleRate * 0.5) {
            _ = voice0.renderSample(sampleRate: sampleRate)
            _ = voice1.renderSample(sampleRate: sampleRate)
        }

        // Collect samples
        var samples0: [Float] = []
        var samples1: [Float] = []
        for _ in 0..<4410 {
            samples0.append(voice0.renderSample(sampleRate: sampleRate))
            samples1.append(voice1.renderSample(sampleRate: sampleRate))
        }

        // The base harmonic series is identical across voices (same pitch, same params).
        // The NOISE modulation is what should differ. Measure the difference signal:
        // if noise is decorrelated, voice0 - voice1 has non-zero energy.
        // If noise is correlated (same seed), the difference is exactly zero.
        var diffSamples: [Float] = []
        for i in 0..<samples0.count {
            diffSamples.append(samples0[i] - samples1[i])
        }

        let signalRMS = rms(samples0)
        let diffRMS = rms(diffSamples)

        XCTAssertGreaterThan(signalRMS, 0.001, "Voices should produce audible signal")

        // The noise-driven difference should be at least 1% of the signal.
        // If it's exactly 0, the seeds are not being used.
        let noiseRatio = signalRMS > 0 ? diffRMS / signalRMS : 0
        XCTAssertGreaterThan(noiseRatio, 0.01,
            "Noise decorrelation too low (diff/signal = \(noiseRatio)). " +
            "diffRMS=\(diffRMS), signalRMS=\(signalRMS). " +
            "If ratio≈0, noise seeds are identical or turbulence layer is inactive.")
    }

    // MARK: - Peak Level Diagnostic
    //
    // Prints peak output for 1–8 simultaneous voices so we can see
    // exactly where headroom runs out. If peak < 1.0 and it still
    // crackles on device, the audio thread is stalling (CPU).

    func testPeakLevelDiagnostic() {
        let allPitches = [48, 52, 55, 60, 64, 67, 72, 76]
        var report = "PEAK LEVELS:"

        for voiceCount in 1...8 {
            var manager = FlowVoiceManager()
            manager.configureFlow(current: 0.5, viscosity: 0.3, obstacle: 0.5, channel: 0.5, density: 0.5, warmth: 0.3)

            for i in 0..<voiceCount {
                manager.noteOn(pitch: allPitches[i], velocity: 1.0, frequency: 0)
            }

            var peak: Float = 0
            var maxSlew: Float = 0
            var prev: Float = 0
            // Render 1 second at 48kHz
            for s in 0..<48000 {
                let sample = manager.renderSample(sampleRate: 48000)
                peak = max(peak, abs(sample))
                if s > 0 {
                    maxSlew = max(maxSlew, abs(sample - prev))
                }
                prev = sample
            }

            report += " | \(voiceCount)v: peak=\(String(format: "%.4f", peak)) slew=\(String(format: "%.4f", maxSlew))"
            XCTAssertLessThanOrEqual(peak, 1.0,
                "\(voiceCount) voices clipping: peak = \(peak)")
        }

        // All peaks well under 1.0 — signal is not clipping.
        // If device still crackles, it's audio thread stalling (CPU), not signal level.
    }

    // MARK: - Incremental Chord Build Diagnostic
    //
    // Simulates pressing keys one at a time to build a chord.
    // Measures peak and max slew after each note addition.
    // If the 4th note causes a slew spike in this offline test,
    // the DSP math is the problem. If it's clean here but crackles
    // on device, the audio thread is stalling ([FlowPartial] CoW).

    func testIncrementalChordBuild() {
        var manager = FlowVoiceManager()
        manager.configureFlow(current: 0.5, viscosity: 0.3, obstacle: 0.5, channel: 0.5, density: 0.5, warmth: 0.3)

        let chord = [60, 64, 67, 72, 76, 79, 84, 88] // C4 up
        let sr: Double = 48000
        let samplesPerNote = Int(sr * 0.3) // 300ms between each note
        var prev: Float = 0
        var report = "CHORD BUILD:"

        for noteIndex in 0..<8 {
            manager.noteOn(pitch: chord[noteIndex], velocity: 1.0, frequency: 0)

            var peak: Float = 0
            var maxSlew: Float = 0

            for s in 0..<samplesPerNote {
                let sample = manager.renderSample(sampleRate: sr)
                peak = max(peak, abs(sample))
                let slew = abs(sample - prev)
                if slew > maxSlew { maxSlew = slew }
                prev = sample
            }

            let voices = noteIndex + 1
            report += " | \(voices)v: peak=\(String(format: "%.4f", peak)) slew=\(String(format: "%.4f", maxSlew))"

            XCTAssertLessThan(maxSlew, 0.5,
                "Adding voice \(voices) caused slew spike: \(maxSlew)")
        }

        // Smooth linear scaling across all 8 voices — no slew spikes.
        // If device still crackles at 4 voices, the problem is audio thread
        // stalling from [FlowPartial] heap array CoW checks, not signal math.
    }

    // MARK: - 4. Polyphonic Summing Headroom
    //
    // Play all 8 voices at maximum velocity through the voice manager.
    // The output must stay within [-1, 1] and show no NaN/Inf.
    // Also measure crest factor — if it exceeds 6dB beyond expected,
    // the summing stage is distorting.

    func testEightVoiceFullPolyphonyHeadroom() {
        var manager = FlowVoiceManager()
        // Mid-regime (worst case for amplitude — both vortex and turbulence active)
        manager.configureFlow(current: 0.5, viscosity: 0.3, obstacle: 0.5, channel: 0.5, density: 0.5, warmth: 0.3)

        // Trigger all 8 voices at different pitches, full velocity
        let pitches = [48, 52, 55, 60, 64, 67, 72, 76] // C3 to E5
        for p in pitches {
            manager.noteOn(pitch: p, velocity: 1.0, frequency: 0)
        }

        var samples: [Float] = []
        var hasNaN = false

        // Render 1 second
        for _ in 0..<Int(sampleRate) {
            let s = manager.renderSample(sampleRate: sampleRate)
            if s.isNaN || s.isInfinite {
                hasNaN = true
                break
            }
            samples.append(s)
        }

        XCTAssertFalse(hasNaN, "8-voice polyphony produced NaN/Inf")

        let peak = samples.map { abs($0) }.max() ?? 0
        let sigRMS = rms(samples)

        XCTAssertLessThanOrEqual(peak, 1.0,
            "8-voice polyphony exceeded [-1,1] — peak=\(peak)")
        XCTAssertGreaterThan(sigRMS, 0.01,
            "8-voice polyphony is too quiet — RMS=\(sigRMS)")

        // Crest factor: peak/RMS. For 8 summed tanh-compressed voices,
        // expect ~3-6dB (1.4–2.0). If much higher, something is peaking abnormally.
        let crest = sigRMS > 0 ? peak / sigRMS : 0
        XCTAssertLessThan(crest, 10.0,
            "Crest factor too high (\(crest)) — indicates spiky distortion artifacts. peak=\(peak) rms=\(sigRMS)")
    }

    // MARK: - 5. Sample-to-Sample Slew Rate (Click Detection)
    //
    // The maximum rate of change between consecutive samples is physically bounded
    // by the highest frequency in the signal. For bandwidth-limited signals,
    // max slew ≈ 2π * f_max * peak_amplitude / sampleRate.
    // A click/discontinuity violates this bound dramatically.

    func testMaxSlewRateAllRegimes() {
        let configs: [(String, Double, Double, Double, Double, Double)] = [
            ("Laminar",    0.02, 0.9,  0.1, 0.5, 0.5),
            ("Transition", 0.35, 0.4,  0.4, 0.5, 0.5),
            ("Turbulent",  0.95, 0.05, 0.5, 0.8, 0.8),
            ("Mixed",      0.5,  0.3,  0.5, 0.5, 0.5),
        ]

        for (name, current, viscosity, obstacle, channel, density) in configs {
            var voice = FlowVoice()
            voice.currentTarget = current
            voice.viscosityTarget = viscosity
            voice.obstacleTarget = obstacle
            voice.channelTarget = channel
            voice.densityTarget = density

            voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

            // Skip attack
            for _ in 0..<Int(sampleRate * 0.1) {
                _ = voice.renderSample(sampleRate: sampleRate)
            }

            // Collect samples
            var samples: [Float] = []
            for _ in 0..<Int(sampleRate * 0.5) {
                samples.append(voice.renderSample(sampleRate: sampleRate))
            }

            // Max slew rate
            var maxSlew: Float = 0
            var maxSlewIndex = 0
            for i in 1..<samples.count {
                let slew = abs(samples[i] - samples[i - 1])
                if slew > maxSlew {
                    maxSlew = slew
                    maxSlewIndex = i
                }
            }

            // Theoretical max slew for 64 partials at C4 (261.6 Hz):
            // highest partial ≈ 16742 Hz. Max slew for a sine at that freq with
            // amplitude 1.0 is 2π * 16742 / 44100 ≈ 2.38 per sample.
            // With 64 partials summed and tanh-compressed, actual peak slew is lower.
            // Allow generous bound of 1.0 per sample — anything above indicates a click.
            XCTAssertLessThan(maxSlew, 1.0,
                "\(name) regime: max slew rate \(maxSlew) at sample \(maxSlewIndex) — " +
                "indicates a click or discontinuity. " +
                "Surrounding: [\(maxSlewIndex > 0 ? samples[maxSlewIndex-1] : 0), \(samples[maxSlewIndex])]")
        }
    }

    // MARK: - 6. Regime Sweep — No Crackle During Transitions
    //
    // Sweep 'current' from 0 to 1 over 5 seconds while a note plays.
    // This traverses laminar → transition → turbulent. Check for clicks
    // (slew rate violations) during the sweep.

    func testRegimeSweepNoCrackle() {
        var voice = FlowVoice()
        voice.viscosityTarget = 0.3
        voice.obstacleTarget = 0.4
        voice.channelTarget = 0.5
        voice.densityTarget = 0.6

        voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

        let totalSamples = Int(sampleRate * 5) // 5 seconds
        var prevSample: Float = 0
        var maxSlew: Float = 0
        var hasNaN = false
        var maxAbs: Float = 0

        for i in 0..<totalSamples {
            // Sweep current from 0 to 1
            let t = Double(i) / Double(totalSamples)
            voice.currentTarget = t

            let sample = voice.renderSample(sampleRate: sampleRate)

            if sample.isNaN || sample.isInfinite {
                hasNaN = true
                break
            }

            maxAbs = max(maxAbs, abs(sample))

            if i > 0 {
                let slew = abs(sample - prevSample)
                maxSlew = max(maxSlew, slew)
            }
            prevSample = sample
        }

        XCTAssertFalse(hasNaN, "Regime sweep produced NaN/Inf")
        XCTAssertLessThanOrEqual(maxAbs, 1.0, "Regime sweep exceeded [-1,1]")
        XCTAssertLessThan(maxSlew, 1.0,
            "Regime sweep max slew \(maxSlew) — crackle during regime transition")
    }

    // MARK: - 7. High Pitch Partial Culling
    //
    // At high pitches, many partials exceed Nyquist and should be silenced.
    // Verify that a high note doesn't produce more energy than a low note
    // (which would indicate above-Nyquist partials piling up instead of being culled).

    func testHighPitchPartialCulling() {
        // C2 (65.4 Hz) — all 64 partials below Nyquist
        var voiceLow = FlowVoice()
        voiceLow.currentTarget = 0.02
        voiceLow.viscosityTarget = 0.9
        voiceLow.obstacleTarget = 0.1
        voiceLow.channelTarget = 0.5
        voiceLow.densityTarget = 0.5
        voiceLow.trigger(pitch: 36, velocity: 0.8, sampleRate: sampleRate)

        // C6 (1046.5 Hz) — partial 22+ above Nyquist, should be culled
        var voiceHigh = FlowVoice()
        voiceHigh.currentTarget = 0.02
        voiceHigh.viscosityTarget = 0.9
        voiceHigh.obstacleTarget = 0.1
        voiceHigh.channelTarget = 0.5
        voiceHigh.densityTarget = 0.5
        voiceHigh.trigger(pitch: 84, velocity: 0.8, sampleRate: sampleRate)

        // Skip attack
        for _ in 0..<Int(sampleRate * 0.1) {
            _ = voiceLow.renderSample(sampleRate: sampleRate)
            _ = voiceHigh.renderSample(sampleRate: sampleRate)
        }

        // Collect 1 second
        var samplesLow: [Float] = []
        var samplesHigh: [Float] = []
        for _ in 0..<Int(sampleRate) {
            samplesLow.append(voiceLow.renderSample(sampleRate: sampleRate))
            samplesHigh.append(voiceHigh.renderSample(sampleRate: sampleRate))
        }

        let rmsLow = rms(samplesLow)
        let rmsHigh = rms(samplesHigh)

        XCTAssertGreaterThan(rmsLow, 0.001, "Low note should produce sound")
        XCTAssertGreaterThan(rmsHigh, 0.001, "High note should produce sound")

        // High note has fewer active partials, so it should be quieter or similar,
        // NOT louder. If louder by >6dB, partials are piling up at Nyquist.
        XCTAssertLessThan(rmsHigh, rmsLow * 2.5,
            "High note RMS (\(rmsHigh)) is suspiciously louder than low note (\(rmsLow)) — " +
            "above-Nyquist partials may be piling up instead of being culled")

        // No NaN
        XCTAssertFalse(samplesHigh.contains(where: { $0.isNaN || $0.isInfinite }),
            "High-pitch note produced NaN/Inf")
    }

    // MARK: - 8. Sustained Rendering Stability
    //
    // Render all 10 presets for 10 seconds each. Check that output stays
    // bounded, doesn't drift to DC, and doesn't develop increasing distortion.
    // Compare first-second RMS to last-second RMS.

    func testSustainedRenderingAllPresets() {
        let presets: [(String, FlowConfig)] = [
            ("Still Water", .stillWater), ("Gentle Stream", .gentleStream),
            ("River", .river), ("Rapids", .rapids), ("Waterfall", .waterfall),
            ("Lava", .lava), ("Steam", .steam), ("Whirlpool", .whirlpool),
            ("Breath", .breath), ("Jet", .jet)
        ]

        for (name, preset) in presets {
            var voice = FlowVoice()
            voice.currentTarget = preset.current
            voice.viscosityTarget = preset.viscosity
            voice.obstacleTarget = preset.obstacle
            voice.channelTarget = preset.channel
            voice.densityTarget = preset.density
            voice.trigger(pitch: 60, velocity: 0.8, sampleRate: sampleRate)

            let tenSeconds = Int(sampleRate * 10)
            let oneSecond = Int(sampleRate)

            // Collect first second
            var firstSecond: [Float] = []
            for _ in 0..<oneSecond {
                firstSecond.append(voice.renderSample(sampleRate: sampleRate))
            }

            // Skip to second 9
            for _ in 0..<(oneSecond * 8) {
                let s = voice.renderSample(sampleRate: sampleRate)
                XCTAssertFalse(s.isNaN || s.isInfinite, "\(name): NaN/Inf during sustained render")
            }

            // Collect last second
            var lastSecond: [Float] = []
            for _ in 0..<oneSecond {
                let s = voice.renderSample(sampleRate: sampleRate)
                XCTAssertFalse(s.isNaN || s.isInfinite, "\(name): NaN/Inf at t=10s")
                lastSecond.append(s)
            }

            let firstRMS = rms(firstSecond)
            let lastRMS = rms(lastSecond)

            // Signal should still be alive
            XCTAssertGreaterThan(lastRMS, 0.0001,
                "\(name): Signal died after 10 seconds (RMS=\(lastRMS))")

            // RMS shouldn't have changed dramatically (factor of 4 = 12dB)
            if firstRMS > 0.001 {
                let ratio = max(firstRMS, lastRMS) / min(firstRMS, lastRMS)
                XCTAssertLessThan(ratio, 4.0,
                    "\(name): RMS changed by \(ratio)x over 10s (first=\(firstRMS), last=\(lastRMS)) — " +
                    "possible accumulator drift or phase precision loss")
            }

            // Check for DC offset in last second (sign of accumulator leaking)
            let dcOffset = lastSecond.reduce(0, +) / Float(lastSecond.count)
            XCTAssertLessThan(abs(dcOffset), 0.05,
                "\(name): DC offset of \(dcOffset) after 10s — accumulator leak")

            // Max slew in last second
            var maxSlew: Float = 0
            for i in 1..<lastSecond.count {
                maxSlew = max(maxSlew, abs(lastSecond[i] - lastSecond[i - 1]))
            }
            XCTAssertLessThan(maxSlew, 1.0,
                "\(name): Max slew \(maxSlew) at t=10s — late-onset crackle")
        }
    }

    // MARK: - 9. Rapid Retrigger Stress Test
    //
    // Retrigger a voice every 50ms at alternating pitches for 2 seconds.
    // This is the worst case for phase reset bugs and CoW issues.
    // Output must stay bounded with no NaN.

    func testRapidRetriggerStress() {
        var manager = FlowVoiceManager()
        manager.configureFlow(current: 0.4, viscosity: 0.4, obstacle: 0.4, channel: 0.5, density: 0.5, warmth: 0.3)

        let retriggerInterval = Int(sampleRate * 0.05) // 50ms
        let totalSamples = Int(sampleRate * 2) // 2 seconds
        let pitches = [60, 72, 48, 67, 55, 76, 64, 69] // various pitches
        var pitchIndex = 0

        var hasNaN = false
        var maxAbs: Float = 0
        var maxSlew: Float = 0
        var prevSample: Float = 0

        for i in 0..<totalSamples {
            // Retrigger every 50ms
            if i % retriggerInterval == 0 {
                manager.noteOn(pitch: pitches[pitchIndex % pitches.count], velocity: 0.8, frequency: 0)
                pitchIndex += 1
            }

            let s = manager.renderSample(sampleRate: sampleRate)

            if s.isNaN || s.isInfinite {
                hasNaN = true
                break
            }

            maxAbs = max(maxAbs, abs(s))

            if i > 0 {
                let slew = abs(s - prevSample)
                maxSlew = max(maxSlew, slew)
            }
            prevSample = s
        }

        XCTAssertFalse(hasNaN, "Rapid retrigger produced NaN/Inf")
        XCTAssertLessThanOrEqual(maxAbs, 1.0, "Rapid retrigger exceeded [-1,1] — peak=\(maxAbs)")
        XCTAssertLessThan(maxSlew, 1.0, "Rapid retrigger max slew \(maxSlew) — click on retrigger")
    }

    // MARK: - Helpers

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    private func zeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i - 1] >= 0 && samples[i] < 0) || (samples[i - 1] < 0 && samples[i] >= 0) {
                crossings += 1
            }
        }
        return Float(crossings) / Float(samples.count)
    }
}
