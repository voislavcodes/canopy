import AVFoundation
import os

/// Transient snapshot of captured audio from the rolling buffer.
/// Not persisted — used to transfer audio between capture and save.
struct CatchSnapshot {
    let samples: [Float]       // interleaved stereo
    let sampleRate: Double
    let channelCount: Int
    let durationSeconds: Double
}

/// Rolling circular audio buffer that continuously captures the main output.
/// Installed as a tap on the master bus AVAudioUnit output.
///
/// Thread safety: `NSLock` protects buffer access between the tap callback
/// (CoreAudio utility thread) and snapshot extraction (main thread).
/// The tap callback is NOT the render thread — `installTap` runs on a
/// separate CoreAudio utility thread where locking is acceptable.
final class CatchBuffer {
    private static let logger = Logger(subsystem: "com.canopy", category: "CatchBuffer")

    /// Maximum buffer duration in seconds.
    let maxDuration: Double

    /// Project sample rate.
    let sampleRate: Double

    /// Number of channels (always 2 for stereo).
    let channelCount: Int = 2

    /// Total capacity in float samples (frames × channels).
    private let capacity: Int

    /// Raw circular buffer — interleaved stereo [L0, R0, L1, R1, ...].
    private let buffer: UnsafeMutablePointer<Float>

    /// Current write head index into the float array.
    private var writePosition: Int = 0

    /// Monotonic counter — total interleaved samples written since creation.
    private(set) var totalSamplesWritten: Int64 = 0

    /// Lock for thread-safe extraction vs. writing.
    private let lock = NSLock()

    /// Whether a tap is currently installed.
    private(set) var isAttached: Bool = false

    init(sampleRate: Double, maxDuration: Double = 90.0) {
        self.sampleRate = sampleRate
        self.maxDuration = maxDuration
        self.capacity = Int(sampleRate * maxDuration) * channelCount
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
        Self.logger.info("CatchBuffer allocated: \(self.capacity) floats (\(maxDuration)s at \(sampleRate) Hz)")
    }

    deinit {
        buffer.deallocate()
    }

    // MARK: - Tap Management

    /// Install as a tap on the given audio node's output bus.
    func install(on node: AVAudioNode) {
        guard !isAttached else { return }
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount >= 1 else {
            Self.logger.error("Cannot install tap — node has 0 channels")
            return
        }

        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcmBuffer, _ in
            self?.writeTapBuffer(pcmBuffer)
        }
        isAttached = true
        Self.logger.info("Catch tap installed on node (format: \(format.channelCount)ch \(format.sampleRate) Hz)")
    }

    /// Remove the tap from the given node.
    func remove(from node: AVAudioNode) {
        guard isAttached else { return }
        node.removeTap(onBus: 0)
        isAttached = false
        Self.logger.info("Catch tap removed")
    }

    // MARK: - Snapshot

    /// Capture the last N seconds from the buffer as a linear snapshot.
    /// Returns nil if insufficient audio has been recorded.
    func snapshot(lastSeconds: Double) -> CatchSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        let requestedFrames = Int(min(lastSeconds, maxDuration) * sampleRate)
        let availableFrames = Int(min(Int64(requestedFrames), totalSamplesWritten / Int64(channelCount)))
        guard availableFrames > 0 else { return nil }

        let sampleCount = availableFrames * channelCount
        var output = [Float](repeating: 0, count: sampleCount)

        // Calculate start position in the circular buffer (in interleaved samples)
        let endPos = writePosition
        var startPos = endPos - sampleCount
        if startPos < 0 { startPos += capacity }

        if startPos < endPos {
            // Contiguous region — no wrap
            for i in 0..<sampleCount {
                output[i] = buffer[startPos + i]
            }
        } else {
            // Wrapped — copy tail then head
            let tailCount = capacity - startPos
            for i in 0..<tailCount {
                output[i] = buffer[startPos + i]
            }
            let headCount = sampleCount - tailCount
            for i in 0..<headCount {
                output[tailCount + i] = buffer[i]
            }
        }

        return CatchSnapshot(
            samples: output,
            sampleRate: sampleRate,
            channelCount: channelCount,
            durationSeconds: Double(availableFrames) / sampleRate
        )
    }

    // MARK: - Internal

    /// Write incoming tap buffer data into the circular buffer.
    private func writeTapBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else { return }

        let srcChannels = Int(pcmBuffer.format.channelCount)

        lock.lock()
        defer { lock.unlock() }

        for frame in 0..<frameCount {
            // Left channel
            buffer[writePosition] = channelData[0][frame]
            writePosition += 1

            // Right channel (duplicate mono if needed)
            if srcChannels >= 2 {
                buffer[writePosition] = channelData[1][frame]
            } else {
                buffer[writePosition] = channelData[0][frame]
            }
            writePosition += 1

            // Wrap around
            if writePosition >= capacity {
                writePosition = 0
            }
        }

        totalSamplesWritten += Int64(frameCount * channelCount)
    }
}
