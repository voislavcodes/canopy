import Accelerate
import Foundation
import os

/// Asynchronous audio analysis service for Catch.
/// Detects BPM, key, chords, and density from raw audio.
/// Runs on a background queue — never blocks the main thread.
enum PitchAnalysisService {
    private static let logger = Logger(subsystem: "com.canopy", category: "PitchAnalysis")

    /// FFT size for spectral analysis.
    private static let fftSize = 4096
    /// Hop size between FFT frames.
    private static let hopSize = 1024

    // MARK: - Public Entry Point

    /// Analyse captured audio and produce estimated LoopMetadata.
    /// Dispatches to `.userInitiated` queue. Calls back on main thread.
    static func analyse(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        projectBPM: Double,
        completion: @escaping (LoopMetadata) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let mono = mixToMono(samples: samples, channelCount: channelCount)
            let result = analyseSync(mono: mono, sampleRate: sampleRate, projectBPM: projectBPM)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    // MARK: - Synchronous Analysis

    private static func analyseSync(mono: [Float], sampleRate: Double, projectBPM: Double) -> LoopMetadata {
        let sr = Float(sampleRate)

        // Step 1: Onset detection
        let onsets = detectOnsets(mono: mono, sampleRate: sr)

        // Step 2: BPM detection
        let (bpm, bpmConf) = detectBPM(onsets: onsets, sampleRate: sr, projectBPM: projectBPM)
        let effectiveBPM = bpmConf > 0.3 ? bpm : projectBPM

        // Step 3: Beat grid
        let beatDuration = 60.0 / effectiveBPM // seconds per beat
        let totalDuration = Double(mono.count) / sampleRate
        let beatCount = max(1, Int(totalDuration / beatDuration))

        // Step 4: Per-beat pitch detection
        var allPitchClasses = [Float](repeating: 0, count: 12)
        var densityPerBeat = [Double]()
        var spectralCentroids = [Double]()

        for beat in 0..<beatCount {
            let startFrame = Int(Double(beat) * beatDuration * sampleRate)
            let endFrame = min(Int(Double(beat + 1) * beatDuration * sampleRate), mono.count)
            let frameCount = endFrame - startFrame
            guard frameCount > 0 else {
                densityPerBeat.append(0)
                spectralCentroids.append(0)
                continue
            }

            let window = Array(mono[startFrame..<endFrame])

            // Pitch detection for this beat
            let pitches = detectPitches(window: window, sampleRate: sr)
            for (pitch, amplitude) in pitches {
                let pitchClass = pitch % 12
                allPitchClasses[pitchClass] += Float(amplitude)
            }

            // Density: count onsets in this beat + RMS
            let beatStart = Double(startFrame) / Double(sampleRate)
            let beatEnd = Double(endFrame) / Double(sampleRate)
            let onsetCount = onsets.filter { $0 >= beatStart && $0 < beatEnd }.count
            var rms: Float = 0
            vDSP_rmsqv(window, 1, &rms, vDSP_Length(frameCount))
            densityPerBeat.append(Double(onsetCount) * 0.3 + Double(rms) * 0.7)

            // Spectral centroid
            let centroid = computeSpectralCentroid(window: window, sampleRate: sr)
            spectralCentroids.append(centroid)
        }

        // Normalize density
        let maxDensity = densityPerBeat.max() ?? 1
        if maxDensity > 0 {
            densityPerBeat = densityPerBeat.map { $0 / maxDensity }
        }

        // Step 5: Key detection
        let (detectedKey, keyConf) = detectKey(histogram: allPitchClasses)

        // Step 6: Chord progression (per beat)
        var chordProgression = [String]()
        for beat in 0..<beatCount {
            let startFrame = Int(Double(beat) * beatDuration * sampleRate)
            let endFrame = min(Int(Double(beat + 1) * beatDuration * sampleRate), mono.count)
            guard endFrame - startFrame > 0 else {
                chordProgression.append("—")
                continue
            }
            let window = Array(mono[startFrame..<endFrame])
            let pitches = detectPitches(window: window, sampleRate: sr)
            if let chord = detectChord(pitches: pitches) {
                chordProgression.append(chord)
            } else {
                chordProgression.append("—")
            }
        }

        // Merge adjacent identical chords
        chordProgression = mergeAdjacentChords(chordProgression)

        // Average spectral centroid
        let avgCentroid = spectralCentroids.isEmpty ? 0 : spectralCentroids.reduce(0, +) / Double(spectralCentroids.count)

        logger.info("Analysis: BPM=\(effectiveBPM) (conf=\(bpmConf)), key=\(detectedKey?.displayName ?? "?") (conf=\(keyConf)), \(beatCount) beats")

        return LoopMetadata(
            detectedBPM: effectiveBPM,
            bpmConfidence: Double(bpmConf),
            detectedKey: keyConf > 0.15 ? detectedKey : nil,
            keyConfidence: Double(keyConf),
            chordProgression: chordProgression,
            densityPerBeat: densityPerBeat,
            spectralCentroid: avgCentroid,
            lengthInBeats: beatCount
        )
    }

    // MARK: - Mix to Mono

    private static func mixToMono(samples: [Float], channelCount: Int) -> [Float] {
        guard channelCount > 1 else { return samples }
        let frameCount = samples.count / channelCount
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += samples[frame * channelCount + ch]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }

    // MARK: - Onset Detection

    /// Detect onset times via spectral flux.
    private static func detectOnsets(mono: [Float], sampleRate: Float) -> [Double] {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftSize / 2
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var prevMagnitudes = [Float](repeating: 0, count: halfN)
        var fluxValues = [Double]()
        var frameOffsets = [Int]()

        var offset = 0
        while offset + fftSize <= mono.count {
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(mono[offset..<(offset + fftSize)]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

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

                    var mags = [Float](repeating: 0, count: halfN)
                    vDSP_zvmags(&splitComplex, 1, &mags, 1, vDSP_Length(halfN))
                    var count = Int32(halfN)
                    vvsqrtf(&mags, mags, &count)

                    // Spectral flux: sum of positive differences
                    var flux: Double = 0
                    for i in 0..<halfN {
                        let diff = mags[i] - prevMagnitudes[i]
                        if diff > 0 { flux += Double(diff) }
                    }
                    fluxValues.append(flux)
                    frameOffsets.append(offset)
                    prevMagnitudes = mags
                }
            }

            offset += hopSize
        }

        // Adaptive thresholding: moving median + offset
        let medianWindow = 7
        var onsets = [Double]()
        for i in 0..<fluxValues.count {
            let start = max(0, i - medianWindow / 2)
            let end = min(fluxValues.count, i + medianWindow / 2 + 1)
            var neighborhood = Array(fluxValues[start..<end])
            neighborhood.sort()
            let median = neighborhood[neighborhood.count / 2]
            let threshold = median * 1.5 + 0.01

            if fluxValues[i] > threshold {
                // Check it's a local peak
                let isPeak = (i == 0 || fluxValues[i] > fluxValues[i - 1]) &&
                             (i == fluxValues.count - 1 || fluxValues[i] >= fluxValues[i + 1])
                if isPeak {
                    let time = Double(frameOffsets[i]) / Double(sampleRate)
                    onsets.append(time)
                }
            }
        }

        return onsets
    }

    // MARK: - BPM Detection

    /// Detect tempo from onset pattern via autocorrelation.
    private static func detectBPM(onsets: [Double], sampleRate: Float, projectBPM: Double) -> (Double, Float) {
        guard onsets.count >= 4 else { return (projectBPM, 0) }

        // Compute inter-onset intervals
        var iois = [Double]()
        for i in 1..<onsets.count {
            let ioi = onsets[i] - onsets[i - 1]
            if ioi > 0.1 && ioi < 2.0 { // between ~30 and 600 BPM
                iois.append(ioi)
            }
        }
        guard !iois.isEmpty else { return (projectBPM, 0) }

        // Histogram of IOIs in BPM space
        var bpmHistogram = [Double: Double]()
        for ioi in iois {
            let bpm = 60.0 / ioi
            // Also consider half and double time
            for multiplier in [0.5, 1.0, 2.0] {
                let candidate = bpm * multiplier
                if candidate >= 60 && candidate <= 200 {
                    let snapped = (candidate * 2).rounded() / 2 // snap to 0.5 BPM
                    bpmHistogram[snapped, default: 0] += 1.0 / multiplier
                }
            }
        }

        guard let (bestBPM, bestCount) = bpmHistogram.max(by: { $0.value < $1.value }) else {
            return (projectBPM, 0)
        }

        let totalVotes = bpmHistogram.values.reduce(0, +)
        let confidence = Float(bestCount / totalVotes)

        return (bestBPM, confidence)
    }

    // MARK: - Pitch Detection

    /// Detect pitches in a time window using FFT + harmonic product spectrum.
    private static func detectPitches(window: [Float], sampleRate: Float) -> [(pitch: Int, amplitude: Double)] {
        let n = min(fftSize, window.count)
        guard n >= 1024 else { return [] }

        let log2n = vDSP_Length(log2(Float(n)))
        let actualSize = 1 << Int(log2n) // Round down to power of 2
        guard actualSize >= 1024 else { return [] }

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = actualSize / 2

        // Window and FFT
        var hannWindow = [Float](repeating: 0, count: actualSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(actualSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: actualSize)
        let input = Array(window.prefix(actualSize))
        vDSP_vmul(input, 1, hannWindow, 1, &windowed, 1, vDSP_Length(actualSize))

        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { winBuf in
                    winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
                var count = Int32(halfN)
                vvsqrtf(&magnitudes, magnitudes, &count)
            }
        }

        // Find peaks above threshold
        var maxMag: Float = 0
        vDSP_maxv(magnitudes, 1, &maxMag, vDSP_Length(halfN))
        let threshold = maxMag * 0.05
        let binWidth = sampleRate / Float(actualSize)

        var results = [(pitch: Int, amplitude: Double)]()

        for i in 2..<(halfN - 2) {
            if magnitudes[i] > threshold &&
               magnitudes[i] > magnitudes[i - 1] &&
               magnitudes[i] > magnitudes[i + 1] {
                let freq = Float(i) * binWidth
                guard freq >= 50 && freq <= 4000 else { continue }

                // Convert to MIDI note
                let midiNote = 69 + 12 * log2(freq / 440.0)
                let roundedNote = Int(midiNote.rounded())
                guard roundedNote >= 0 && roundedNote <= 127 else { continue }

                results.append((roundedNote, Double(magnitudes[i] / maxMag)))
            }
        }

        // Take top 8 strongest
        results.sort { $0.amplitude > $1.amplitude }
        return Array(results.prefix(8))
    }

    // MARK: - Key Detection (Krumhansl-Schmuckler)

    /// Detect key and scale from a pitch class histogram.
    private static func detectKey(histogram: [Float]) -> (MusicalKey?, Float) {
        // Normalize histogram
        var total: Float = 0
        vDSP_sve(histogram, 1, &total, vDSP_Length(12))
        guard total > 0 else { return (nil, 0) }

        var normalized = [Float](repeating: 0, count: 12)
        var divisor = total
        vDSP_vsdiv(histogram, 1, &divisor, &normalized, 1, vDSP_Length(12))

        // Krumhansl-Kessler profiles
        let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

        var bestKey: MusicalKey?
        var bestCorr: Float = -1
        var secondBestCorr: Float = -1

        let pitchClasses: [PitchClass] = [.C, .Cs, .D, .Ds, .E, .F, .Fs, .G, .Gs, .A, .As, .B]

        for rotation in 0..<12 {
            // Rotate histogram to test each root
            var rotated = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                rotated[i] = normalized[(i + rotation) % 12]
            }

            // Correlate with major profile
            let majorCorr = pearsonCorrelation(rotated, majorProfile)
            if majorCorr > bestCorr {
                secondBestCorr = bestCorr
                bestCorr = majorCorr
                bestKey = MusicalKey(root: pitchClasses[rotation], mode: .major)
            } else if majorCorr > secondBestCorr {
                secondBestCorr = majorCorr
            }

            // Correlate with minor profile
            let minorCorr = pearsonCorrelation(rotated, minorProfile)
            if minorCorr > bestCorr {
                secondBestCorr = bestCorr
                bestCorr = minorCorr
                bestKey = MusicalKey(root: pitchClasses[rotation], mode: .minor)
            } else if minorCorr > secondBestCorr {
                secondBestCorr = minorCorr
            }
        }

        // Confidence: how much better the best key is than the second best
        let confidence: Float
        if bestCorr > 0 {
            confidence = (bestCorr - secondBestCorr) / bestCorr
        } else {
            confidence = 0
        }

        return (bestKey, confidence)
    }

    /// Pearson correlation coefficient between two arrays.
    private static func pearsonCorrelation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        var sumA: Float = 0, sumB: Float = 0
        var sumAB: Float = 0, sumA2: Float = 0, sumB2: Float = 0

        for i in 0..<a.count {
            sumA += a[i]
            sumB += b[i]
            sumAB += a[i] * b[i]
            sumA2 += a[i] * a[i]
            sumB2 += b[i] * b[i]
        }

        let numerator = n * sumAB - sumA * sumB
        let denominator = ((n * sumA2 - sumA * sumA) * (n * sumB2 - sumB * sumB)).squareRoot()
        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    // MARK: - Chord Detection

    /// Detect chord from a set of pitches using template matching.
    private static func detectChord(pitches: [(pitch: Int, amplitude: Double)]) -> String? {
        guard pitches.count >= 2 else { return nil }

        // Build weighted pitch class set
        var pitchClassWeights = [Float](repeating: 0, count: 12)
        for (pitch, amplitude) in pitches {
            let pc = pitch % 12
            pitchClassWeights[pc] += Float(amplitude)
        }

        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

        // Chord templates: (intervals from root, quality name)
        let templates: [(intervals: [Int], quality: String)] = [
            ([0, 4, 7], ""),        // major
            ([0, 3, 7], "m"),       // minor
            ([0, 4, 7, 11], "maj7"),
            ([0, 3, 7, 10], "m7"),
            ([0, 4, 7, 10], "7"),   // dominant 7
            ([0, 3, 6], "dim"),
            ([0, 4, 8], "aug"),
            ([0, 2, 7], "sus2"),
            ([0, 5, 7], "sus4"),
        ]

        var bestChord: String?
        var bestScore: Float = 0

        for root in 0..<12 {
            for template in templates {
                var score: Float = 0
                for interval in template.intervals {
                    let pc = (root + interval) % 12
                    score += pitchClassWeights[pc]
                }
                // Penalize for notes NOT in the template
                for pc in 0..<12 {
                    let inTemplate = template.intervals.contains { ($0 + root) % 12 == pc }
                    if !inTemplate {
                        score -= pitchClassWeights[pc] * 0.3
                    }
                }

                if score > bestScore {
                    bestScore = score
                    bestChord = "\(noteNames[root])\(template.quality)"
                }
            }
        }

        // Only return if score is meaningful
        return bestScore > 0.1 ? bestChord : nil
    }

    // MARK: - Spectral Centroid

    /// Compute the spectral centroid (brightness) of a window.
    private static func computeSpectralCentroid(window: [Float], sampleRate: Float) -> Double {
        let n = min(2048, window.count)
        guard n >= 512 else { return 0 }

        let log2n = vDSP_Length(log2(Float(n)))
        let actualSize = 1 << Int(log2n)
        guard actualSize >= 512 else { return 0 }
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0 }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = actualSize / 2
        var hannWindow = [Float](repeating: 0, count: actualSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(actualSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: actualSize)
        let input = Array(window.prefix(actualSize))
        vDSP_vmul(input, 1, hannWindow, 1, &windowed, 1, vDSP_Length(actualSize))

        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        var weightedSum: Double = 0
        var totalMag: Double = 0

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { winBuf in
                    winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                var magnitudes = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                let binWidth = Double(sampleRate) / Double(actualSize)
                for i in 1..<halfN {
                    let mag = Double(magnitudes[i])
                    let freq = Double(i) * binWidth
                    weightedSum += freq * mag
                    totalMag += mag
                }
            }
        }

        return totalMag > 0 ? weightedSum / totalMag : 0
    }

    // MARK: - Helpers

    /// Merge adjacent identical chords into a single entry.
    private static func mergeAdjacentChords(_ chords: [String]) -> [String] {
        guard !chords.isEmpty else { return [] }
        var merged = [String]()
        var prev = chords[0]
        for i in 1..<chords.count {
            if chords[i] != prev {
                merged.append(prev)
                prev = chords[i]
            }
        }
        merged.append(prev)
        return merged
    }
}
