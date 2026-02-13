import XCTest
@testable import Canopy

final class SequencerAlgorithmTests: XCTestCase {

    // MARK: - Xorshift64 PRNG

    func testXorshiftProducesDifferentValues() {
        var prng = Xorshift64(seed: 42)
        let a = prng.next()
        let b = prng.next()
        let c = prng.next()
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
    }

    func testXorshiftDoubleRange() {
        var prng = Xorshift64(seed: 123)
        for _ in 0..<100 {
            let val = prng.nextDouble()
            XCTAssertGreaterThanOrEqual(val, 0)
            XCTAssertLessThan(val, 1)
        }
    }

    func testXorshiftIntRange() {
        var prng = Xorshift64(seed: 456)
        for _ in 0..<100 {
            let val = prng.nextInt(in: 3...7)
            XCTAssertGreaterThanOrEqual(val, 3)
            XCTAssertLessThanOrEqual(val, 7)
        }
    }

    func testXorshiftDeterministic() {
        var prng1 = Xorshift64(seed: 999)
        var prng2 = Xorshift64(seed: 999)
        for _ in 0..<50 {
            XCTAssertEqual(prng1.next(), prng2.next())
        }
    }

    // MARK: - SequencerEvent Construction

    func testSequencerEventDefaults() {
        let event = SequencerEvent(pitch: 60, velocity: 0.8, startBeat: 0, endBeat: 1)
        XCTAssertEqual(event.probability, 1.0)
        XCTAssertEqual(event.ratchetCount, 1)
    }

    func testSequencerEventCustomFields() {
        let event = SequencerEvent(pitch: 60, velocity: 0.8, startBeat: 0, endBeat: 1,
                                   probability: 0.5, ratchetCount: 3)
        XCTAssertEqual(event.probability, 0.5)
        XCTAssertEqual(event.ratchetCount, 3)
    }

    // MARK: - Accumulator Config

    func testAccumulatorConfigDefaults() {
        let config = AccumulatorConfig()
        XCTAssertEqual(config.target, .pitch)
        XCTAssertEqual(config.amount, 1.0)
        XCTAssertEqual(config.limit, 12.0)
        XCTAssertEqual(config.mode, .clamp)
    }

    // MARK: - Mutation Config

    func testMutationConfigDefaults() {
        let config = MutationConfig()
        XCTAssertEqual(config.amount, 0.1)
        XCTAssertEqual(config.range, 1)
    }

    // MARK: - Playback Direction

    func testAllPlaybackDirections() {
        let cases = PlaybackDirection.allCases
        XCTAssertEqual(cases.count, 5)
        XCTAssertTrue(cases.contains(.forward))
        XCTAssertTrue(cases.contains(.reverse))
        XCTAssertTrue(cases.contains(.pingPong))
        XCTAssertTrue(cases.contains(.random))
        XCTAssertTrue(cases.contains(.brownian))
    }

    // MARK: - Accumulator Modes

    func testAllAccumulatorModes() {
        let modes = AccumulatorMode.allCases
        XCTAssertEqual(modes.count, 3)
        XCTAssertTrue(modes.contains(.clamp))
        XCTAssertTrue(modes.contains(.wrap))
        XCTAssertTrue(modes.contains(.pingPong))
    }

    func testAllAccumulatorTargets() {
        let targets = AccumulatorTarget.allCases
        XCTAssertEqual(targets.count, 3)
        XCTAssertTrue(targets.contains(.pitch))
        XCTAssertTrue(targets.contains(.velocity))
        XCTAssertTrue(targets.contains(.probability))
    }

    // MARK: - EuclideanConfig Codable

    func testEuclideanConfigRoundTrip() throws {
        let config = EuclideanConfig(pulses: 5, rotation: 2)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EuclideanConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - PitchRange Codable

    func testPitchRangeRoundTrip() throws {
        let range = PitchRange(low: 36, high: 84)
        let data = try JSONEncoder().encode(range)
        let decoded = try JSONDecoder().decode(PitchRange.self, from: data)
        XCTAssertEqual(range, decoded)
    }

    // MARK: - MutationConfig Codable

    func testMutationConfigRoundTrip() throws {
        let config = MutationConfig(amount: 0.3, range: 4)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MutationConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - AccumulatorConfig Codable

    func testAccumulatorConfigRoundTrip() throws {
        let config = AccumulatorConfig(target: .velocity, amount: 2.5, limit: 24.0, mode: .pingPong)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AccumulatorConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }
}
