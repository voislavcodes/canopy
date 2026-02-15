import Foundation

/// Quantizes captured MIDI events to the step grid and musical scale.
/// Stateless service — all methods are static.
enum CaptureQuantizer {
    /// Quantize captured events into NoteEvents suitable for a NoteSequence.
    ///
    /// - Parameters:
    ///   - events: Raw captured events (normalized to 0..<lengthInBeats).
    ///   - strength: Quantize strength (0.0 = raw timing, 1.0 = snap to grid).
    ///   - key: Musical key for pitch quantization.
    ///   - lengthInBeats: Loop length for grid calculation.
    /// - Returns: Quantized and deduplicated NoteEvents.
    static func quantize(
        events: [MIDIBufferEvent],
        strength: Double,
        key: MusicalKey,
        lengthInBeats: Double
    ) -> [NoteEvent] {
        let grid = NoteSequence.stepDuration
        let clampedStrength = max(0, min(1, strength))

        var result = events.map { event -> NoteEvent in
            // Timing quantization: interpolate between raw and nearest grid snap
            let nearestGrid = round(event.startBeat / grid) * grid
            let quantizedStart = event.startBeat + (nearestGrid - event.startBeat) * clampedStrength

            // Clamp start to valid range
            let safeStart = max(0, min(lengthInBeats - grid, quantizedStart))

            // Duration quantization: snap to grid multiples at same strength
            let rawDuration = max(grid, event.durationBeats)
            let nearestDurationGrid = max(grid, round(rawDuration / grid) * grid)
            let quantizedDuration = rawDuration + (nearestDurationGrid - rawDuration) * clampedStrength

            // Clamp duration to not exceed loop end
            let safeDuration = min(quantizedDuration, lengthInBeats - safeStart)

            // Pitch: always snap to scale
            let quantizedPitch = key.quantize(event.pitch)

            return NoteEvent(
                pitch: quantizedPitch,
                velocity: event.velocity,
                startBeat: safeStart,
                duration: max(grid, safeDuration)
            )
        }

        // Deduplicate: if multiple notes land on the same pitch + grid step, keep highest velocity
        result = deduplicate(result, grid: grid)

        return result
    }

    /// Remove duplicate notes at the same pitch and grid position, keeping highest velocity.
    private static func deduplicate(_ events: [NoteEvent], grid: Double) -> [NoteEvent] {
        // Group by (pitch, grid step index)
        var best: [String: NoteEvent] = [:]
        for event in events {
            let stepIndex = Int(round(event.startBeat / grid))
            let key = "\(event.pitch)_\(stepIndex)"
            if let existing = best[key] {
                if event.velocity > existing.velocity {
                    best[key] = event
                }
            } else {
                best[key] = event
            }
        }
        return Array(best.values).sorted { $0.startBeat < $1.startBeat }
    }
}
