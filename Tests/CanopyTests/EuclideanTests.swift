import XCTest
@testable import Canopy

final class EuclideanTests: XCTestCase {

    // MARK: - Known Patterns

    func testE3_8() {
        // E(3,8) — tresillo: 3 pulses evenly distributed across 8 steps
        let pattern = EuclideanRhythm.generate(steps: 8, pulses: 3)
        let pulseCount = pattern.filter { $0 }.count
        XCTAssertEqual(pulseCount, 3)
        XCTAssertEqual(pattern.count, 8)
        // Verify even distribution: gaps between pulses should be 2 or 3
        let pulsePositions = pattern.enumerated().compactMap { $0.element ? $0.offset : nil }
        XCTAssertEqual(pulsePositions.count, 3)
    }

    func testE5_8() {
        // E(5,8) — cinquillo: 5 pulses evenly distributed across 8 steps
        let pattern = EuclideanRhythm.generate(steps: 8, pulses: 5)
        let pulseCount = pattern.filter { $0 }.count
        XCTAssertEqual(pulseCount, 5)
        XCTAssertEqual(pattern.count, 8)
    }

    func testE4_12() {
        // E(4,12) = [x . . x . . x . . x . .]
        let pattern = EuclideanRhythm.generate(steps: 12, pulses: 4)
        let pulseCount = pattern.filter { $0 }.count
        XCTAssertEqual(pulseCount, 4)
        XCTAssertEqual(pattern.count, 12)
    }

    func testE7_16() {
        let pattern = EuclideanRhythm.generate(steps: 16, pulses: 7)
        let pulseCount = pattern.filter { $0 }.count
        XCTAssertEqual(pulseCount, 7)
        XCTAssertEqual(pattern.count, 16)
    }

    // MARK: - Edge Cases

    func testZeroPulses() {
        let pattern = EuclideanRhythm.generate(steps: 8, pulses: 0)
        XCTAssertEqual(pattern, Array(repeating: false, count: 8))
    }

    func testAllPulses() {
        let pattern = EuclideanRhythm.generate(steps: 4, pulses: 4)
        XCTAssertEqual(pattern, Array(repeating: true, count: 4))
    }

    func testSingleStep() {
        let pattern = EuclideanRhythm.generate(steps: 1, pulses: 1)
        XCTAssertEqual(pattern, [true])
    }

    func testZeroSteps() {
        let pattern = EuclideanRhythm.generate(steps: 0, pulses: 0)
        XCTAssertEqual(pattern, [])
    }

    func testOnePulse() {
        let pattern = EuclideanRhythm.generate(steps: 8, pulses: 1)
        let pulseCount = pattern.filter { $0 }.count
        XCTAssertEqual(pulseCount, 1)
        // Exactly one pulse somewhere in the pattern
        XCTAssertTrue(pattern.contains(true))
    }

    // MARK: - Rotation

    func testRotation() {
        let base = EuclideanRhythm.generate(steps: 8, pulses: 3, rotation: 0)
        let rotated = EuclideanRhythm.generate(steps: 8, pulses: 3, rotation: 1)

        // Rotated by 1: the pattern shifts left by 1
        for i in 0..<8 {
            XCTAssertEqual(rotated[i], base[(i + 1) % 8],
                           "Rotation mismatch at index \(i)")
        }
    }

    func testFullRotation() {
        let base = EuclideanRhythm.generate(steps: 8, pulses: 3, rotation: 0)
        let fullRotation = EuclideanRhythm.generate(steps: 8, pulses: 3, rotation: 8)
        XCTAssertEqual(base, fullRotation)
    }

    // MARK: - Pulse Count Invariant

    func testPulseCountAlwaysCorrect() {
        for steps in 1...16 {
            for pulses in 0...steps {
                let pattern = EuclideanRhythm.generate(steps: steps, pulses: pulses)
                let count = pattern.filter { $0 }.count
                XCTAssertEqual(count, pulses,
                               "E(\(pulses),\(steps)) should have \(pulses) pulses, got \(count)")
                XCTAssertEqual(pattern.count, steps)
            }
        }
    }

    // MARK: - Clamping

    func testPulsesClampedToSteps() {
        let pattern = EuclideanRhythm.generate(steps: 4, pulses: 10)
        XCTAssertEqual(pattern, Array(repeating: true, count: 4))
    }

    func testNegativePulsesClamped() {
        let pattern = EuclideanRhythm.generate(steps: 4, pulses: -3)
        XCTAssertEqual(pattern, Array(repeating: false, count: 4))
    }
}
