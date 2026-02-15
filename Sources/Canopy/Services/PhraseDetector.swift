import Foundation

/// Extracts the most musically relevant phrase from a capture buffer.
/// Stateless service — all methods are static.
enum PhraseDetector {
    /// Compute the appropriate sequence length from the buffer's content span.
    /// Returns a step-aligned length (multiple of 0.25) clamped to 1–maxBeats.
    static func spanLength(from buffer: MIDICaptureBuffer, maxBeats: Double) -> Double {
        let events = buffer.events
        guard !events.isEmpty else { return 0 }

        let sd = NoteSequence.stepDuration
        let minBeats = sd  // at least 1 step

        let earliest = events.map(\.startBeat).min()!
        let latest = events.map { $0.startBeat + $0.durationBeats }.max()!
        let span = latest - earliest

        // Round up to nearest step boundary
        let steps = max(1, Int(ceil(span / sd)))
        let aligned = Double(steps) * sd

        return max(minBeats, min(maxBeats, aligned))
    }

    /// Extract a phrase of `lengthInBeats` from the buffer.
    /// Takes the most recent window; if sparse, scans backward for the densest window.
    static func extractPhrase(from buffer: MIDICaptureBuffer, lengthInBeats: Double) -> [MIDIBufferEvent] {
        let events = buffer.events
        guard !events.isEmpty, lengthInBeats > 0 else { return [] }

        // Find the most recent event's end time
        let latestBeat = events.map { $0.startBeat + $0.durationBeats }.max() ?? 0

        // Try the most recent window
        let recentWindowStart = latestBeat - lengthInBeats
        let recentEvents = events.filter { $0.startBeat >= recentWindowStart }

        if recentEvents.count >= 2 {
            return normalize(recentEvents, windowStart: recentWindowStart, lengthInBeats: lengthInBeats)
        }

        // Sparse recent window — scan backward for densest window (up to 4x lookback)
        let maxLookback = lengthInBeats * 4
        let earliestBeat = events.map(\.startBeat).min() ?? 0
        let scanStart = max(earliestBeat, latestBeat - maxLookback)

        var bestWindowStart = recentWindowStart
        var bestCount = recentEvents.count

        // Slide window backward in half-length increments
        var windowStart = recentWindowStart - lengthInBeats / 2
        while windowStart >= scanStart {
            let windowEnd = windowStart + lengthInBeats
            let count = events.filter { $0.startBeat >= windowStart && $0.startBeat < windowEnd }.count
            if count > bestCount {
                bestCount = count
                bestWindowStart = windowStart
            }
            windowStart -= lengthInBeats / 2
        }

        let bestEvents = events.filter {
            $0.startBeat >= bestWindowStart && $0.startBeat < bestWindowStart + lengthInBeats
        }

        return normalize(bestEvents, windowStart: bestWindowStart, lengthInBeats: lengthInBeats)
    }

    /// Normalize event start times to 0..<lengthInBeats and clamp durations.
    private static func normalize(_ events: [MIDIBufferEvent], windowStart: Double, lengthInBeats: Double) -> [MIDIBufferEvent] {
        events.map { event in
            let normalizedStart = event.startBeat - windowStart
            // Wrap to 0..<lengthInBeats
            let wrappedStart = normalizedStart.truncatingRemainder(dividingBy: lengthInBeats)
            let safeStart = wrappedStart < 0 ? wrappedStart + lengthInBeats : wrappedStart
            // Clamp duration so note doesn't exceed loop end
            let maxDuration = lengthInBeats - safeStart
            let clampedDuration = min(event.durationBeats, max(0.01, maxDuration))

            return MIDIBufferEvent(
                pitch: event.pitch,
                velocity: event.velocity,
                startBeat: safeStart,
                durationBeats: clampedDuration
            )
        }
    }
}
