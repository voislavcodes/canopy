import AVFoundation
import Foundation
import os

/// Stateless service for writing and managing audio files.
enum AudioFileService {
    private static let logger = Logger(subsystem: "com.canopy", category: "AudioFileService")

    /// Write interleaved stereo float samples to a WAV file.
    /// Converts from interleaved to deinterleaved format for AVAudioFile.
    static func writeWAV(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        to url: URL
    ) throws {
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            throw AudioFileError.emptySamples
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )!

        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = pcmBuffer.floatChannelData else {
            throw AudioFileError.bufferCreationFailed
        }

        // Deinterleave: [L0, R0, L1, R1, ...] → separate L and R arrays
        for frame in 0..<frameCount {
            for ch in 0..<channelCount {
                channelData[ch][frame] = samples[frame * channelCount + ch]
            }
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        try audioFile.write(from: pcmBuffer)
        logger.info("Wrote WAV: \(url.lastPathComponent) (\(frameCount) frames, \(channelCount)ch)")
    }

    /// Returns (and creates if needed) the Catches/ directory for a project.
    static func catchesDirectory(for projectURL: URL) throws -> URL {
        let projectDir = projectURL.deletingLastPathComponent()
        let catchesDir = projectDir.appendingPathComponent("Catches", isDirectory: true)

        if !FileManager.default.fileExists(atPath: catchesDir.path) {
            try FileManager.default.createDirectory(at: catchesDir, withIntermediateDirectories: true)
            logger.info("Created Catches directory at \(catchesDir.path)")
        }

        return catchesDir
    }

    /// Generate a unique filename for a wild harvest.
    static func generateCatchFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "wild-\(timestamp).wav"
    }

    /// Generate a display name for a wild harvest based on time of day.
    static func generateCatchDisplayName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: Date())
        return "Wild — \(time)"
    }

    enum AudioFileError: Error, LocalizedError {
        case emptySamples
        case bufferCreationFailed

        var errorDescription: String? {
            switch self {
            case .emptySamples: return "No audio samples to write"
            case .bufferCreationFailed: return "Failed to create audio buffer"
            }
        }
    }
}
