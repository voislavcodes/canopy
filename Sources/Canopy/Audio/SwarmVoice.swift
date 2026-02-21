import Foundation

/// Per-voice DSP for the SWARM engine.
/// 64 sine partials as autonomous agents in frequency space, governed by physics:
/// gravity (harmonic attraction), repulsion (spacing), flocking (group motion),
/// turbulence (random perturbation). The timbre IS the emergent behaviour.
///
/// CRITICAL: All partial state stored as 64-element tuples, NOT arrays.
/// Loop access via withUnsafeMutablePointer + withMemoryRebound.
/// Zero heap, zero ARC, audio-thread safe.
struct SwarmVoice {
    static let partialCount = 64
    static let controlBlockSize = 64 // Physics tick every 64 samples (~750Hz at 48kHz)

    // MARK: - Partial State (inline tuples — NO heap, NO CoW)

    var positions: (Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float,
                    Float, Float, Float, Float, Float, Float, Float, Float)

    var velocities: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)

    var amplitudes: (Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float,
                     Float, Float, Float, Float, Float, Float, Float, Float)

    var phases: (Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float,
                 Float, Float, Float, Float, Float, Float, Float, Float)

    var noiseStates: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
                      UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)

    // MARK: - Smoothed Controls (Rule 5)

    var gravitySmooth: Float = 0.5
    var energySmooth: Float = 0.3
    var flockSmooth: Float = 0.2
    var scatterSmooth: Float = 0.3

    // MARK: - Envelope (Rule 3: exponential)

    var envValue: Float = 0
    var envStage: Int = 0       // 0=idle, 1=attack, 2=sustain, 3=release
    var envAttackRate: Float = 0
    var envReleaseRate: Float = 0

    // MARK: - Voice State

    var isActive: Bool = false
    var isReleasing: Bool = false
    var envelopeLevel: Float = 0
    var noteFrequency: Float = 440
    var currentFrequency: Float = 440
    var targetFrequency: Float = 440
    var noteVelocity: Float = 0
    var warmth: Float = 0.3
    var physicsSampleCounter: Int = 0

    // Steal-fade (Rule 7)
    private var pendingPitch: Int = -1
    private var pendingVelocity: Float = 0
    private var stealFadeRate: Float = 0
    private var cachedSampleRate: Float = 48000

    // Base noise seed for this voice (set by manager for decorrelation)
    var noiseSeedBase: UInt32 = 12345

    // WARM analog physics state (seeded per-voice by manager)
    var warmState: WarmVoiceState = WarmVoiceState()

    // Imprint amplitude weights: scales bloom target per-partial so the
    // spectral fingerprint persists as physics operates. 1.0 = full bloom,
    // lower values suppress that partial. Set during beginNote when imprint active.
    var useImprintWeights: Bool = false

    /// Cached imprint positions for steal-fade retrigger. The UnsafePointer from
    /// triggerVoiceAt goes out of scope before advanceEnvelope completes the fade.
    var pendingImprintPos: (Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float,
                            Float, Float, Float, Float, Float, Float, Float, Float)?

    /// Cached imprint amplitudes for steal-fade retrigger.
    var pendingImprintAmps: (Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float)?
    var imprintWeights: (Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float)

    // MARK: - Init

    init() {
        let z: Float = 0
        let w: Float = 1
        positions = (z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                     z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                     z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                     z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z)
        imprintWeights = (w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w,
                          w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w,
                          w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w,
                          w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w)
        velocities = (z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z)
        amplitudes = (z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                      z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z)
        phases = (z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                  z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                  z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z,
                  z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z)
        let nz: UInt32 = 0
        noiseStates = (nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz,
                       nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz,
                       nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz,
                       nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz, nz)
    }

    // MARK: - Note Control

    /// Trigger a note. If already active, enter 5ms steal-fade (Rule 7).
    /// - Parameters:
    ///   - imprintPositions: Optional 64 frequency ratios from spectral peaks.
    ///   - imprintAmplitudes: Optional 64 peak amplitudes.
    mutating func trigger(pitch: Int, velocity: Float,
                          gravity: Float, energy: Float, flock: Float, scatter: Float,
                          sampleRate: Float,
                          imprintPositions: UnsafePointer<Float>? = nil,
                          imprintAmplitudes: UnsafePointer<Float>? = nil) {
        if isActive && envValue > 0.001 {
            pendingPitch = pitch
            pendingVelocity = velocity
            cachedSampleRate = sampleRate
            stealFadeRate = 1.0 / max(1, 0.005 * sampleRate)
            envStage = 4 // steal-fade
            // Cache imprint data so it survives the steal-fade gap.
            if let posPtr = imprintPositions, let ampPtr = imprintAmplitudes {
                pendingImprintPos = posPtr.withMemoryRebound(to: (Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float,
                                                                  Float, Float, Float, Float, Float, Float, Float, Float).self,
                                                             capacity: 1) { $0.pointee }
                pendingImprintAmps = ampPtr.withMemoryRebound(to: (Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float,
                                                                   Float, Float, Float, Float, Float, Float, Float, Float).self,
                                                              capacity: 1) { $0.pointee }
            } else {
                pendingImprintPos = nil
                pendingImprintAmps = nil
            }
            return
        }
        pendingImprintPos = nil
        pendingImprintAmps = nil
        beginNote(pitch: pitch, velocity: velocity, gravity: gravity,
                  energy: energy, flock: flock, scatter: scatter, sampleRate: sampleRate,
                  imprintPositions: imprintPositions, imprintAmplitudes: imprintAmplitudes)
    }

    private mutating func beginNote(pitch: Int, velocity: Float,
                                     gravity: Float, energy: Float, flock: Float, scatter: Float,
                                     sampleRate: Float,
                                     imprintPositions: UnsafePointer<Float>? = nil,
                                     imprintAmplitudes: UnsafePointer<Float>? = nil) {
        isActive = true
        isReleasing = false
        noteVelocity = velocity
        noteFrequency = 440.0 * powf(2.0, Float(pitch - 69) / 12.0)
        targetFrequency = noteFrequency
        currentFrequency = noteFrequency
        cachedSampleRate = sampleRate

        // Envelope (Rule 3: exponential approach)
        envStage = 1
        envValue = 0.001 // near-zero, not zero (avoids log(0))
        envAttackRate = 1.0 / max(1.0, 0.01 * sampleRate) // 10ms attack
        envReleaseRate = 1.0 / max(1.0, 1.0 * sampleRate) // 1s release

        pendingPitch = -1
        physicsSampleCounter = 0

        // Derive scatter amount from Energy and Scatter
        let triggerScatter = energy * 1.5
        let range = 0.12 + scatter * 0.88
        let hasImprint = imprintPositions != nil && imprintAmplitudes != nil
        useImprintWeights = hasImprint

        // Initialize 64 partials via pointer rebind
        withUnsafeMutablePointer(to: &positions) { posPtr in
            posPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { pos in
                withUnsafeMutablePointer(to: &velocities) { velPtr in
                    velPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { vel in
                        withUnsafeMutablePointer(to: &amplitudes) { ampPtr in
                            ampPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { amp in
                                withUnsafeMutablePointer(to: &phases) { phPtr in
                                    phPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { ph in
                                        withUnsafeMutablePointer(to: &noiseStates) { nsPtr in
                                            nsPtr.withMemoryRebound(to: UInt32.self, capacity: Self.partialCount) { ns in
                                                withUnsafeMutablePointer(to: &imprintWeights) { iwPtr in
                                                    iwPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { iw in
                                                        for i in 0..<Self.partialCount {
                                                            // Unique noise seed per partial (Rule 10)
                                                            ns[i] = noiseSeedBase &+ UInt32(i) &* 2654435761

                                                            if hasImprint {
                                                                // IMPRINT: use spectral peak positions and amplitudes
                                                                let imprintPos = imprintPositions![i]
                                                                pos[i] = imprintPos > 0 ? imprintPos : Float(i + 1)
                                                                amp[i] = imprintAmplitudes![i]
                                                                // Store weight so bloom target stays scaled
                                                                // by the spectral fingerprint permanently.
                                                                iw[i] = max(0.05, imprintAmplitudes![i])
                                                            } else {
                                                                let harmonicRatio = Float(i + 1)
                                                                let rangeScale = range * 0.75 + 0.25
                                                                let basePosition = harmonicRatio * rangeScale

                                                                // Scatter from harmonic position
                                                                ns[i] = ns[i] &* 1664525 &+ 1013904223
                                                                let rnd = Float(Int32(bitPattern: ns[i])) / Float(Int32.max)
                                                                let offset = rnd * triggerScatter * 2.0

                                                                pos[i] = max(0.5, basePosition + offset)
                                                                amp[i] = 1.0 / max(1.0, Float(i + 1))
                                                                iw[i] = 1.0
                                                            }

                                                            vel[i] = 0.0

                                                            // Rule 9: randomize initial phase (decorrelates partials)
                                                            ns[i] = ns[i] &* 1664525 &+ 1013904223
                                                            ph[i] = Float(ns[i] % 1000) / 1000.0
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Release: begin dissolution (gravity drops, turbulence rises).
    mutating func release(sampleRate: Float) {
        guard envStage != 0 else { return }
        isReleasing = true
        envStage = 3
        envReleaseRate = 1.0 / max(1.0, 1.0 * sampleRate)
    }

    /// Kill immediately.
    mutating func kill() {
        isActive = false
        isReleasing = false
        envStage = 0
        envValue = 0
        envelopeLevel = 0
        useImprintWeights = false
    }

    // MARK: - Render

    /// Render one stereo sample. Physics runs at control rate (every 64 samples).
    mutating func renderSample(
        gravity: Float, energy: Float, flock: Float, scatter: Float,
        sampleRate: Float
    ) -> (Float, Float) {
        guard isActive else { return (0, 0) }

        // Advance envelope
        advanceEnvelope()
        guard envValue > 0.0001 else {
            if envStage == 3 || envStage == 0 {
                isActive = false
                envelopeLevel = 0
            }
            return (0, 0)
        }
        envelopeLevel = envValue

        // Smooth controls per-sample (Rule 5)
        let smoothCoeff: Float = 0.001
        gravitySmooth += (gravity - gravitySmooth) * smoothCoeff
        energySmooth += (energy - energySmooth) * smoothCoeff
        flockSmooth += (flock - flockSmooth) * smoothCoeff
        scatterSmooth += (scatter - scatterSmooth) * smoothCoeff

        // Physics update at control rate
        physicsSampleCounter += 1
        if physicsSampleCounter >= Self.controlBlockSize {
            physicsSampleCounter = 0
            updatePhysics()
            // WARM pitch drift (control rate)
            let driftCents = WarmProcessor.computePitchOffset(&warmState, warm: warmth, sampleRate: sampleRate)
            warmState.cachedDriftMul = powf(2.0, driftCents / 1200.0)
        }

        // Glide
        currentFrequency += (targetFrequency - currentFrequency) * 0.001
        let driftedFreq = currentFrequency * warmState.cachedDriftMul

        // Sine bank + stereo output
        var outL: Float = 0
        var outR: Float = 0
        let stereoWidth = 0.1 + scatterSmooth * 0.5
        let nyquist = sampleRate * 0.49 // Rule 8

        withUnsafeMutablePointer(to: &phases) { phPtr in
            phPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { ph in
                withUnsafeMutablePointer(to: &positions) { posPtr in
                    posPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { pos in
                        withUnsafeMutablePointer(to: &amplitudes) { ampPtr in
                            ampPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { amp in
                                for i in 0..<Self.partialCount {
                                    let frequency = driftedFreq * pos[i]

                                    // Rule 8: skip partials outside audible range
                                    guard frequency > 20 && frequency < nyquist else { continue }

                                    // Rule 9: phase advance and wrap
                                    let phaseInc = frequency / sampleRate
                                    ph[i] += phaseInc
                                    ph[i] -= Float(Int(ph[i]))

                                    // Sine oscillator
                                    let sample = sinf(ph[i] * 2.0 * .pi) * amp[i]

                                    // Per-partial stereo position (from frequency ratio)
                                    let stereoPos = (pos[i] / 64.0) * 2.0 - 1.0
                                    let panL = 0.5 + stereoPos * stereoWidth * 0.5
                                    let panR = 0.5 - stereoPos * stereoWidth * 0.5

                                    outL += sample * panL
                                    outR += sample * panR
                                }
                            }
                        }
                    }
                }
            }
        }

        // Normalize (sqrt(64) ~= 8, with headroom)
        let norm: Float = 1.0 / 10.0
        outL *= norm
        outR *= norm

        // Envelope + velocity
        outL *= envValue * noteVelocity
        outR *= envValue * noteVelocity

        // Per-voice WARM analog physics
        (outL, outR) = WarmProcessor.processStereo(&warmState, sampleL: outL, sampleR: outR,
                                                    warm: warmth, sampleRate: sampleRate)

        return (outL, outR)
    }

    // MARK: - Envelope

    private mutating func advanceEnvelope() {
        switch envStage {
        case 1: // Attack (exponential approach)
            envValue += (1.0 - envValue) * envAttackRate
            if envValue >= 0.999 {
                envValue = 1.0
                envStage = 2
            }
        case 2: // Sustain
            break
        case 3: // Release (exponential decay)
            envValue *= (1.0 - envReleaseRate)
            if envValue < 0.0001 {
                envValue = 0
                envStage = 0
                isActive = false
            }
        case 4: // Steal-fade (Rule 7: 5ms)
            envValue -= stealFadeRate
            if envValue <= 0.001 {
                envValue = 0
                if pendingPitch >= 0 {
                    if var cachedPos = pendingImprintPos, var cachedAmps = pendingImprintAmps {
                        pendingImprintPos = nil
                        pendingImprintAmps = nil
                        withUnsafeMutablePointer(to: &cachedPos) { posPtr in
                            posPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { posP in
                                withUnsafeMutablePointer(to: &cachedAmps) { ampPtr in
                                    ampPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { ampP in
                                        beginNote(pitch: pendingPitch, velocity: pendingVelocity,
                                                  gravity: gravitySmooth, energy: energySmooth,
                                                  flock: flockSmooth, scatter: scatterSmooth,
                                                  sampleRate: cachedSampleRate,
                                                  imprintPositions: posP, imprintAmplitudes: ampP)
                                    }
                                }
                            }
                        }
                    } else {
                        beginNote(pitch: pendingPitch, velocity: pendingVelocity,
                                  gravity: gravitySmooth, energy: energySmooth,
                                  flock: flockSmooth, scatter: scatterSmooth,
                                  sampleRate: cachedSampleRate)
                    }
                } else {
                    envStage = 0
                    isActive = false
                }
            }
        default:
            break
        }
    }

    // MARK: - Physics

    /// Update positions, velocities, and amplitudes of all 64 partials.
    /// Runs at control rate (~750Hz). N² loop for repulsion + flocking.
    /// All tuple arrays rebound to raw pointers — zero ARC inside.
    private mutating func updatePhysics() {
        // Derive physics params from 4 smoothed controls
        let attractionStrength = gravitySmooth * 3.0
        let bloom = 0.2 + gravitySmooth * 0.6
        let velocityDamping = 0.990 + gravitySmooth * 0.008

        let turbulence = energySmooth * 0.8
        let effectiveMass = 0.1 + (1.0 - energySmooth) * 4.9
        let releaseTurbBoost: Float = isReleasing ? energySmooth * 0.4 : 0.0
        let effectiveTurb = turbulence + releaseTurbBoost
        let releaseGravityMod: Float = isReleasing ? 0.3 : 1.0

        let flockAlignment = flockSmooth * 0.8
        let flockRadius = 2.0 + flockSmooth * 3.0
        let repulsionMod = 1.0 - flockSmooth * 0.3

        let repulsion = (0.1 + scatterSmooth * 0.8) * repulsionMod
        let ampFalloff = 1.0 - scatterSmooth * 0.6

        // Single pointer scope for ALL arrays
        let hasIW = useImprintWeights
        withUnsafeMutablePointer(to: &positions) { posPtr in
            posPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { pos in
                withUnsafeMutablePointer(to: &velocities) { velPtr in
                    velPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { vel in
                        withUnsafeMutablePointer(to: &amplitudes) { ampPtr in
                            ampPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { amp in
                                withUnsafeMutablePointer(to: &noiseStates) { nsPtr in
                                    nsPtr.withMemoryRebound(to: UInt32.self, capacity: Self.partialCount) { ns in
                                        withUnsafePointer(to: &imprintWeights) { iwPtr in
                                            iwPtr.withMemoryRebound(to: Float.self, capacity: Self.partialCount) { iw in
                                                for i in 0..<Self.partialCount {
                                                    let p = pos[i]
                                                    var netForce: Float = 0.0

                                                    // 1. GRAVITY — pull toward nearest harmonic integer
                                                    let nearestHarmonic = roundf(p)
                                                    let gravDistance = nearestHarmonic - p
                                                    netForce += gravDistance * attractionStrength * releaseGravityMod

                                                    // 2. REPULSION — push away from neighbours (N² loop)
                                                    for j in 0..<Self.partialCount {
                                                        guard j != i else { continue }
                                                        let diff = p - pos[j]
                                                        let dist = abs(diff) + 0.01 // Rule 2: singularity floor
                                                        if dist < 2.5 {
                                                            let direction: Float = diff > 0 ? 1.0 : -1.0
                                                            netForce += direction * repulsion * 0.1 / (dist * dist)
                                                        }
                                                    }

                                                    // 3. FLOCKING — align velocity with neighbours
                                                    var neighbourVelSum: Float = 0
                                                    var neighbourCount: Int = 0
                                                    for j in 0..<Self.partialCount {
                                                        guard j != i else { continue }
                                                        if abs(p - pos[j]) < flockRadius {
                                                            neighbourVelSum += vel[j]
                                                            neighbourCount += 1
                                                        }
                                                    }
                                                    if neighbourCount > 0 {
                                                        let avgVel = neighbourVelSum / Float(neighbourCount)
                                                        netForce += (avgVel - vel[i]) * flockAlignment
                                                    }

                                                    // 4. TURBULENCE — per-partial LCG noise (Rule 10)
                                                    ns[i] = ns[i] &* 1664525 &+ 1013904223
                                                    let noise = Float(Int32(bitPattern: ns[i])) / Float(Int32.max)
                                                    netForce += noise * effectiveTurb * 0.5

                                                    // 5. INTEGRATE — F/m = a
                                                    let acceleration = netForce / effectiveMass
                                                    vel[i] += acceleration
                                                    vel[i] *= velocityDamping // Rule 4: damping

                                                    // Velocity clamp (Rule 4)
                                                    vel[i] = max(-2.0, min(2.0, vel[i]))

                                                    pos[i] += vel[i]

                                                    // Position clamp (Rule 8)
                                                    pos[i] = max(0.25, min(80.0, pos[i]))

                                                    // 6. AMPLITUDE — bloom, blended with imprint weight
                                                    let naturalAmp = 1.0 / max(1.0, powf(p, ampFalloff))
                                                    let harmonicDist = abs(p - nearestHarmonic)
                                                    let proximityReward = max(0.0, 1.0 - harmonicDist * 4.0 * bloom)
                                                    let physicsAmp = naturalAmp * (1.0 - bloom + bloom * proximityReward)
                                                    // Imprint: interpolate between physics target and imprint
                                                    // weight so the spectral fingerprint can BOOST partials
                                                    // above their natural 1/n falloff, not just suppress.
                                                    // 60% imprint / 40% physics keeps the swarm alive while
                                                    // preserving the voice character.
                                                    let targetAmp: Float
                                                    if hasIW {
                                                        targetAmp = physicsAmp * 0.4 + iw[i] * 0.6
                                                    } else {
                                                        targetAmp = physicsAmp
                                                    }
                                                    amp[i] += (max(0.0, min(1.0, targetAmp)) - amp[i]) * 0.01
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
