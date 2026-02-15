import Foundation

/// Commands sent from the main thread to the audio thread.
enum AudioCommand {
    case noteOn(pitch: Int, velocity: Double)
    case noteOff(pitch: Int)
    case allNotesOff
    case setPatch(waveform: Int, detune: Double, attack: Double, decay: Double, sustain: Double, release: Double, volume: Double)
    // waveform: 0=sine, 1=triangle, 2=sawtooth, 3=square, 4=noise

    // Sequencer control
    case sequencerStart(bpm: Double)
    case sequencerStop
    case sequencerSetBPM(Double)
    case sequencerLoad(events: [SequencerEvent], lengthInBeats: Double,
                       direction: PlaybackDirection,
                       mutationAmount: Double, mutationRange: Int,
                       scaleRootSemitone: Int, scaleIntervals: [Int],
                       accumulatorConfig: AccumulatorConfig?)

    // Real-time parameter updates (no full reload needed)
    case sequencerSetGlobalProbability(Double)
    case sequencerSetMutation(amount: Double, range: Int, rootSemitone: Int, intervals: [Int])
    case sequencerResetMutation
    case sequencerFreezeMutation

    // Arp
    case sequencerSetArp(active: Bool, samplesPerStep: Int, gateLength: Double, mode: ArpMode)
    case sequencerSetArpPool(pitches: [Int], velocities: [Double], startBeats: [Double], endBeats: [Double])

    // Filter
    case setFilter(enabled: Bool, cutoff: Double, resonance: Double)

    // LFO modulation
    case setLFOSlot(slotIndex: Int, enabled: Bool, waveform: Int,
                    rateHz: Double, initialPhase: Double, depth: Double, parameter: Int)
    case setLFOSlotCount(Int)

    // Drum kit voice configuration
    case setDrumVoice(index: Int, carrierFreq: Double, modulatorRatio: Double,
                      fmDepth: Double, noiseMix: Double, ampDecay: Double,
                      pitchEnvAmount: Double, pitchDecay: Double, level: Double)
}

/// Lock-free single-producer single-consumer ring buffer for AudioCommands.
///
/// Thread safety contract:
/// - `push()` must only be called from the main thread (producer)
/// - `pop()` must only be called from the audio thread (consumer)
///
/// Uses power-of-2 capacity with masking for index wrapping.
/// Head and tail are stored as UnsafeMutablePointer<Int> for
/// cross-thread visibility without locks.
final class AudioCommandRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<AudioCommand?>

    // Separate cache lines to avoid false sharing.
    // Written only by producer, read by both.
    private let headPtr: UnsafeMutablePointer<Int>
    // Written only by consumer, read by both.
    private let tailPtr: UnsafeMutablePointer<Int>

    init(capacity requestedCapacity: Int = 256) {
        // Round up to power of 2
        var cap = 1
        while cap < requestedCapacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1

        self.storage = .allocate(capacity: cap)
        storage.initialize(repeating: nil, count: cap)

        self.headPtr = .allocate(capacity: 1)
        headPtr.initialize(to: 0)

        self.tailPtr = .allocate(capacity: 1)
        tailPtr.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        headPtr.deinitialize(count: 1)
        headPtr.deallocate()
        tailPtr.deinitialize(count: 1)
        tailPtr.deallocate()
    }

    /// Push a command onto the buffer. Called from main thread only.
    /// Returns false if the buffer is full.
    @discardableResult
    func push(_ command: AudioCommand) -> Bool {
        let head = headPtr.pointee
        let tail = tailPtr.pointee
        let next = (head + 1) & mask

        if next == tail {
            return false // full
        }

        storage[head] = command
        // Ensure the store to storage is visible before updating head.
        // On ARM64 (Apple Silicon) stores have release semantics.
        // On x86, stores are naturally ordered.
        headPtr.pointee = next
        return true
    }

    /// Pop a command from the buffer. Called from audio thread only.
    /// Returns nil if the buffer is empty. No allocations, no locks.
    ///
    /// The popped slot is NOT nilled out — leaving the old value avoids
    /// ARC release on the audio thread (which would call `free()` for
    /// commands carrying heap-allocated associated values like
    /// `.sequencerLoad`). The slot will be overwritten by the next
    /// `push()` from the main thread, where ARC release is safe.
    /// Stale slots are bounded by the ring buffer capacity (256).
    func pop() -> AudioCommand? {
        let tail = tailPtr.pointee
        let head = headPtr.pointee

        if tail == head {
            return nil // empty
        }

        let command = storage[tail]
        // Don't nil the slot — defer ARC release to the producer thread (push).
        tailPtr.pointee = (tail + 1) & mask
        return command
    }
}
