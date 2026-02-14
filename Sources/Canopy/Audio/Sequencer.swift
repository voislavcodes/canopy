import Foundation

/// A note event for the sequencer to schedule, derived from NoteSequence.
struct SequencerEvent {
    let pitch: Int
    let velocity: Double
    let startBeat: Double
    let endBeat: Double  // startBeat + duration
    let probability: Double
    let ratchetCount: Int

    init(pitch: Int, velocity: Double, startBeat: Double, endBeat: Double,
         probability: Double = 1.0, ratchetCount: Int = 1) {
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.probability = probability
        self.ratchetCount = ratchetCount
    }
}

// MARK: - Audio-thread-safe xorshift64 PRNG

/// Lock-free, allocation-free PRNG suitable for the audio render callback.
struct Xorshift64 {
    var state: UInt64

    init(seed: UInt64 = 88172645463325252) {
        self.state = seed == 0 ? 1 : seed
    }

    /// Returns a random UInt64.
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Returns a random Double in [0, 1).
    mutating func nextDouble() -> Double {
        Double(next() & 0x1FFFFFFFFFFFFF) / Double(1 << 53)
    }

    /// Returns a random Int in [low, high] (inclusive).
    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        guard span > 0 else { return range.lowerBound }
        return range.lowerBound + Int(next() % span)
    }
}

// MARK: - Pending Ratchet

/// Pre-allocated ratchet hit tracking — no allocations on audio thread.
struct PendingRatchet {
    var pitch: Int = 0
    var velocity: Double = 0
    var beatTime: Double = 0
    var endBeatTime: Double = 0
    var isActive: Bool = false
    var hasTriggeredOn: Bool = false
    var hasTriggeredOff: Bool = false
}

// MARK: - Sequencer

/// Audio-thread sequencer that advances a beat clock sample-by-sample
/// and triggers noteOn/noteOff events from a loaded sequence.
///
/// This struct is owned by the AudioEngine render callback.
/// All mutation happens on the audio thread — no locks needed.
///
/// All arrays are pre-allocated to `maxEvents` capacity in `init()`.
/// `load()` copies into pre-allocated storage via indexed assignment —
/// zero heap allocations on the audio thread.
struct Sequencer {
    /// Maximum number of events a single sequence can hold.
    /// Pre-allocated at init; load() clamps to this limit.
    static let maxEvents = 128

    /// Maximum number of scale intervals (chromatic = 12).
    static let maxScaleIntervals = 12

    var bpm: Double = 120
    var currentBeat: Double = 0
    var isPlaying: Bool = false

    private var events: [SequencerEvent]
    private var eventCount: Int = 0
    private var lengthInBeats: Double = 16

    // Track which events have been triggered this loop cycle
    private var triggeredOnFlags: [Bool]
    private var triggeredOffFlags: [Bool]

    // Probability
    var globalProbability: Double = 1.0
    private var prng = Xorshift64()
    private var probabilityRolled: [Bool]
    private var probabilityPassed: [Bool]

    // Direction
    private var direction: PlaybackDirection = .forward
    private var sortedStepIndices: [Int]
    private var sortedStepCount: Int = 0
    private var currentStepIndex: Int = 0
    private var pingPongForward: Bool = true
    private var lastBrownianStep: Int = 0
    private var directionTriggeredOn: [Bool]
    private var directionTriggeredOff: [Bool]
    // Step boundaries for direction-based stepping
    private var stepBoundaries: [Double]
    private var stepBoundaryCount: Int = 0
    private var lastStepBoundaryIndex: Int = -1

    // Cursor-based event scanning (forward mode)
    // Indices into events[] sorted by startBeat, for O(1) note-on scanning
    private var sortedOnIndices: [Int]
    private var sortedOnCount: Int = 0
    private var nextOnCursor: Int = 0
    // Indices into events[] sorted by endBeat, for O(1) note-off scanning
    private var sortedOffIndices: [Int]
    private var sortedOffCount: Int = 0
    private var nextOffCursor: Int = 0

    // Ratcheting
    private var pendingRatchets: [PendingRatchet] = Array(repeating: PendingRatchet(), count: 32)
    private var activeRatchetCount: Int = 0

    // Mutation
    private var mutatedPitches: [Int]
    private var originalPitches: [Int]
    private var mutationAmount: Double = 0
    private var mutationRange: Int = 0
    private var scaleRootSemitone: Int = 0
    private var scaleIntervals: [Int]
    private var scaleIntervalsCount: Int = 0
    /// Double buffer for freeze: A and B arrays. Audio writes active, main reads inactive.
    private var mutatedPitchesA: [Int]
    private var mutatedPitchesB: [Int]
    private var activeBufferIsA: Bool = true

    // Accumulator
    private var accumulatorValue: Double = 0
    private var accumulatorTarget: AccumulatorTarget = .pitch
    private var accumulatorAmount: Double = 0
    private var accumulatorLimit: Double = 12
    private var accumulatorMode: AccumulatorMode = .clamp
    private var accumulatorEnabled: Bool = false
    private var accumulatorDirection: Double = 1.0  // for pingPong

    // Cycle counter for loop wrap detection
    private var loopCount: Int = 0

    /// Sentinel event used for unused pre-allocated slots.
    private static let emptyEvent = SequencerEvent(pitch: 0, velocity: 0, startBeat: 0, endBeat: 0)

    init() {
        let cap = Sequencer.maxEvents
        events = Array(repeating: Sequencer.emptyEvent, count: cap)
        triggeredOnFlags = Array(repeating: false, count: cap)
        triggeredOffFlags = Array(repeating: false, count: cap)
        probabilityRolled = Array(repeating: false, count: cap)
        probabilityPassed = Array(repeating: false, count: cap)
        sortedStepIndices = Array(repeating: 0, count: cap)
        directionTriggeredOn = Array(repeating: false, count: cap)
        directionTriggeredOff = Array(repeating: false, count: cap)
        stepBoundaries = Array(repeating: 0, count: cap)
        sortedOnIndices = Array(repeating: 0, count: cap)
        sortedOffIndices = Array(repeating: 0, count: cap)
        mutatedPitches = Array(repeating: 0, count: cap)
        originalPitches = Array(repeating: 0, count: cap)
        mutatedPitchesA = Array(repeating: 0, count: cap)
        mutatedPitchesB = Array(repeating: 0, count: cap)
        scaleIntervals = Array(repeating: 0, count: Sequencer.maxScaleIntervals)
    }

    /// Load a sequence of events into pre-allocated storage. Zero heap allocations.
    mutating func load(events incoming: [SequencerEvent], lengthInBeats: Double,
                       direction: PlaybackDirection = .forward,
                       mutationAmount: Double = 0, mutationRange: Int = 0,
                       scaleRootSemitone: Int = 0, scaleIntervals incomingIntervals: [Int] = [],
                       accumulatorConfig: AccumulatorConfig? = nil) {
        let count = min(incoming.count, Sequencer.maxEvents)
        self.eventCount = count
        self.lengthInBeats = max(lengthInBeats, 1)
        self.direction = direction

        // Copy events into pre-allocated storage
        for i in 0..<count {
            events[i] = incoming[i]
        }

        // Reset flags
        for i in 0..<count {
            triggeredOnFlags[i] = false
            triggeredOffFlags[i] = false
            probabilityRolled[i] = false
            probabilityPassed[i] = false
            directionTriggeredOn[i] = false
            directionTriggeredOff[i] = false
        }

        // Direction setup: build sorted step indices
        // Simple insertion sort (count is small, avoids allocation)
        for i in 0..<count {
            sortedStepIndices[i] = i
        }
        self.sortedStepCount = count
        if count > 1 {
            for i in 1..<count {
                let key = sortedStepIndices[i]
                var j = i - 1
                while j >= 0 && events[sortedStepIndices[j]].startBeat > events[key].startBeat {
                    sortedStepIndices[j + 1] = sortedStepIndices[j]
                    j -= 1
                }
                sortedStepIndices[j + 1] = key
            }
        }

        self.currentStepIndex = direction == .reverse ? max(count - 1, 0) : 0
        self.pingPongForward = true
        self.lastBrownianStep = 0

        // Build step boundaries (sorted startBeats)
        self.stepBoundaryCount = count
        for i in 0..<count {
            stepBoundaries[i] = events[sortedStepIndices[i]].startBeat
        }
        self.lastStepBoundaryIndex = -1

        // Build cursor arrays for forward-mode O(1) scanning
        // sortedOnIndices: indices into events[] sorted by startBeat
        for i in 0..<count {
            sortedOnIndices[i] = i
        }
        self.sortedOnCount = count
        if count > 1 {
            for i in 1..<count {
                let key = sortedOnIndices[i]
                var j = i - 1
                while j >= 0 && events[sortedOnIndices[j]].startBeat > events[key].startBeat {
                    sortedOnIndices[j + 1] = sortedOnIndices[j]
                    j -= 1
                }
                sortedOnIndices[j + 1] = key
            }
        }

        // sortedOffIndices: indices into events[] sorted by endBeat
        for i in 0..<count {
            sortedOffIndices[i] = i
        }
        self.sortedOffCount = count
        if count > 1 {
            for i in 1..<count {
                let key = sortedOffIndices[i]
                var j = i - 1
                while j >= 0 && events[sortedOffIndices[j]].endBeat > events[key].endBeat {
                    sortedOffIndices[j + 1] = sortedOffIndices[j]
                    j -= 1
                }
                sortedOffIndices[j + 1] = key
            }
        }
        self.nextOnCursor = 0
        self.nextOffCursor = 0

        // Clear ratchets
        for i in 0..<pendingRatchets.count {
            pendingRatchets[i].isActive = false
        }
        activeRatchetCount = 0

        // Mutation setup
        for i in 0..<count {
            originalPitches[i] = incoming[i].pitch
            mutatedPitches[i] = incoming[i].pitch
            mutatedPitchesA[i] = incoming[i].pitch
            mutatedPitchesB[i] = incoming[i].pitch
        }
        self.activeBufferIsA = true
        self.mutationAmount = mutationAmount
        self.mutationRange = mutationRange
        self.scaleRootSemitone = scaleRootSemitone

        // Copy scale intervals
        let intervalCount = min(incomingIntervals.count, Sequencer.maxScaleIntervals)
        self.scaleIntervalsCount = intervalCount
        for i in 0..<intervalCount {
            scaleIntervals[i] = incomingIntervals[i]
        }

        // Accumulator setup
        self.accumulatorValue = 0
        self.accumulatorDirection = 1.0
        if let acc = accumulatorConfig {
            self.accumulatorEnabled = true
            self.accumulatorTarget = acc.target
            self.accumulatorAmount = acc.amount
            self.accumulatorLimit = acc.limit
            self.accumulatorMode = acc.mode
        } else {
            self.accumulatorEnabled = false
        }

        self.loopCount = 0
    }

    /// Start playback from beat 0.
    mutating func start(bpm: Double) {
        self.bpm = bpm
        self.currentBeat = 0
        self.isPlaying = true
        self.loopCount = 0
        self.accumulatorValue = 0
        self.accumulatorDirection = 1.0
        resetFlags()
    }

    /// Stop playback.
    mutating func stop() {
        isPlaying = false
        currentBeat = 0
    }

    /// Set mutation parameters without full reload.
    mutating func setMutation(amount: Double, range: Int, rootSemitone: Int, intervals: [Int]) {
        self.mutationAmount = amount
        self.mutationRange = range
        self.scaleRootSemitone = rootSemitone
        // Only update intervals if provided (avoid empty overwrite)
        if !intervals.isEmpty {
            let intervalCount = min(intervals.count, Sequencer.maxScaleIntervals)
            self.scaleIntervalsCount = intervalCount
            for i in 0..<intervalCount {
                scaleIntervals[i] = intervals[i]
            }
        }
    }

    /// Reset mutated pitches to originals.
    mutating func resetMutation() {
        for i in 0..<eventCount {
            mutatedPitches[i] = originalPitches[i]
        }
        if activeBufferIsA {
            for i in 0..<eventCount { mutatedPitchesA[i] = originalPitches[i] }
        } else {
            for i in 0..<eventCount { mutatedPitchesB[i] = originalPitches[i] }
        }
    }

    /// Freeze: copy current mutations to inactive buffer and swap.
    /// After this, the main thread can read the inactive buffer safely.
    mutating func freezeMutation() {
        if activeBufferIsA {
            for i in 0..<eventCount { mutatedPitchesB[i] = mutatedPitchesA[i] }
        } else {
            for i in 0..<eventCount { mutatedPitchesA[i] = mutatedPitchesB[i] }
        }
        activeBufferIsA.toggle()
    }

    /// Read frozen pitches (call from main thread when audio is using the other buffer).
    func frozenPitches() -> [Int] {
        let source = activeBufferIsA ? mutatedPitchesB : mutatedPitchesA
        return Array(source[0..<eventCount])
    }

    /// Advance the beat clock by one sample and trigger any pending events.
    /// Called from the audio render callback per sample frame.
    mutating func advanceOneSample(sampleRate: Double, voices: inout VoiceManager, detune: Double) {
        guard isPlaying else { return }

        let beatsPerSample = bpm / (60.0 * sampleRate)

        currentBeat += beatsPerSample

        // Check for loop wrap
        if currentBeat >= lengthInBeats {
            // Trigger any remaining note-offs before wrapping
            for i in 0..<eventCount {
                if triggeredOnFlags[i] && !triggeredOffFlags[i] {
                    voices.noteOff(pitch: applyAccumulatorToPitch(effectivePitch(for: i)))
                    triggeredOffFlags[i] = true
                }
            }
            // Clear pending ratchets
            for i in 0..<pendingRatchets.count {
                if pendingRatchets[i].isActive && !pendingRatchets[i].hasTriggeredOff {
                    voices.noteOff(pitch: applyAccumulatorToPitch(pendingRatchets[i].pitch))
                }
                pendingRatchets[i].isActive = false
            }
            activeRatchetCount = 0

            currentBeat -= lengthInBeats
            loopCount += 1

            // Apply mutation at loop wrap
            if mutationAmount > 0 && scaleIntervalsCount > 0 {
                applyMutation()
            }

            // Advance accumulator at loop wrap
            if accumulatorEnabled {
                advanceAccumulator()
            }

            // Reset direction state for new cycle
            if direction == .reverse {
                currentStepIndex = max(sortedStepCount - 1, 0)
            } else {
                currentStepIndex = 0
            }
            lastStepBoundaryIndex = -1

            // Reset cursors for forward mode
            nextOnCursor = 0
            nextOffCursor = 0

            resetFlags()
        }

        // Process ratchets (short-circuit when none active)
        if activeRatchetCount > 0 {
            processRatchets(voices: &voices, detune: detune)
        }

        // Forward direction uses cursor-based scanning
        if direction == .forward {
            advanceForward(sampleRate: sampleRate, voices: &voices, detune: detune)
        } else {
            advanceDirectional(sampleRate: sampleRate, voices: &voices, detune: detune)
        }
    }

    // MARK: - Forward Playback (cursor-based O(1) amortized scanning)

    private mutating func advanceForward(sampleRate: Double, voices: inout VoiceManager, detune: Double) {
        // Note-on: check only the next event(s) at the cursor
        while nextOnCursor < sortedOnCount {
            let eventIdx = sortedOnIndices[nextOnCursor]
            let event = events[eventIdx]
            if currentBeat >= event.startBeat {
                triggeredOnFlags[eventIdx] = true
                triggerEventOn(index: eventIdx, voices: &voices, detune: detune)
                nextOnCursor += 1
            } else {
                break
            }
        }

        // Note-off: check only the next event(s) at the cursor
        while nextOffCursor < sortedOffCount {
            let eventIdx = sortedOffIndices[nextOffCursor]
            if triggeredOnFlags[eventIdx] && currentBeat >= events[eventIdx].endBeat {
                voices.noteOff(pitch: applyAccumulatorToPitch(effectivePitch(for: eventIdx)))
                triggeredOffFlags[eventIdx] = true
                nextOffCursor += 1
            } else {
                break
            }
        }
    }

    // MARK: - Directional Playback

    private mutating func advanceDirectional(sampleRate: Double, voices: inout VoiceManager, detune: Double) {
        guard sortedStepCount > 0 else { return }

        // Cursor-based boundary detection: check only the next boundary
        var currentBoundaryIndex = lastStepBoundaryIndex
        while currentBoundaryIndex + 1 < stepBoundaryCount
                && currentBeat >= stepBoundaries[currentBoundaryIndex + 1] {
            currentBoundaryIndex += 1
        }

        // If we crossed a new step boundary, advance the directional index
        if currentBoundaryIndex > lastStepBoundaryIndex && currentBoundaryIndex >= 0 {
            let stepsToAdvance = currentBoundaryIndex - max(lastStepBoundaryIndex, -1)
            for _ in 0..<stepsToAdvance {
                if lastStepBoundaryIndex >= 0 {
                    advanceStepIndex()
                }
                lastStepBoundaryIndex += 1
            }

            // Map directional step to actual event
            let eventIndex = mapStepToEvent(currentStepIndex)
            if eventIndex >= 0 && eventIndex < eventCount && !directionTriggeredOn[eventIndex] {
                directionTriggeredOn[eventIndex] = true
                triggerEventOn(index: eventIndex, voices: &voices, detune: detune)
            }
        }

        // Handle note-offs based on duration
        for i in 0..<eventCount {
            if directionTriggeredOn[i] && !directionTriggeredOff[i] {
                let event = events[i]
                let duration = event.endBeat - event.startBeat
                // For non-forward, note-off after duration from when it was triggered
                // Use current beat position relative to the event's start
                if currentBeat >= event.startBeat + duration || currentBeat < event.startBeat {
                    if directionTriggeredOn[i] {
                        voices.noteOff(pitch: applyAccumulatorToPitch(effectivePitch(for: i)))
                        directionTriggeredOff[i] = true
                    }
                }
            }
        }
    }

    private mutating func advanceStepIndex() {
        let count = sortedStepCount
        guard count > 0 else { return }

        switch direction {
        case .forward:
            currentStepIndex = (currentStepIndex + 1) % count
        case .reverse:
            currentStepIndex = (currentStepIndex - 1 + count) % count
        case .pingPong:
            if pingPongForward {
                currentStepIndex += 1
                if currentStepIndex >= count - 1 {
                    currentStepIndex = count - 1
                    pingPongForward = false
                }
            } else {
                currentStepIndex -= 1
                if currentStepIndex <= 0 {
                    currentStepIndex = 0
                    pingPongForward = true
                }
            }
        case .random:
            currentStepIndex = prng.nextInt(in: 0...max(0, count - 1))
        case .brownian:
            let step = prng.nextInt(in: -1...1)
            currentStepIndex = (currentStepIndex + step + count) % count
        }
    }

    private func mapStepToEvent(_ stepIndex: Int) -> Int {
        guard stepIndex >= 0 && stepIndex < sortedStepCount else { return -1 }
        return sortedStepIndices[stepIndex]
    }

    // MARK: - Event Triggering

    private mutating func triggerEventOn(index i: Int, voices: inout VoiceManager, detune: Double) {
        let event = events[i]

        // Roll probability (only once per event per cycle)
        if !probabilityRolled[i] {
            probabilityRolled[i] = true
            let effectiveProb = event.probability * globalProbability
            probabilityPassed[i] = prng.nextDouble() < effectiveProb
        }
        guard probabilityPassed[i] else { return }

        let pitch = effectivePitch(for: i)

        if event.ratchetCount > 1 {
            // Schedule ratchet hits
            let duration = event.endBeat - event.startBeat
            let subDuration = duration / Double(event.ratchetCount)
            let gateRatio = 0.8

            for r in 0..<event.ratchetCount {
                let ratchetStart = event.startBeat + Double(r) * subDuration
                let ratchetEnd = ratchetStart + subDuration * gateRatio
                let velocityDecay = event.velocity * (1.0 - 0.15 * Double(r))

                // Find a free ratchet slot
                if let slot = (0..<pendingRatchets.count).first(where: { !pendingRatchets[$0].isActive }) {
                    pendingRatchets[slot] = PendingRatchet(
                        pitch: pitch,
                        velocity: max(0.1, velocityDecay),
                        beatTime: ratchetStart,
                        endBeatTime: ratchetEnd,
                        isActive: true,
                        hasTriggeredOn: false,
                        hasTriggeredOff: false
                    )
                    activeRatchetCount += 1
                }
            }
        } else {
            // Normal single note
            let accPitch = applyAccumulatorToPitch(pitch)
            let accVelocity = applyAccumulatorToVelocity(event.velocity)
            let freq = MIDIUtilities.detunedFrequency(
                base: MIDIUtilities.frequency(forNote: accPitch),
                cents: detune
            )
            voices.noteOn(pitch: accPitch, velocity: accVelocity, frequency: freq)
        }
    }

    // MARK: - Ratchet Processing

    private mutating func processRatchets(voices: inout VoiceManager, detune: Double) {
        for i in 0..<pendingRatchets.count {
            guard pendingRatchets[i].isActive else { continue }

            // Note on
            if !pendingRatchets[i].hasTriggeredOn && currentBeat >= pendingRatchets[i].beatTime {
                let pitch = applyAccumulatorToPitch(pendingRatchets[i].pitch)
                let velocity = applyAccumulatorToVelocity(pendingRatchets[i].velocity)
                let freq = MIDIUtilities.detunedFrequency(
                    base: MIDIUtilities.frequency(forNote: pitch),
                    cents: detune
                )
                voices.noteOn(pitch: pitch, velocity: velocity, frequency: freq)
                pendingRatchets[i].hasTriggeredOn = true
            }

            // Note off
            if pendingRatchets[i].hasTriggeredOn && !pendingRatchets[i].hasTriggeredOff
                && currentBeat >= pendingRatchets[i].endBeatTime {
                voices.noteOff(pitch: applyAccumulatorToPitch(pendingRatchets[i].pitch))
                pendingRatchets[i].hasTriggeredOff = true
                pendingRatchets[i].isActive = false
                activeRatchetCount -= 1
            }
        }
    }

    // MARK: - Effective Pitch (mutation)

    private func effectivePitch(for index: Int) -> Int {
        guard index < eventCount else {
            return index < eventCount ? events[index].pitch : 60
        }
        return mutatedPitches[index]
    }

    // MARK: - Mutation

    private mutating func applyMutation() {
        guard mutationRange > 0 && scaleIntervalsCount > 0 else { return }
        let rootSemi = scaleRootSemitone

        for i in 0..<eventCount {
            if prng.nextDouble() < mutationAmount {
                let shift = prng.nextInt(in: -mutationRange...mutationRange)
                if shift != 0 {
                    mutatedPitches[i] = quantizeToScale(
                        shiftPitch(mutatedPitches[i], byDegrees: shift, root: rootSemi),
                        root: rootSemi
                    )
                }
            }
        }
        // Update active buffer
        if activeBufferIsA {
            for i in 0..<eventCount { mutatedPitchesA[i] = mutatedPitches[i] }
        } else {
            for i in 0..<eventCount { mutatedPitchesB[i] = mutatedPitches[i] }
        }
    }

    /// Shift a MIDI note by scale degrees. Pure math, no allocations.
    private func shiftPitch(_ midi: Int, byDegrees degrees: Int, root: Int) -> Int {
        let pc = ((midi % 12) - root + 12) % 12
        let octave = midi / 12

        // Find current degree
        var currentDeg = 0
        var minDist = 12
        for idx in 0..<scaleIntervalsCount {
            let dist = abs(pc - scaleIntervals[idx])
            if dist < minDist {
                minDist = dist
                currentDeg = idx
            }
        }

        let scaleSize = scaleIntervalsCount
        let targetDeg = currentDeg + degrees
        let octShift = targetDeg >= 0
            ? targetDeg / scaleSize
            : (targetDeg - scaleSize + 1) / scaleSize
        let degInScale = ((targetDeg % scaleSize) + scaleSize) % scaleSize

        let result = (octave + octShift) * 12 + root + scaleIntervals[degInScale]
        return max(0, min(127, result))
    }

    /// Quantize to nearest scale note. Pure math.
    private func quantizeToScale(_ midi: Int, root: Int) -> Int {
        let pc = ((midi % 12) - root + 12) % 12
        for idx in 0..<scaleIntervalsCount {
            if scaleIntervals[idx] == pc { return midi }
        }

        var bestOffset = 12
        for idx in 0..<scaleIntervalsCount {
            let diff = scaleIntervals[idx] - pc
            for candidate in [diff, diff + 12, diff - 12] {
                if abs(candidate) < abs(bestOffset) {
                    bestOffset = candidate
                }
            }
        }
        return max(0, min(127, midi + bestOffset))
    }

    // MARK: - Accumulator

    private mutating func advanceAccumulator() {
        switch accumulatorMode {
        case .clamp:
            accumulatorValue += accumulatorAmount
            accumulatorValue = max(-accumulatorLimit, min(accumulatorLimit, accumulatorValue))
        case .wrap:
            accumulatorValue += accumulatorAmount
            if accumulatorLimit > 0 {
                while accumulatorValue > accumulatorLimit { accumulatorValue -= accumulatorLimit * 2 }
                while accumulatorValue < -accumulatorLimit { accumulatorValue += accumulatorLimit * 2 }
            }
        case .pingPong:
            accumulatorValue += accumulatorAmount * accumulatorDirection
            if accumulatorValue >= accumulatorLimit {
                accumulatorValue = accumulatorLimit
                accumulatorDirection = -1
            } else if accumulatorValue <= -accumulatorLimit {
                accumulatorValue = -accumulatorLimit
                accumulatorDirection = 1
            }
        }
    }

    private func applyAccumulatorToPitch(_ pitch: Int) -> Int {
        guard accumulatorEnabled && accumulatorTarget == .pitch else { return pitch }
        return max(0, min(127, pitch + Int(round(accumulatorValue))))
    }

    private func applyAccumulatorToVelocity(_ velocity: Double) -> Double {
        guard accumulatorEnabled && accumulatorTarget == .velocity else { return velocity }
        return max(0.0, min(1.0, velocity + accumulatorValue / 127.0))
    }

    // Probability accumulator affects the roll threshold
    func accumulatorProbabilityOffset() -> Double {
        guard accumulatorEnabled && accumulatorTarget == .probability else { return 0 }
        return accumulatorValue / 100.0
    }

    // MARK: - Flag Reset

    private mutating func resetFlags() {
        for i in 0..<eventCount {
            triggeredOnFlags[i] = false
            triggeredOffFlags[i] = false
            probabilityRolled[i] = false
            probabilityPassed[i] = false
            directionTriggeredOn[i] = false
            directionTriggeredOff[i] = false
        }
    }
}
