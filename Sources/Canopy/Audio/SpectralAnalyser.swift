import Accelerate
import Foundation

/// One-shot spectral analysis: takes raw audio samples, returns a SpectralImprint.
/// Runs on a background thread after recording stops. ~50–100ms computation, not real-time.
///
/// Uses Apple's Accelerate framework (vDSP) for FFT and windowing.
/// YIN algorithm for fundamental pitch detection.
enum SpectralAnalyser {
    // MARK: - Configuration

    static let fftSize = 4096
    static let hopSize = 2048
    static let harmonicCount = 64
    static let bandCount = 16
    static let peakCount = 64
    static let maxFrames = 16
    static let minFrames = 4

    /// Log-spaced band center frequencies (75Hz–16kHz), matching TIDE's 16 bands.
    static let bandFrequencies: [Float] = [
        75, 120, 190, 300, 475, 750, 1200, 1900,
        3000, 4750, 7500, 10000, 11500, 13000, 14500, 16000
    ]

    // MARK: - Public Entry Point

    /// Analyse audio samples and produce a SpectralImprint.
    /// - Parameters:
    ///   - samples: Mono audio buffer (Float)
    ///   - sampleRate: Sample rate of the recording
    /// - Returns: SpectralImprint with harmonic, peak, and spectral frame data
    static func analyse(samples: [Float], sampleRate: Float) -> SpectralImprint {
        guard samples.count >= fftSize else {
            return emptyImprint(sampleRate: sampleRate, duration: Float(samples.count) / sampleRate)
        }

        // Compute FFT magnitudes for the strongest window (highest RMS)
        let (bestMagnitudes, allFrameMagnitudes) = computeFFTFrames(samples: samples, sampleRate: sampleRate)

        // Detect fundamental pitch using YIN
        let fundamental = detectPitchYIN(samples: samples, sampleRate: sampleRate)

        // Extract data for each engine
        let harmonicAmps = extractHarmonics(magnitudes: bestMagnitudes, fundamental: fundamental, sampleRate: sampleRate)
        let (peakRatios, peakAmps) = extractPeaks(magnitudes: bestMagnitudes, sampleRate: sampleRate, fundamental: fundamental)
        let spectralFrames = extractBands(frameMagnitudes: allFrameMagnitudes, sampleRate: sampleRate)

        return SpectralImprint(
            fundamental: fundamental,
            harmonicAmplitudes: harmonicAmps,
            peakRatios: peakRatios,
            peakAmplitudes: peakAmps,
            spectralFrames: spectralFrames,
            sampleRate: sampleRate,
            durationSeconds: Float(samples.count) / sampleRate,
            timestamp: Date()
        )
    }

    // MARK: - FFT

    /// Compute FFT magnitudes for all frames. Returns (best frame magnitudes, all frame magnitudes).
    private static func computeFFTFrames(samples: [Float], sampleRate: Float) -> ([Float], [[Float]]) {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (Array(repeating: 0, count: fftSize / 2), [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var allMagnitudes: [[Float]] = []
        var bestMagnitudes = [Float](repeating: 0, count: fftSize / 2)
        var bestRMS: Float = 0

        var offset = 0
        while offset + fftSize <= samples.count {
            // Window the signal
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(samples[offset..<(offset + fftSize)]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // Split into even/odd for FFT
            let halfN = fftSize / 2
            var realPart = [Float](repeating: 0, count: halfN)
            var imagPart = [Float](repeating: 0, count: halfN)

            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    windowed.withUnsafeBufferPointer { winBuf in
                        winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                    // Compute magnitudes
                    var mags = [Float](repeating: 0, count: halfN)
                    vDSP_zvmags(&splitComplex, 1, &mags, 1, vDSP_Length(halfN))
                    // Square root to get amplitude (not power)
                    var count = Int32(halfN)
                    vvsqrtf(&mags, mags, &count)

                    // Normalize
                    var scale = 2.0 / Float(fftSize)
                    vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

                    // RMS of this frame
                    var rms: Float = 0
                    vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(fftSize))

                    allMagnitudes.append(mags)

                    if rms > bestRMS {
                        bestRMS = rms
                        bestMagnitudes = mags
                    }
                }
            }

            offset += hopSize
        }

        return (bestMagnitudes, allMagnitudes)
    }

    // MARK: - YIN Pitch Detection

    /// YIN fundamental frequency detection via autocorrelation.
    /// Returns detected pitch in Hz, or nil if unpitched.
    private static func detectPitchYIN(samples: [Float], sampleRate: Float) -> Float? {
        let windowSize = min(4096, samples.count)
        let halfWindow = windowSize / 2

        // Use the loudest segment
        var bestStart = 0
        var bestRMS: Float = 0
        let stride = windowSize / 2
        var offset = 0
        while offset + windowSize <= samples.count {
            var rms: Float = 0
            vDSP_rmsqv(Array(samples[offset..<(offset + windowSize)]), 1, &rms, vDSP_Length(windowSize))
            if rms > bestRMS {
                bestRMS = rms
                bestStart = offset
            }
            offset += stride
        }

        let window = Array(samples[bestStart..<min(bestStart + windowSize, samples.count)])
        guard window.count >= windowSize else { return nil }

        // Compute difference function
        var diff = [Float](repeating: 0, count: halfWindow)
        for tau in 1..<halfWindow {
            var sum: Float = 0
            for j in 0..<halfWindow {
                let d = window[j] - window[j + tau]
                sum += d * d
            }
            diff[tau] = sum
        }

        // Cumulative mean normalized difference
        var cmndf = [Float](repeating: 0, count: halfWindow)
        cmndf[0] = 1
        var runningSum: Float = 0
        for tau in 1..<halfWindow {
            runningSum += diff[tau]
            cmndf[tau] = diff[tau] / max(runningSum / Float(tau), 1e-10)
        }

        // Find first dip below threshold
        let threshold: Float = 0.15
        let minPeriod = Int(sampleRate / 2000) // max 2kHz fundamental
        let maxPeriod = Int(sampleRate / 50)    // min 50Hz fundamental

        var bestTau = -1
        for tau in max(minPeriod, 2)..<min(maxPeriod, halfWindow) {
            if cmndf[tau] < threshold {
                // Find the local minimum
                while tau + 1 < halfWindow && cmndf[tau + 1] < cmndf[tau] {
                    bestTau = tau + 1
                    break
                }
                if bestTau < 0 { bestTau = tau }
                break
            }
        }

        // Fallback: find absolute minimum if threshold wasn't crossed
        if bestTau < 0 {
            var minVal: Float = .infinity
            for tau in max(minPeriod, 2)..<min(maxPeriod, halfWindow) {
                if cmndf[tau] < minVal {
                    minVal = cmndf[tau]
                    bestTau = tau
                }
            }
            // Only accept if reasonably periodic
            if minVal > 0.4 { return nil }
        }

        guard bestTau > 0 else { return nil }

        // Parabolic interpolation for sub-sample accuracy
        let tauF: Float
        if bestTau > 0 && bestTau < halfWindow - 1 {
            let s0 = cmndf[bestTau - 1]
            let s1 = cmndf[bestTau]
            let s2 = cmndf[bestTau + 1]
            let adjustment = (s0 - s2) / (2 * (s0 - 2 * s1 + s2))
            tauF = Float(bestTau) + (adjustment.isFinite ? adjustment : 0)
        } else {
            tauF = Float(bestTau)
        }

        let pitch = sampleRate / tauF
        return (pitch > 30 && pitch < 4000) ? pitch : nil
    }

    // MARK: - Harmonic Extraction (for FLOW)

    /// Extract 64 harmonic amplitudes relative to the fundamental.
    /// Falls back to lowest significant peak if no pitch detected.
    private static func extractHarmonics(magnitudes: [Float], fundamental: Float?, sampleRate: Float) -> [Float] {
        let binWidth = sampleRate / Float(fftSize)
        let halfN = magnitudes.count

        // Use fundamental, or find lowest significant peak as fallback
        let f0: Float
        if let fund = fundamental {
            f0 = fund
        } else {
            f0 = findLowestPeak(magnitudes: magnitudes, binWidth: binWidth) ?? 100
        }

        var amplitudes = [Float](repeating: 0, count: harmonicCount)
        var maxAmp: Float = 0

        for i in 0..<harmonicCount {
            let harmonicFreq = f0 * Float(i + 1)
            let centerBin = Int(harmonicFreq / binWidth)

            guard centerBin >= 0 && centerBin < halfN else { continue }

            // Sum ±2 bins around the harmonic
            var amp: Float = 0
            for offset in -2...2 {
                let bin = centerBin + offset
                if bin >= 0 && bin < halfN {
                    amp = max(amp, magnitudes[bin])
                }
            }
            amplitudes[i] = amp
            maxAmp = max(maxAmp, amp)
        }

        // Normalize to 0–1
        if maxAmp > 0 {
            for i in 0..<harmonicCount {
                amplitudes[i] /= maxAmp
            }
        }

        return amplitudes
    }

    // MARK: - Band Extraction (for TIDE)

    /// Extract 16 log-spaced band levels from multiple FFT frames.
    /// Subsamples to 4–16 frames for TIDE pattern use.
    private static func extractBands(frameMagnitudes: [[Float]], sampleRate: Float) -> [[Float]] {
        guard !frameMagnitudes.isEmpty else {
            return [Array(repeating: 0.5, count: bandCount)]
        }

        let binWidth = sampleRate / Float(fftSize)
        let halfN = fftSize / 2

        // Compute band edges (geometric mean between adjacent center frequencies)
        var bandEdges = [Float](repeating: 0, count: bandCount + 1)
        bandEdges[0] = 50
        for i in 0..<(bandCount - 1) {
            bandEdges[i + 1] = sqrtf(bandFrequencies[i] * bandFrequencies[i + 1])
        }
        bandEdges[bandCount] = 20000

        var allBandLevels: [[Float]] = []

        for magnitudes in frameMagnitudes {
            var levels = [Float](repeating: 0, count: bandCount)

            for b in 0..<bandCount {
                let lowBin = max(1, Int(bandEdges[b] / binWidth))
                let highBin = min(halfN - 1, Int(bandEdges[b + 1] / binWidth))

                guard lowBin < highBin else { continue }

                // Use peak (max) within each band instead of average.
                // Average dilutes concentrated harmonic energy across wide
                // high-frequency bands, making imprint frames nearly flat.
                var peak: Float = 0
                for bin in lowBin...highBin {
                    peak = max(peak, magnitudes[bin])
                }
                levels[b] = peak
            }

            allBandLevels.append(levels)
        }

        // Normalize across all frames
        var globalMax: Float = 0
        for levels in allBandLevels {
            for l in levels {
                globalMax = max(globalMax, l)
            }
        }
        if globalMax > 0 {
            for i in 0..<allBandLevels.count {
                for j in 0..<bandCount {
                    allBandLevels[i][j] /= globalMax
                }
            }
        }

        // Boost contrast: square the normalized values so quiet bands
        // become much quieter while loud bands stay prominent.
        // Without this, voice spectra are too flat for audible TIDE animation.
        for i in 0..<allBandLevels.count {
            for j in 0..<bandCount {
                let v = allBandLevels[i][j]
                allBandLevels[i][j] = v * v
            }
        }

        // Subsample to 4–16 frames
        let targetCount = max(minFrames, min(maxFrames, allBandLevels.count))
        if allBandLevels.count <= targetCount {
            return allBandLevels
        }

        var subsampled: [[Float]] = []
        let step = Float(allBandLevels.count) / Float(targetCount)
        for i in 0..<targetCount {
            let idx = min(Int(Float(i) * step), allBandLevels.count - 1)
            subsampled.append(allBandLevels[idx])
        }
        return subsampled
    }

    // MARK: - Peak Extraction (for SWARM)

    /// Extract 64 strongest spectral peaks as frequency ratios + amplitudes.
    /// Sorted low→high by frequency ratio.
    private static func extractPeaks(magnitudes: [Float], sampleRate: Float, fundamental: Float?) -> ([Float], [Float]) {
        let binWidth = sampleRate / Float(fftSize)
        let halfN = magnitudes.count

        // Find local maxima
        var peaks: [(bin: Int, amplitude: Float)] = []
        for i in 2..<(halfN - 2) {
            if magnitudes[i] > magnitudes[i - 1] &&
               magnitudes[i] > magnitudes[i + 1] &&
               magnitudes[i] > magnitudes[i - 2] &&
               magnitudes[i] > magnitudes[i + 2] &&
               magnitudes[i] > 0.001 {
                peaks.append((i, magnitudes[i]))
            }
        }

        // Sort by amplitude descending, take top 64
        peaks.sort { $0.amplitude > $1.amplitude }
        let topPeaks = Array(peaks.prefix(peakCount))

        // Reference frequency for ratio calculation
        let refFreq: Float
        if let fund = fundamental {
            refFreq = fund
        } else if let lowest = topPeaks.min(by: { $0.bin < $1.bin }) {
            refFreq = Float(lowest.bin) * binWidth
        } else {
            refFreq = 100
        }

        guard refFreq > 0 else {
            return (Array(repeating: 1, count: peakCount), Array(repeating: 0, count: peakCount))
        }

        // Convert to ratios, sorted low→high
        var ratioAmpPairs: [(ratio: Float, amplitude: Float)] = topPeaks.map { peak in
            let freq = Float(peak.bin) * binWidth
            return (freq / refFreq, peak.amplitude)
        }
        ratioAmpPairs.sort { $0.ratio < $1.ratio }

        // Normalize amplitudes
        let maxAmp = ratioAmpPairs.map(\.amplitude).max() ?? 1
        let normalizedAmps = ratioAmpPairs.map { maxAmp > 0 ? $0.amplitude / maxAmp : 0 }
        let ratios = ratioAmpPairs.map(\.ratio)

        // Fill all 64 slots. Real peaks get their extracted values.
        // Remaining slots get harmonic-series positions with gentle falloff
        // so they contribute faint tonal content instead of silence.
        var finalRatios = [Float](repeating: 0, count: peakCount)
        var finalAmps = [Float](repeating: 0, count: peakCount)
        let realCount = min(ratioAmpPairs.count, peakCount)
        for i in 0..<realCount {
            finalRatios[i] = ratios[i]
            finalAmps[i] = normalizedAmps[i]
        }
        // Pad remaining with harmonic series + natural amplitude falloff
        for i in realCount..<peakCount {
            finalRatios[i] = Float(i + 1)
            finalAmps[i] = 0.15 / Float(i + 1)
        }

        return (finalRatios, finalAmps)
    }

    // MARK: - Helpers

    /// Find the lowest significant spectral peak.
    private static func findLowestPeak(magnitudes: [Float], binWidth: Float) -> Float? {
        let halfN = magnitudes.count
        var maxMag: Float = 0
        vDSP_maxv(magnitudes, 1, &maxMag, vDSP_Length(halfN))
        let threshold = maxMag * 0.1

        for i in 2..<halfN {
            if magnitudes[i] > threshold &&
               magnitudes[i] > magnitudes[i - 1] &&
               magnitudes[i] > magnitudes[i + 1] {
                return Float(i) * binWidth
            }
        }
        return nil
    }

    /// Return an empty imprint (for recordings too short to analyse).
    private static func emptyImprint(sampleRate: Float, duration: Float) -> SpectralImprint {
        SpectralImprint(
            fundamental: nil,
            harmonicAmplitudes: Array(repeating: 0, count: harmonicCount),
            peakRatios: Array(repeating: 0, count: peakCount),
            peakAmplitudes: Array(repeating: 0, count: peakCount),
            spectralFrames: [Array(repeating: 0.5, count: bandCount)],
            sampleRate: sampleRate,
            durationSeconds: duration,
            timestamp: Date()
        )
    }
}
