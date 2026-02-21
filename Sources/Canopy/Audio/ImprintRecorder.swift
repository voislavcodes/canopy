import AVFoundation
import Combine
import os

/// Recording lifecycle state for the IMPRINT feature.
enum RecordingState: Equatable {
    case idle
    case recording(progress: Float)
    case analysing
    case imprinted(SpectralImprint)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording(let a), .recording(let b)): return a == b
        case (.analysing, .analysing): return true
        case (.imprinted(let a), .imprinted(let b)): return a == b
        default: return false
        }
    }
}

/// Manages microphone recording for spectral imprinting.
/// Uses a SEPARATE AVAudioEngine from the main playback engine — mic capture
/// doesn't interfere with synthesis output.
///
/// NOT on the audio render thread. Uses install-tap for input capture
/// and dispatches analysis to a background queue after recording stops.
final class ImprintRecorder: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var waveformSamples: [Float] = []

    private static let logger = Logger(subsystem: "com.canopy", category: "ImprintRecorder")

    private var inputEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private var recordingSampleRate: Float = 48000

    /// Maximum recording duration in seconds.
    static let maxDuration: Float = 4.0
    /// Maximum samples at 48kHz.
    private static let maxSamples = Int(maxDuration * 48000)
    /// Minimum samples for valid analysis.
    private static let minSamples = 1024
    /// Waveform preview resolution (how many points for the UI).
    private static let waveformResolution = 128

    // MARK: - Mic Permission

    /// Check current microphone authorization status.
    static var micPermissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request microphone access if not yet determined.
    static func requestMicPermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    // MARK: - Recording

    /// Begin capturing audio from the default input device.
    func startRecording() {
        guard case .idle = state else { return }

        guard ImprintRecorder.micPermissionGranted else {
            ImprintRecorder.requestMicPermission { [weak self] granted in
                if granted { self?.startRecording() }
            }
            return
        }

        sampleBuffer.removeAll(keepingCapacity: true)
        waveformSamples.removeAll(keepingCapacity: true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        recordingSampleRate = Float(format.sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            let channelData = buffer.floatChannelData?[0]
            let frameCount = Int(buffer.frameLength)
            guard let data = channelData, frameCount > 0 else { return }

            // Convert to mono if needed (take first channel)
            var monoSamples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                monoSamples[i] = data[i]
            }

            DispatchQueue.main.async {
                let remaining = Self.maxSamples - self.sampleBuffer.count
                let toAppend = min(remaining, monoSamples.count)
                guard toAppend > 0 else {
                    self.stopRecording()
                    return
                }

                self.sampleBuffer.append(contentsOf: monoSamples.prefix(toAppend))

                // Update progress
                let progress = Float(self.sampleBuffer.count) / Float(Self.maxSamples)
                self.state = .recording(progress: min(progress, 1.0))

                // Update waveform preview (downsample)
                self.updateWaveform()

                // Auto-stop at max duration
                if self.sampleBuffer.count >= Self.maxSamples {
                    self.stopRecording()
                }
            }
        }

        do {
            try engine.start()
            inputEngine = engine
            state = .recording(progress: 0)
            Self.logger.info("Imprint recording started at \(self.recordingSampleRate) Hz")
        } catch {
            Self.logger.error("Failed to start input engine: \(error.localizedDescription)")
            inputEngine = nil
        }
    }

    /// Stop recording and begin spectral analysis.
    func stopRecording() {
        guard case .recording = state else { return }

        inputEngine?.inputNode.removeTap(onBus: 0)
        inputEngine?.stop()
        inputEngine = nil

        let samples = sampleBuffer
        let sr = recordingSampleRate

        guard samples.count >= Self.minSamples else {
            Self.logger.info("Recording too short (\(samples.count) samples), discarding")
            state = .idle
            return
        }

        state = .analysing
        Self.logger.info("Analysing \(samples.count) samples...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let imprint = SpectralAnalyser.analyse(samples: samples, sampleRate: sr)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.state = .imprinted(imprint)
                Self.logger.info("Imprint complete — fundamental: \(imprint.fundamental ?? 0) Hz")
            }
        }
    }

    /// Clear imprint and return to idle.
    func clear() {
        inputEngine?.inputNode.removeTap(onBus: 0)
        inputEngine?.stop()
        inputEngine = nil
        sampleBuffer.removeAll()
        waveformSamples.removeAll()
        state = .idle
    }

    // MARK: - Waveform Preview

    private func updateWaveform() {
        let count = sampleBuffer.count
        guard count > 0 else { return }

        let resolution = Self.waveformResolution
        let chunkSize = max(1, count / resolution)
        var preview = [Float](repeating: 0, count: min(resolution, count))

        for i in 0..<preview.count {
            let start = i * chunkSize
            let end = min(start + chunkSize, count)
            var maxAbs: Float = 0
            for j in start..<end {
                maxAbs = max(maxAbs, abs(sampleBuffer[j]))
            }
            preview[i] = maxAbs
        }

        waveformSamples = preview
    }
}
