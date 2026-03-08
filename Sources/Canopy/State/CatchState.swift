import AVFoundation
import Combine
import Foundation
import os

/// Manages the Catch UI lifecycle: buffer snapshots, preview playback, and saving.
class CatchState: ObservableObject {
    private static let logger = Logger(subsystem: "com.canopy", category: "CatchState")

    /// Whether the catch buffer is actively recording.
    @Published var isBufferActive: Bool = true

    /// Whether the catch popover is showing.
    @Published var showPopover: Bool = false

    /// Selected duration to capture (seconds).
    @Published var selectedDuration: Double = 30.0

    /// Snapshot taken when popup opens (design doc: snapshot immediately on popup open).
    @Published var snapshot: CatchSnapshot?

    /// Downsampled waveform for UI preview (128 points).
    @Published var waveformPreview: [Float] = []

    /// Whether preview playback is active.
    @Published var isPreviewing: Bool = false

    /// Whether a save/analysis operation is in progress.
    @Published var isSaving: Bool = false

    /// Whether the buffer is empty (nothing to catch).
    @Published var isEmpty: Bool = true

    /// Whether the captured audio is very quiet.
    @Published var isVeryQuiet: Bool = false

    /// Preview player.
    private var previewPlayer: AVAudioPlayer?

    /// Waveform resolution for the UI.
    private static let waveformResolution = 128

    /// RMS threshold in linear amplitude for "very quiet" warning.
    private static let quietThreshold: Float = 0.001

    // MARK: - Catch Lifecycle

    /// Open the catch popup — snapshots the buffer immediately.
    func openCatch() {
        // Snapshot the full buffer immediately (design doc edge case)
        snapshot = AudioEngine.shared.catchSnapshot(lastSeconds: 90)

        if let snap = snapshot, !snap.samples.isEmpty {
            isEmpty = false
            isVeryQuiet = computeRMS(snap.samples) < Self.quietThreshold
            generateWaveformPreview()
        } else {
            isEmpty = true
            isVeryQuiet = false
            waveformPreview = []
        }

        showPopover = true
    }

    /// Save the captured audio as a Wild Harvest.
    func catchAndSave(projectState: ProjectState) {
        guard let fullSnapshot = snapshot, !fullSnapshot.samples.isEmpty else { return }
        guard let projectURL = projectState.currentFilePath else {
            Self.logger.error("No project file path — cannot save catch")
            return
        }

        isSaving = true

        // Extract the selected duration from the full snapshot
        let captureSnapshot = extractDuration(from: fullSnapshot, seconds: selectedDuration)

        let fileName = AudioFileService.generateCatchFilename()
        let displayName = AudioFileService.generateCatchDisplayName()

        // Save on a background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let catchesDir = try AudioFileService.catchesDirectory(for: projectURL)
                let fileURL = catchesDir.appendingPathComponent(fileName)

                try AudioFileService.writeWAV(
                    samples: captureSnapshot.samples,
                    sampleRate: captureSnapshot.sampleRate,
                    channelCount: captureSnapshot.channelCount,
                    to: fileURL
                )

                let loop = HarvestedLoop(
                    name: displayName,
                    harvestSettings: HarvestSettings(mode: .wild),
                    durationSeconds: captureSnapshot.durationSeconds,
                    sampleRate: captureSnapshot.sampleRate,
                    channelCount: captureSnapshot.channelCount,
                    fileName: fileName,
                    isAnalysing: true
                )

                DispatchQueue.main.async {
                    projectState.project.catches.append(loop)
                    projectState.markDirty()
                    self?.isSaving = false
                    self?.dismiss()

                    Self.logger.info("Wild harvest saved: \(fileName) (\(captureSnapshot.durationSeconds)s)")

                    // Kick off async analysis
                    let loopID = loop.id
                    PitchAnalysisService.analyse(
                        samples: captureSnapshot.samples,
                        sampleRate: captureSnapshot.sampleRate,
                        channelCount: captureSnapshot.channelCount,
                        projectBPM: projectState.project.bpm
                    ) { metadata in
                        DispatchQueue.main.async {
                            if let index = projectState.project.catches.firstIndex(where: { $0.id == loopID }) {
                                projectState.project.catches[index].metadata = metadata
                                projectState.project.catches[index].isAnalysing = false
                                projectState.markDirty()
                                Self.logger.info("Analysis complete for \(fileName)")
                            }
                        }
                    }
                }
            } catch {
                Self.logger.error("Failed to save catch: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.isSaving = false
                }
            }
        }
    }

    /// Start or stop preview playback of the captured audio.
    func togglePreview() {
        if isPreviewing {
            stopPreview()
        } else {
            startPreview()
        }
    }

    /// Cancel and dismiss the popup.
    func dismiss() {
        stopPreview()
        snapshot = nil
        waveformPreview = []
        showPopover = false
        isEmpty = true
        isVeryQuiet = false
    }

    /// Regenerate waveform when duration selection changes.
    func regenerateWaveform() {
        generateWaveformPreview()
    }

    // MARK: - Preview Playback

    private func startPreview() {
        guard let fullSnapshot = snapshot else { return }
        let captureSnapshot = extractDuration(from: fullSnapshot, seconds: selectedDuration)

        // Write to a temp file for AVAudioPlayer
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("catch-preview-\(UUID().uuidString).wav")

        do {
            try AudioFileService.writeWAV(
                samples: captureSnapshot.samples,
                sampleRate: captureSnapshot.sampleRate,
                channelCount: captureSnapshot.channelCount,
                to: tempURL
            )

            previewPlayer = try AVAudioPlayer(contentsOf: tempURL)
            previewPlayer?.play()
            isPreviewing = true

            // Auto-stop when playback finishes
            let duration = captureSnapshot.durationSeconds
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { [weak self] in
                if self?.isPreviewing == true {
                    self?.isPreviewing = false
                }
            }
        } catch {
            Self.logger.error("Preview playback failed: \(error.localizedDescription)")
        }
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPreviewing = false
    }

    // MARK: - Helpers

    /// Extract a sub-snapshot of the desired duration from the end of the full snapshot.
    private func extractDuration(from snapshot: CatchSnapshot, seconds: Double) -> CatchSnapshot {
        let requestedFrames = Int(seconds * snapshot.sampleRate)
        let totalFrames = snapshot.samples.count / snapshot.channelCount
        let framesToUse = min(requestedFrames, totalFrames)
        let samplesToUse = framesToUse * snapshot.channelCount
        let startIndex = snapshot.samples.count - samplesToUse

        let extracted = Array(snapshot.samples[startIndex...])

        return CatchSnapshot(
            samples: extracted,
            sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount,
            durationSeconds: Double(framesToUse) / snapshot.sampleRate
        )
    }

    /// Generate a downsampled waveform preview for the selected duration.
    private func generateWaveformPreview() {
        guard let fullSnapshot = snapshot else {
            waveformPreview = []
            return
        }

        let captureSnapshot = extractDuration(from: fullSnapshot, seconds: selectedDuration)
        let samples = captureSnapshot.samples
        let frameCount = samples.count / captureSnapshot.channelCount
        guard frameCount > 0 else {
            waveformPreview = []
            return
        }

        let resolution = Self.waveformResolution
        let chunkSize = max(1, frameCount / resolution)
        var preview = [Float](repeating: 0, count: min(resolution, frameCount))

        for i in 0..<preview.count {
            let startFrame = i * chunkSize
            let endFrame = min(startFrame + chunkSize, frameCount)
            var maxAbs: Float = 0
            for frame in startFrame..<endFrame {
                // Use left channel for waveform display
                let idx = frame * captureSnapshot.channelCount
                if idx < samples.count {
                    maxAbs = max(maxAbs, abs(samples[idx]))
                }
            }
            preview[i] = maxAbs
        }

        waveformPreview = preview
    }

    /// Compute RMS amplitude of interleaved samples.
    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquared: Float = 0
        for sample in samples {
            sumSquared += sample * sample
        }
        return (sumSquared / Float(samples.count)).squareRoot()
    }
}
