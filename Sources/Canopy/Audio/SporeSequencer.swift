import Foundation

/// Audio-thread-safe probabilistic sequencer for SPORE.
/// Notes emerge from autocorrelation (Memory) and evolve under random walks (Drift).
/// All state is inline (no heap, no arrays, no CoW) for real-time safety.
struct SporeSequencerState {
    // MARK: - Clock

    private var phase: Double = 0           // accumulated samples within current subdivision
    private var samplesPerSubdivision: Int = 0
    private var subdivision: SporeSubdivision = .sixteenth

    // MARK: - Controls (with smoothing targets)

    private var densityParam: Double = 0.5
    private var densityTarget: Double = 0.5
    private var focusParam: Double = 0.4
    private var focusTarget: Double = 0.4
    private var driftParam: Double = 0.3
    private var driftTarget: Double = 0.3
    private var memoryParam: Double = 0.3
    private var memoryTarget: Double = 0.3

    // MARK: - Memory chain (autocorrelation)

    private var previousPitch: Int = 60         // last fired pitch (MIDI)
    private var previousVelocity: Float = 0.7   // last fired velocity
    private var previousFired: Bool = false      // did we fire last step?

    // MARK: - Drift state (random walks on 5 dimensions)

    private var centerPitchOffset: Double = 0   // random walk on center pitch
    private var focusModulation: Double = 0     // drift on pitch focus
    private var densityModulation: Double = 0   // drift on event density
    private var velocityOffset: Double = 0      // drift on velocity
    private var subdivisionJitter: Double = 0   // drift on timing

    // MARK: - Scale data (inline, max 12 intervals)

    private var scaleIntervals: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int)
        = (0, 2, 3, 5, 7, 8, 10, 0, 0, 0, 0, 0)
    private var scaleCount: Int = 7
    private var rootSemitone: Int = 0

    // MARK: - Range

    private var rangeOctaves: Int = 3

    // MARK: - RNG

    private var noiseState: UInt32 = 0xBEEF_CAFE

    // MARK: - Transport

    var isRunning: Bool = false
    var bpm: Double = 120

    // MARK: - Note tracking for auto note-off

    private var activeNotes: (Int, Int, Int, Int, Int, Int, Int, Int) = (-1, -1, -1, -1, -1, -1, -1, -1)
    private var activeNoteTimers: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)

    // MARK: - Init

    init() {}

    // MARK: - Configuration

    mutating func configure(
        subdivision: SporeSubdivision,
        density: Double,
        focus: Double,
        drift: Double,
        memory: Double,
        rangeOctaves: Int
    ) {
        self.subdivision = subdivision
        self.densityTarget = density
        self.focusTarget = focus
        self.driftTarget = drift
        self.memoryTarget = memory
        self.rangeOctaves = max(1, min(6, rangeOctaves))
    }

    mutating func setScale(rootSemitone: Int, intervals: [Int]) {
        self.rootSemitone = rootSemitone
        self.scaleCount = min(12, intervals.count)
        withUnsafeMutablePointer(to: &scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                for i in 0..<12 {
                    p[i] = i < intervals.count ? intervals[i] : 0
                }
            }
        }
    }

    // MARK: - Transport

    mutating func start(bpm: Double) {
        self.bpm = bpm
        self.isRunning = true
        self.phase = 0
        previousPitch = 60
        previousVelocity = 0.7
        previousFired = false
        centerPitchOffset = 0
        focusModulation = 0
        densityModulation = 0
        velocityOffset = 0
        subdivisionJitter = 0
    }

    mutating func stop() {
        isRunning = false
    }

    mutating func setBPM(_ newBPM: Double) {
        self.bpm = newBPM
    }

    // MARK: - Main Process

    /// Process samples and fire events via callback.
    /// Called per-sample or per-buffer from the audio thread.
    mutating func process(sampleCount: Int, sampleRate: Double,
                          eventCallback: (Int, Double) -> Void) {
        guard isRunning else { return }

        // Smooth controls
        let smooth = 0.001
        densityParam += (densityTarget - densityParam) * smooth
        focusParam += (focusTarget - focusParam) * smooth
        driftParam += (driftTarget - driftParam) * smooth
        memoryParam += (memoryTarget - memoryParam) * smooth

        // Calculate samples per subdivision
        let beatsPerSecond = bpm / 60.0
        let subdivBeats = subdivision.beats
        let subdivSeconds = subdivBeats / beatsPerSecond
        samplesPerSubdivision = max(1, Int(subdivSeconds * sampleRate))

        // Decrement active note timers
        decrementNoteTimers(sampleCount: sampleCount, eventCallback: eventCallback)

        for _ in 0..<sampleCount {
            phase += 1

            if Int(phase) >= samplesPerSubdivision {
                phase = 0
                onSubdivisionBoundary(sampleRate: sampleRate, eventCallback: eventCallback)
            }
        }
    }

    // MARK: - Subdivision Processing

    private mutating func onSubdivisionBoundary(sampleRate: Double,
                                                 eventCallback: (Int, Double) -> Void) {
        // Advance drift
        advanceDrift()

        // Effective density with drift modulation
        let effectiveDensity = max(0, min(1, densityParam + densityModulation))

        // Should we fire?
        guard shouldFire(density: effectiveDensity) else {
            previousFired = false
            return
        }

        // Generate pitch and velocity
        let effectiveFocus = max(0, min(1, focusParam + focusModulation))
        let (pitch, velocity) = generateEvent(focus: effectiveFocus)

        // Duration: density-responsive note length
        let subdivSeconds = subdivision.beats / (bpm / 60.0)
        let durationSeconds = drawDuration(subdivisionDuration: subdivSeconds, density: effectiveDensity)
        let durationSamples = max(1, Int(durationSeconds * sampleRate))

        // Track note for auto note-off
        trackNote(pitch: pitch, durationSamples: durationSamples)

        // Fire event
        eventCallback(pitch, velocity)

        // Update memory chain
        previousPitch = pitch
        previousVelocity = Float(velocity)
        previousFired = true
    }

    // MARK: - Probability Gate

    /// Returns true with probability = density per subdivision step.
    private mutating func shouldFire(density: Double) -> Bool {
        return xorshiftUnit() < density
    }

    // MARK: - Event Generation

    /// Generate a pitch and velocity using memory chain logic.
    /// Memory=0: pure random from scale
    /// Memory=1: repeat or perturb previous pitch
    private mutating func generateEvent(focus: Double) -> (Int, Double) {
        let memory = memoryParam

        let pitch: Int
        if !previousFired || xorshiftUnit() > memory {
            // Fresh draw from scale distribution
            pitch = drawPitch(focus: focus)
        } else if xorshiftUnit() < memory * 0.6 {
            // Repeat previous
            pitch = previousPitch
        } else {
            // Perturb previous by a scale step
            let direction = xorshiftUnit() < 0.5 ? -1 : 1
            let steps = 1 + Int(xorshiftUnit() * 2)
            pitch = perturbPitch(previousPitch, steps: steps * direction)
        }

        // Velocity: focus-scaled distribution
        let velocityBase = 0.5 + focus * 0.3
        let velocitySpread = (1.0 - focus) * 0.3
        let velocityRandom = xorshiftNorm() * velocitySpread
        let effectiveVelocity = max(0.1, min(1.0,
            velocityBase + velocityRandom + velocityOffset * 0.2
        ))

        // Memory: blend toward previous velocity
        let finalVelocity: Double
        if memory > 0 && previousFired {
            finalVelocity = effectiveVelocity * (1 - memory * 0.5) + Double(previousVelocity) * memory * 0.5
        } else {
            finalVelocity = effectiveVelocity
        }

        return (pitch, max(0.1, min(1.0, finalVelocity)))
    }

    /// Draw a pitch from Gaussian-weighted scale degrees.
    private mutating func drawPitch(focus: Double) -> Int {
        guard scaleCount > 0 else { return 60 }

        // Center note with drift
        let centerOctave = 5  // MIDI octave 5 = C5 = 60
        let centerNote = Double(centerOctave * 12 + rootSemitone) + centerPitchOffset

        // Range in semitones
        let rangeSemitones = Double(rangeOctaves) * 12.0

        // Draw from Gaussian centered on centerNote, scaled by focus
        // High focus → tight cluster, low focus → wide spread
        let sigma = rangeSemitones * 0.5 * (1.0 - focus * 0.8)
        let rawPitch = centerNote + gaussianRandom() * sigma

        // Snap to nearest scale degree
        let snapped = nearestScaleDegree(to: Int(rawPitch.rounded()))

        // Clamp to range
        let low = Int(centerNote - rangeSemitones * 0.5)
        let high = Int(centerNote + rangeSemitones * 0.5)
        return max(max(0, low), min(min(127, high), snapped))
    }

    /// Perturb a pitch by a number of scale steps.
    private mutating func perturbPitch(_ basePitch: Int, steps: Int) -> Int {
        guard scaleCount > 0 else { return basePitch + steps }

        // Find current scale position
        let baseDegree = (basePitch - rootSemitone) % 12
        var currentIndex = 0
        withUnsafePointer(to: &scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                var minDist = 12
                for i in 0..<scaleCount {
                    let dist = abs(((baseDegree - p[i]) % 12 + 12) % 12)
                    if dist < minDist {
                        minDist = dist
                        currentIndex = i
                    }
                }
            }
        }

        // Move by steps
        let baseOctave = basePitch / 12
        let newIndex = ((currentIndex + steps) % scaleCount + scaleCount) % scaleCount
        let octaveShift = (currentIndex + steps) / scaleCount - (currentIndex + steps < 0 ? 1 : 0)

        var newInterval = 0
        withUnsafePointer(to: &scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                newInterval = p[newIndex]
            }
        }

        let result = (baseOctave + octaveShift) * 12 + rootSemitone + newInterval
        return max(0, min(127, result))
    }

    /// Snap to the nearest scale degree.
    private func nearestScaleDegree(to pitch: Int) -> Int {
        guard scaleCount > 0 else { return pitch }

        let octave = pitch / 12
        let noteInOctave = ((pitch % 12) + 12) % 12

        var bestPitch = pitch
        var bestDist = 12

        withUnsafePointer(to: scaleIntervals) { ptr in
            ptr.withMemoryRebound(to: Int.self, capacity: 12) { p in
                for i in 0..<scaleCount {
                    let scaleDeg = (p[i] + rootSemitone) % 12
                    let dist = min(abs(noteInOctave - scaleDeg), 12 - abs(noteInOctave - scaleDeg))
                    if dist < bestDist {
                        bestDist = dist
                        bestPitch = octave * 12 + scaleDeg
                    }
                }
            }
        }

        return max(0, min(127, bestPitch))
    }

    // MARK: - Duration

    /// Draw a note duration based on subdivision and density.
    /// Higher density → shorter notes (more room for others).
    private mutating func drawDuration(subdivisionDuration: Double, density: Double) -> Double {
        let baseDuration = subdivisionDuration * (0.3 + (1.0 - density) * 0.6)
        let variation = xorshiftUnit() * 0.3 * baseDuration
        return max(0.02, baseDuration + variation)
    }

    // MARK: - Drift

    /// Advance random walks on all drift dimensions.
    private mutating func advanceDrift() {
        let drift = driftParam

        // Scale step size by drift parameter
        let step = drift * 0.3

        centerPitchOffset += xorshiftNorm() * step * 2.0
        centerPitchOffset *= 0.995
        centerPitchOffset = max(-12, min(12, centerPitchOffset))

        focusModulation += xorshiftNorm() * step * 0.15
        focusModulation *= 0.995
        focusModulation = max(-0.3, min(0.3, focusModulation))

        densityModulation += xorshiftNorm() * step * 0.1
        densityModulation *= 0.995
        densityModulation = max(-0.2, min(0.2, densityModulation))

        velocityOffset += xorshiftNorm() * step * 0.2
        velocityOffset *= 0.99
        velocityOffset = max(-0.3, min(0.3, velocityOffset))

        subdivisionJitter += xorshiftNorm() * step * 0.05
        subdivisionJitter *= 0.99
        subdivisionJitter = max(-0.1, min(0.1, subdivisionJitter))
    }

    // MARK: - Note Tracking

    /// Track an active note for auto note-off.
    private mutating func trackNote(pitch: Int, durationSamples: Int) {
        // Find a free slot or steal the oldest
        withUnsafeMutablePointer(to: &activeNotes) { notesPtr in
            notesPtr.withMemoryRebound(to: Int.self, capacity: 8) { notes in
                withUnsafeMutablePointer(to: &activeNoteTimers) { timersPtr in
                    timersPtr.withMemoryRebound(to: Int.self, capacity: 8) { timers in
                        // Find a free slot
                        for i in 0..<8 {
                            if notes[i] == -1 {
                                notes[i] = pitch
                                timers[i] = durationSamples
                                return
                            }
                        }
                        // Steal slot 0 if no free
                        notes[0] = pitch
                        timers[0] = durationSamples
                    }
                }
            }
        }
    }

    /// Decrement note timers and fire note-offs.
    private mutating func decrementNoteTimers(sampleCount: Int, eventCallback: (Int, Double) -> Void) {
        withUnsafeMutablePointer(to: &activeNotes) { notesPtr in
            notesPtr.withMemoryRebound(to: Int.self, capacity: 8) { notes in
                withUnsafeMutablePointer(to: &activeNoteTimers) { timersPtr in
                    timersPtr.withMemoryRebound(to: Int.self, capacity: 8) { timers in
                        for i in 0..<8 {
                            guard notes[i] >= 0 else { continue }
                            timers[i] -= sampleCount
                            if timers[i] <= 0 {
                                // Note-off is signaled by velocity 0
                                // Actually, the voice manager handles note-off separately
                                // For SPORE SEQ, notes auto-release via voice envelope
                                notes[i] = -1
                                timers[i] = 0
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - RNG

    private mutating func xorshiftUnit() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(noiseState) / Double(UInt32.max)
    }

    private mutating func xorshiftNorm() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
    }

    private mutating func gaussianRandom() -> Double {
        let u1 = max(1e-10, xorshiftUnit())
        let u2 = xorshiftUnit()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}
