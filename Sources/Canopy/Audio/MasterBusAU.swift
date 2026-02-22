import AVFoundation
import AudioToolbox
import os

/// In-process Audio Unit effect that implements the master bus processing chain.
///
/// Inserted between `mainMixerNode` and `outputNode` in the AVAudioEngine graph.
/// Processes all audio through the Shore (brick-wall limiter) and optional master FX chain.
///
/// The render block captures raw pointers — no ObjC messaging, no ARC, no heap ops on audio thread.
final class MasterBusAU: AUAudioUnit {
    // Component description for registration
    static let masterBusDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCC("mbus"),
        componentManufacturer: fourCC("Cnpy"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Convert a 4-character string to FourCharCode.
    private static func fourCC(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) | FourCharCode(char)
        }
        return result
    }

    private static let logger = Logger(subsystem: "com.canopy", category: "MasterBusAU")

    // Bus arrays
    private var _inputBusArray: AUAudioUnitBusArray!
    private var _outputBusArray: AUAudioUnitBusArray!

    // Shore limiter — heap-allocated for stable pointer capture
    private let shorePtr: UnsafeMutablePointer<StereoShore>

    // Master FX chain — pointer-swapped from main thread
    private let fxChainPtr: UnsafeMutablePointer<EffectChain>

    // Master volume
    private let volumePtr: UnsafeMutablePointer<Float>

    // BPM for tempo-synced effects (e.g. DRIFT sync mode)
    private let bpmPtr: UnsafeMutablePointer<Double>

    // Sample rate for render block (updated in allocateRenderResources)
    private let sampleRatePtr: UnsafeMutablePointer<Float>

    // Tree clock slots — pointer-to-optional-pointer pattern because MasterBusAU
    // is instantiated by Apple's AU framework (can't pass constructor args).
    // Set via setClockPointers() after instantiation.
    private let clockPositionSlot: UnsafeMutablePointer<UnsafeMutablePointer<Int64>?>
    private let clockRunningSlot: UnsafeMutablePointer<UnsafeMutablePointer<Bool>?>

    // Internal render block (captured once, no per-render allocation)
    private var _internalRenderBlock: AUInternalRenderBlock!

    /// Whether Shore limiting is active.
    var shoreEnabled: Bool {
        get { shorePtr.pointee.enabled }
        set { shorePtr.pointee.enabled = newValue }
    }

    /// Shore ceiling in linear amplitude.
    var shoreCeiling: Float {
        get { shorePtr.pointee.ceiling }
        set { shorePtr.pointee.ceiling = newValue }
    }

    /// Master volume (0.0–1.0).
    var masterVolume: Float {
        get { volumePtr.pointee }
        set { volumePtr.pointee = max(0, min(1, newValue)) }
    }

    /// BPM for tempo-synced master bus effects.
    var masterBPM: Double {
        get { bpmPtr.pointee }
        set { bpmPtr.pointee = newValue }
    }

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        // Pre-allocate all audio-thread state on the main thread
        shorePtr = .allocate(capacity: 1)
        shorePtr.initialize(to: StereoShore(lookaheadSamples: 48, releaseMs: 100, ceiling: 0.97, sampleRate: 48000))

        fxChainPtr = .allocate(capacity: 1)
        fxChainPtr.initialize(to: EffectChain())

        volumePtr = .allocate(capacity: 1)
        volumePtr.initialize(to: 1.0)

        bpmPtr = .allocate(capacity: 1)
        bpmPtr.initialize(to: 120.0)

        sampleRatePtr = .allocate(capacity: 1)
        sampleRatePtr.initialize(to: 48000)

        clockPositionSlot = .allocate(capacity: 1)
        clockPositionSlot.initialize(to: nil)
        clockRunningSlot = .allocate(capacity: 1)
        clockRunningSlot.initialize(to: nil)

        try super.init(componentDescription: componentDescription, options: options)

        // Create stereo format
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        // Set up bus arrays
        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        _inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        // Build render block capturing raw pointers only
        let shore = shorePtr
        let fxChain = fxChainPtr
        let vol = volumePtr
        let bpmP = bpmPtr
        let srPtr = sampleRatePtr
        let posSlot = clockPositionSlot
        let runSlot = clockRunningSlot

        _internalRenderBlock = { actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvent, pullInputBlock in
            guard let pullInputBlock = pullInputBlock else {
                return kAudio_ParamError
            }

            // Pull input from upstream (mainMixerNode)
            var pullFlags: AudioUnitRenderActionFlags = []
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            guard abl.count >= 2 else { return noErr }

            let bufL = abl[0].mData?.assumingMemoryBound(to: Float.self)
            let bufR = abl[1].mData?.assumingMemoryBound(to: Float.self)
            guard let leftBuf = bufL, let rightBuf = bufR else { return noErr }

            let sampleRate = srPtr.pointee
            let volume = vol.pointee

            // Propagate BPM to tempo-synced effects once per buffer
            fxChain.pointee.updateBPM(bpmP.pointee)

            for frame in 0..<Int(frameCount) {
                var sampleL = leftBuf[frame] * volume
                var sampleR = rightBuf[frame] * volume

                // Process through master FX chain (stereo-aware)
                (sampleL, sampleR) = fxChain.pointee.processStereo(sampleL: sampleL, sampleR: sampleR, sampleRate: sampleRate)

                // Shore limiter (always last in chain)
                let (limitedL, limitedR) = shore.pointee.process(left: sampleL, right: sampleR)
                leftBuf[frame] = limitedL
                rightBuf[frame] = limitedR
            }

            // Advance tree clock AFTER all processing.
            // Source nodes already rendered (pull model), so this is safe.
            if runSlot.pointee?.pointee == true {
                posSlot.pointee?.pointee += Int64(frameCount)
            }

            return noErr
        }
    }

    /// Connect the tree clock pointers. Called from main thread after AU instantiation.
    func setClockPointers(samplePosition: UnsafeMutablePointer<Int64>,
                          isRunning: UnsafeMutablePointer<Bool>) {
        clockPositionSlot.pointee = samplePosition
        clockRunningSlot.pointee = isRunning
    }

    deinit {
        shorePtr.deinitialize(count: 1)
        shorePtr.deallocate()
        fxChainPtr.deinitialize(count: 1)
        fxChainPtr.deallocate()
        volumePtr.deinitialize(count: 1)
        volumePtr.deallocate()
        bpmPtr.deinitialize(count: 1)
        bpmPtr.deallocate()
        sampleRatePtr.deinitialize(count: 1)
        sampleRatePtr.deallocate()
        clockPositionSlot.deinitialize(count: 1)
        clockPositionSlot.deallocate()
        clockRunningSlot.deinitialize(count: 1)
        clockRunningSlot.deallocate()
    }

    // MARK: - AUAudioUnit overrides

    override var inputBusses: AUAudioUnitBusArray { _inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

    override var internalRenderBlock: AUInternalRenderBlock { _internalRenderBlock }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        // Update Shore and render block sample rate from actual format
        let sr = Float(inputBusses[0].format.sampleRate)
        sampleRatePtr.pointee = sr
        shorePtr.pointee = StereoShore(lookaheadSamples: 48, releaseMs: 100,
                                        ceiling: shorePtr.pointee.ceiling,
                                        sampleRate: sr)
        Self.logger.info("MasterBusAU allocated render resources at \(sr) Hz")
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        shorePtr.pointee.reset()
    }

    // MARK: - FX Chain Swap (main thread)

    /// Swap the master effect chain. Called from main thread.
    /// The old chain is deallocated on the main thread after the swap.
    func swapFXChain(_ newChain: EffectChain) {
        fxChainPtr.pointee = newChain
    }

    /// Reset Shore state (call on transport stop).
    func resetShore() {
        shorePtr.pointee.reset()
    }
}

// MARK: - Registration

extension MasterBusAU {
    /// Register the MasterBusAU component for in-process instantiation.
    /// Call once at app startup before engine.start().
    static func register() {
        AUAudioUnit.registerSubclass(
            MasterBusAU.self,
            as: masterBusDescription,
            name: "Canopy Master Bus",
            version: 1
        )
        logger.info("MasterBusAU registered")
    }
}
