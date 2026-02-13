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
    static func generate(steps: Int, pulses: Int, rotation: Int = 0) -> [Bool] {
        guard steps > 0 else { return [] }
        let pulses = max(0, min(pulses, steps))

        if pulses == 0 { return Array(repeating: false, count: steps) }
        if pulses == steps { return Array(repeating: true, count: steps) }

        // Bjorklund's algorithm
        var pattern = bjorklund(steps: steps, pulses: pulses)

        // Apply rotation
        if rotation != 0 {
            let r = ((rotation % steps) + steps) % steps
            let rotated = Array(pattern[r...]) + Array(pattern[..<r])
            pattern = rotated
        }

        return pattern
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
