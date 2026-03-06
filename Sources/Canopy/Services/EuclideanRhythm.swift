import Foundation

/// Generates Euclidean rhythms using Bjorklund's algorithm.
/// A Euclidean rhythm distributes `pulses` hits as evenly as possible across `steps` slots.
enum EuclideanRhythm {
    /// Generate a Euclidean rhythm pattern.
    /// - Parameters:
    ///   - steps: Total number of steps in the pattern (must be > 0)
    ///   - pulses: Number of active hits (clamped to 0...steps)
    ///   - rotation: Rotate the pattern by this many steps (wraps around)
    /// - Returns: Boolean array where `true` = hit, `false` = rest
    static func generate(steps: Int, pulses: Int, rotation: Int = 0, wobble: Double = 0) -> [Bool] {
        guard steps > 0 else { return [] }
        let pulses = max(0, min(pulses, steps))

        if pulses == 0 { return Array(repeating: false, count: steps) }
        if pulses == steps { return Array(repeating: true, count: steps) }

        // Bjorklund's algorithm (normalize so first hit is at index 0)
        var pattern = bjorklund(steps: steps, pulses: pulses)
        if let firstHit = pattern.firstIndex(of: true), firstHit > 0 {
            pattern = Array(pattern[firstHit...]) + Array(pattern[..<firstHit])
        }

        // Apply rotation
        if rotation != 0 {
            let r = ((rotation % steps) + steps) % steps
            let rotated = Array(pattern[r...]) + Array(pattern[..<r])
            pattern = rotated
        }

        // Apply wobble (perturb hit positions)
        if wobble > 0 {
            pattern = applyWobble(pattern, steps: steps, pulses: pulses, wobble: wobble)
        }

        return pattern
    }

    /// Perturb hit positions deterministically. Pulse count is always preserved.
    private static func applyWobble(_ pattern: [Bool], steps: Int, pulses: Int, wobble: Double) -> [Bool] {
        // Extract hit indices
        var hitIndices: [Int] = []
        for i in 0..<steps where pattern[i] {
            hitIndices.append(i)
        }
        guard hitIndices.count >= 2 else { return pattern }

        let averageGap = Double(steps) / Double(pulses)
        let maxShift = max(1, Int(averageGap / 2))

        // Compute desired new positions via deterministic hash
        var newPositions: [Int] = []
        for hit in hitIndices {
            // Deterministic hash: combine hit position with a prime mixer
            let hash = (hit &* 2654435761) ^ (hit &* 340573321)
            // Map to signed float in -1...1
            let normalized = Double((hash & 0xFFFF)) / 32768.0 - 1.0
            let offset = Int(round(normalized * wobble * Double(maxShift)))
            let shifted = ((hit + offset) % steps + steps) % steps
            newPositions.append(shifted)
        }

        // Resolve collisions: build result greedily, nudging to nearest empty step
        var occupied = Set<Int>()
        var result = [Bool](repeating: false, count: steps)

        for pos in newPositions {
            if !occupied.contains(pos) {
                result[pos] = true
                occupied.insert(pos)
            } else {
                // Find nearest empty step by spiraling outward
                var placed = false
                for offset in 1..<steps {
                    let right = (pos + offset) % steps
                    if !occupied.contains(right) {
                        result[right] = true
                        occupied.insert(right)
                        placed = true
                        break
                    }
                    let left = ((pos - offset) % steps + steps) % steps
                    if !occupied.contains(left) {
                        result[left] = true
                        occupied.insert(left)
                        placed = true
                        break
                    }
                }
                if !placed {
                    // Fallback: keep original (shouldn't happen when pulses < steps)
                    result[pos] = true
                }
            }
        }

        return result
    }

    private static func bjorklund(steps: Int, pulses: Int) -> [Bool] {
        var counts: [Int] = []
        var remainders: [Int] = []

        var divisor = steps - pulses
        remainders.append(pulses)
        var level = 0

        while true {
            counts.append(divisor / remainders[level])
            let newRemainder = divisor % remainders[level]
            remainders.append(newRemainder)
            divisor = remainders[level]
            level += 1
            if remainders[level] <= 1 { break }
        }

        counts.append(divisor)

        var pattern: [Bool] = []
        build(level: level, counts: counts, remainders: remainders, pattern: &pattern)
        return pattern
    }

    private static func build(level: Int, counts: [Int], remainders: [Int], pattern: inout [Bool]) {
        if level == -1 {
            pattern.append(false)
        } else if level == -2 {
            pattern.append(true)
        } else {
            for _ in 0..<counts[level] {
                build(level: level - 1, counts: counts, remainders: remainders, pattern: &pattern)
            }
            if remainders[level] != 0 {
                build(level: level - 2, counts: counts, remainders: remainders, pattern: &pattern)
            }
        }
    }
}
