import Foundation

/// Orbital state passed to QuakeVoiceManager for physics-coupled timbral variation.
struct OrbitalState {
    var speedAtTrigger: Double = 0   // angular velocity at crossing moment
    var gravitationalStress: Double = 0  // cumulative gravitational pull
}

/// A single orbiting body in the ORBIT sequencer.
struct OrbitBody {
    var angle: Double = 0            // current angle in radians
    var angularVelocity: Double = 0  // radians per second (set from period)
    var baseAngularVelocity: Double = 0  // unperturbed velocity (for restore force)
    var mass: Double = 1.0           // relative mass for gravity calc
    var radius: Double = 1.0         // orbital radius (0–1, for visualization)
    var lastZoneIndex: Int = -1      // last zone crossed (prevents double-trigger)
    var voiceIndex: Int = 0          // which drum voice this body triggers
}

/// Gravitational rhythm sequencer running inside the render callback.
/// Bodies orbit a central point in polar coordinates. Triggers fire when
/// bodies cross beat-grid-anchored zone angles.
///
/// Physics runs at control rate (every 64 samples) for efficiency.
/// Trigger detection uses sub-sample interpolation for timing accuracy.
struct OrbitSequencer {
    // Configuration
    private var gravity: Double = 0.3       // inter-body attraction strength
    private var bodyCount: Int = 4          // active bodies (2–6)
    private var tension: Double = 0.0       // ratio complexity
    private var density: Double = 0.5       // zone count

    // Bodies (max 6)
    private var bodies: (OrbitBody, OrbitBody, OrbitBody, OrbitBody, OrbitBody, OrbitBody)

    // Transport
    private var bpm: Double = 120
    private var lengthInBeats: Double = 4
    private(set) var isPlaying: Bool = false
    private(set) var currentBeat: Double = 0

    // Physics timing
    private let controlRate = 64            // physics update every N samples
    private var controlCounter: Int = 0
    private var sampleCounter: Int64 = 0

    // Zone angles (computed from density, up to 16 zones)
    private var zoneCount: Int = 4
    private var zoneAngles: (Double, Double, Double, Double, Double, Double, Double, Double,
                             Double, Double, Double, Double, Double, Double, Double, Double)

    // Body angles pointer for UI polling
    var bodyAngles: (Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0)

    /// GM MIDI pitches for body→voice mapping.
    static let bodyPitches = [36, 38, 42, 46, 41, 43]  // KICK, SNARE, C.HAT, O.HAT, TOM_L, TOM_H

    init() {
        bodies = (
            OrbitBody(angle: 0, voiceIndex: 0),
            OrbitBody(angle: 0, voiceIndex: 1),
            OrbitBody(angle: 0, voiceIndex: 2),
            OrbitBody(angle: 0, voiceIndex: 3),
            OrbitBody(angle: 0, voiceIndex: 4),
            OrbitBody(angle: 0, voiceIndex: 5)
        )
        zoneAngles = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        recalculateOrbits()
        recalculateZones()
    }

    // MARK: - Configuration

    mutating func configure(gravity: Double, bodyCount: Int, tension: Double, density: Double) {
        self.gravity = gravity
        self.bodyCount = min(6, max(2, bodyCount))
        self.tension = tension
        self.density = density
        recalculateOrbits()
        recalculateZones()
    }

    // MARK: - Transport

    mutating func start(bpm: Double, lengthInBeats: Double) {
        self.bpm = bpm
        self.lengthInBeats = lengthInBeats
        self.isPlaying = true
        self.sampleCounter = 0
        self.controlCounter = 0
        self.currentBeat = 0

        // Reset body angles to starting positions
        withUnsafeMutablePointer(to: &bodies) { ptr in
            ptr.withMemoryRebound(to: OrbitBody.self, capacity: 6) { p in
                for i in 0..<6 {
                    p[i].angle = Double(i) * .pi * 2.0 / Double(max(2, bodyCount))
                    p[i].lastZoneIndex = -1
                }
            }
        }
        recalculateOrbits()
    }

    mutating func stop() {
        isPlaying = false
    }

    mutating func setBPM(_ bpm: Double) {
        self.bpm = bpm
        recalculateOrbits()
    }

    // MARK: - Per-Sample Tick

    /// Called per-sample from the render callback.
    /// Advances physics at control rate and fires triggers via the receiver.
    mutating func tick<R: NoteReceiver>(globalSample: Int64, sampleRate: Double, receiver: inout R) {
        guard isPlaying else { return }

        // Update current beat from sample position
        let beatsPerSecond = bpm / 60.0
        let samplesPerBeat = sampleRate / beatsPerSecond
        currentBeat = Double(sampleCounter).truncatingRemainder(dividingBy: lengthInBeats * samplesPerBeat) / samplesPerBeat

        controlCounter += 1

        if controlCounter >= controlRate {
            controlCounter = 0

            let dt = Double(controlRate) / sampleRate

            // Run physics and check triggers
            advancePhysics(dt: dt, sampleRate: sampleRate, receiver: &receiver)

            // Update UI-visible angles
            bodyAngles.0 = Float(bodies.0.angle)
            bodyAngles.1 = Float(bodies.1.angle)
            bodyAngles.2 = Float(bodies.2.angle)
            bodyAngles.3 = Float(bodies.3.angle)
            bodyAngles.4 = Float(bodies.4.angle)
            bodyAngles.5 = Float(bodies.5.angle)
        }

        sampleCounter += 1
    }

    /// Tick variant for QuakeVoiceManager with orbital coupling.
    mutating func tickQuake(globalSample: Int64, sampleRate: Double, receiver: inout QuakeVoiceManager) {
        guard isPlaying else { return }

        let beatsPerSecond = bpm / 60.0
        let samplesPerBeat = sampleRate / beatsPerSecond
        currentBeat = Double(sampleCounter).truncatingRemainder(dividingBy: lengthInBeats * samplesPerBeat) / samplesPerBeat

        controlCounter += 1

        if controlCounter >= controlRate {
            controlCounter = 0

            let dt = Double(controlRate) / sampleRate
            advancePhysicsQuake(dt: dt, sampleRate: sampleRate, receiver: &receiver)

            bodyAngles.0 = Float(bodies.0.angle)
            bodyAngles.1 = Float(bodies.1.angle)
            bodyAngles.2 = Float(bodies.2.angle)
            bodyAngles.3 = Float(bodies.3.angle)
            bodyAngles.4 = Float(bodies.4.angle)
            bodyAngles.5 = Float(bodies.5.angle)
        }

        sampleCounter += 1
    }

    // MARK: - Physics Engine

    private mutating func advancePhysics<R: NoteReceiver>(dt: Double, sampleRate: Double, receiver: inout R) {
        // Capture zone data before exclusive access to bodies
        let count = bodyCount
        let zc = zoneCount
        var localZones = zoneAngles

        withUnsafeMutablePointer(to: &bodies) { ptr in
            ptr.withMemoryRebound(to: OrbitBody.self, capacity: 6) { p in

                // Inter-body gravity
                if gravity > 0.01 {
                    let gStrength = gravity * 0.5
                    for i in 0..<count {
                        for j in (i+1)..<count {
                            var dAngle = p[j].angle - p[i].angle
                            while dAngle > .pi { dAngle -= 2 * .pi }
                            while dAngle < -.pi { dAngle += 2 * .pi }

                            let dist = max(0.1, abs(dAngle))
                            let forceMag = gStrength * p[i].mass * p[j].mass / (dist * dist)
                            let sign = dAngle > 0 ? 1.0 : -1.0

                            p[i].angularVelocity += sign * forceMag * dt / p[i].mass
                            p[j].angularVelocity -= sign * forceMag * dt / p[j].mass
                        }
                    }
                }

                // Central restoring force (keeps orbits stable)
                for i in 0..<count {
                    let deviation = p[i].angularVelocity - p[i].baseAngularVelocity
                    p[i].angularVelocity -= deviation * 0.02
                }

                // Advance angles and check zone crossings
                withUnsafeMutablePointer(to: &localZones) { zPtr in
                    zPtr.withMemoryRebound(to: Double.self, capacity: 16) { zones in
                        for i in 0..<count {
                            let prevAngle = p[i].angle
                            p[i].angle += p[i].angularVelocity * dt

                            while p[i].angle < 0 { p[i].angle += 2 * .pi }
                            while p[i].angle >= 2 * .pi { p[i].angle -= 2 * .pi }

                            // Inline zone crossing check
                            for z in 0..<zc {
                                let zoneAngle = zones[z]
                                if OrbitSequencer.crossedZone(prev: prevAngle, current: p[i].angle, zone: zoneAngle) {
                                    if p[i].lastZoneIndex != z {
                                        p[i].lastZoneIndex = z
                                        let speedRatio = abs(p[i].angularVelocity) / max(0.01, abs(p[i].baseAngularVelocity))
                                        let vel = min(1.0, max(0.3, 0.5 + (speedRatio - 1.0) * 0.5))
                                        let pitch = OrbitSequencer.bodyPitches[p[i].voiceIndex]
                                        receiver.noteOn(pitch: pitch, velocity: vel, frequency: 0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private mutating func advancePhysicsQuake(dt: Double, sampleRate: Double, receiver: inout QuakeVoiceManager) {
        let count = bodyCount
        let zc = zoneCount
        var localZones = zoneAngles

        withUnsafeMutablePointer(to: &bodies) { ptr in
            ptr.withMemoryRebound(to: OrbitBody.self, capacity: 6) { p in

                // Inter-body gravity
                if gravity > 0.01 {
                    let gStrength = gravity * 0.5
                    for i in 0..<count {
                        for j in (i+1)..<count {
                            var dAngle = p[j].angle - p[i].angle
                            while dAngle > .pi { dAngle -= 2 * .pi }
                            while dAngle < -.pi { dAngle += 2 * .pi }

                            let dist = max(0.1, abs(dAngle))
                            let forceMag = gStrength * p[i].mass * p[j].mass / (dist * dist)
                            let sign = dAngle > 0 ? 1.0 : -1.0

                            p[i].angularVelocity += sign * forceMag * dt / p[i].mass
                            p[j].angularVelocity -= sign * forceMag * dt / p[j].mass
                        }
                    }
                }

                // Central restoring force
                for i in 0..<count {
                    let deviation = p[i].angularVelocity - p[i].baseAngularVelocity
                    p[i].angularVelocity -= deviation * 0.02
                }

                // Advance and check crossings with orbital coupling
                withUnsafeMutablePointer(to: &localZones) { zPtr in
                    zPtr.withMemoryRebound(to: Double.self, capacity: 16) { zones in
                        for i in 0..<count {
                            let prevAngle = p[i].angle
                            p[i].angle += p[i].angularVelocity * dt

                            while p[i].angle < 0 { p[i].angle += 2 * .pi }
                            while p[i].angle >= 2 * .pi { p[i].angle -= 2 * .pi }

                            // Inline zone crossing check with orbital state
                            for z in 0..<zc {
                                let zoneAngle = zones[z]
                                if OrbitSequencer.crossedZone(prev: prevAngle, current: p[i].angle, zone: zoneAngle) {
                                    if p[i].lastZoneIndex != z {
                                        p[i].lastZoneIndex = z
                                        let speedRatio = abs(p[i].angularVelocity) / max(0.01, abs(p[i].baseAngularVelocity))
                                        let vel = min(1.0, max(0.3, 0.5 + (speedRatio - 1.0) * 0.5))
                                        let orbitalSpeed = speedRatio
                                        let orbitalStress = abs(p[i].angularVelocity - p[i].baseAngularVelocity) / max(0.01, abs(p[i].baseAngularVelocity))
                                        receiver.triggerWithOrbitalState(
                                            voiceIndex: p[i].voiceIndex,
                                            velocity: vel,
                                            orbitalSpeed: orbitalSpeed,
                                            orbitalStress: min(1.0, orbitalStress)
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Check if angle crossed a zone boundary between prev and current.
    static func crossedZone(prev: Double, current: Double, zone: Double) -> Bool {
        // Handle wrap-around at 2*pi boundary
        if abs(current - prev) > .pi {
            // Wrapped around — check both segments
            if prev < zone && zone <= 2 * .pi { return true }
            if 0 <= zone && zone < current { return true }
            return false
        }

        // Normal case
        let lo = min(prev, current)
        let hi = max(prev, current)
        return lo < zone && zone <= hi
    }

    // MARK: - Orbit Calculation

    private mutating func recalculateOrbits() {
        let beatsPerSecond = bpm / 60.0
        let barsPerSecond = beatsPerSecond / 4.0  // assuming 4/4

        // Simple period ratios (tension = 0)
        let simpleRatios: [Double] = [1, 2, 4, 3, 1.5, 2.5]
        // Complex period ratios (tension = 1)
        let complexRatios: [Double] = [1, 1.41421356, 1.61803399, 1.5 + 0.01, 1.66667, 2.71828]

        withUnsafeMutablePointer(to: &bodies) { ptr in
            ptr.withMemoryRebound(to: OrbitBody.self, capacity: 6) { p in
                for i in 0..<6 {
                    let ratio = simpleRatios[i] * (1.0 - tension) + complexRatios[i] * tension
                    // Angular velocity: one orbit = 2*pi, scaled by ratio and BPM
                    let orbitsPerSecond = barsPerSecond / ratio
                    p[i].baseAngularVelocity = orbitsPerSecond * 2.0 * .pi
                    p[i].angularVelocity = p[i].baseAngularVelocity
                    p[i].radius = Double(i + 1) / 7.0  // evenly spaced orbits
                    p[i].mass = 1.0 + Double(i) * 0.2   // heavier bodies = outer orbits
                }
            }
        }
    }

    private mutating func recalculateZones() {
        // Map density 0–1 to zone count: 0→1, 0.25→2, 0.5→4, 0.75→8, 1.0→16
        if density < 0.125 {
            zoneCount = 1
        } else if density < 0.375 {
            zoneCount = 2
        } else if density < 0.625 {
            zoneCount = 4
        } else if density < 0.875 {
            zoneCount = 8
        } else {
            zoneCount = 16
        }

        // Distribute zones evenly around the circle
        withUnsafeMutablePointer(to: &zoneAngles) { ptr in
            ptr.withMemoryRebound(to: Double.self, capacity: 16) { p in
                for i in 0..<16 {
                    if i < zoneCount {
                        p[i] = Double(i) * 2.0 * .pi / Double(zoneCount)
                    } else {
                        p[i] = -1  // inactive
                    }
                }
            }
        }
    }
}
