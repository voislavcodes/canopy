import XCTest
@testable import Canopy

final class VolumeConversionTests: XCTestCase {
    // MARK: - linearToDb / dbToLinear round-trips

    func testLinearToDbRoundTrip() {
        let values: [Double] = [0.001, 0.01, 0.1, 0.25, 0.5, 0.7, 0.8, 1.0]
        for linear in values {
            let db = VolumeConversion.linearToDb(linear)
            let back = VolumeConversion.dbToLinear(db)
            XCTAssertEqual(back, linear, accuracy: 1e-10,
                           "Round-trip failed for linear=\(linear)")
        }
    }

    func testLinearToDbZero() {
        XCTAssertEqual(VolumeConversion.linearToDb(0), -.infinity)
    }

    func testDbToLinearBelowThreshold() {
        XCTAssertEqual(VolumeConversion.dbToLinear(-120), 0)
        XCTAssertEqual(VolumeConversion.dbToLinear(-200), 0)
        XCTAssertEqual(VolumeConversion.dbToLinear(-.infinity), 0)
    }

    func testLinearToDbUnity() {
        XCTAssertEqual(VolumeConversion.linearToDb(1.0), 0, accuracy: 1e-10)
    }

    // MARK: - faderToDb / dbToFader round-trips

    func testFaderToDbRoundTrip() {
        // Start above 0.05 since 0.05 → -60dB → 0.0 (boundary: -60dB maps to silence)
        let positions: [Double] = [0.1, 0.2, 0.4, 0.5, 0.6, 0.75]
        for pos in positions {
            let db = VolumeConversion.faderToDb(pos)
            let back = VolumeConversion.dbToFader(db)
            XCTAssertEqual(back, pos, accuracy: 1e-10,
                           "Round-trip failed for position=\(pos)")
        }
    }

    func testFaderDeadZone() {
        XCTAssertEqual(VolumeConversion.faderToDb(0), -.infinity)
        XCTAssertEqual(VolumeConversion.faderToDb(0.02), -.infinity)
        XCTAssertEqual(VolumeConversion.faderToDb(0.049), -.infinity)
    }

    func testFaderToDbUnity() {
        // Position 0.75 = 0dB
        XCTAssertEqual(VolumeConversion.faderToDb(0.75), 0, accuracy: 1e-10)
    }

    func testFaderToDbMax() {
        // Position 1.0 = 0dB (clamped in Phase 1)
        XCTAssertEqual(VolumeConversion.faderToDb(1.0), 0, accuracy: 1e-10)
    }

    func testDbToFaderSilence() {
        XCTAssertEqual(VolumeConversion.dbToFader(-.infinity), 0)
        XCTAssertEqual(VolumeConversion.dbToFader(-60), 0)
        XCTAssertEqual(VolumeConversion.dbToFader(-100), 0)
    }

    func testDbToFaderUnity() {
        XCTAssertEqual(VolumeConversion.dbToFader(0), 0.75, accuracy: 1e-10)
    }

    // MARK: - faderToLinear / linearToFader

    func testFaderToLinearUnity() {
        let linear = VolumeConversion.faderToLinear(0.75)
        XCTAssertEqual(linear, 1.0, accuracy: 1e-10)
    }

    func testLinearToFaderUnity() {
        let pos = VolumeConversion.linearToFader(1.0)
        XCTAssertEqual(pos, 0.75, accuracy: 1e-10)
    }

    func testFaderToLinearSilence() {
        XCTAssertEqual(VolumeConversion.faderToLinear(0), 0)
    }

    // MARK: - formatDb

    func testFormatDbSilence() {
        XCTAssertEqual(VolumeConversion.formatDb(-.infinity), "-∞")
        XCTAssertEqual(VolumeConversion.formatDb(-70), "-∞")
    }

    func testFormatDbUnity() {
        XCTAssertEqual(VolumeConversion.formatDb(0), "0.0")
    }

    func testFormatDbNegative() {
        XCTAssertEqual(VolumeConversion.formatDb(-12.3), "-12.3")
    }
}
