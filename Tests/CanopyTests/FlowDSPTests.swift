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
}
