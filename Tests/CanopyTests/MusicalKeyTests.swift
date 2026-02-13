import XCTest
@testable import Canopy

final class MusicalKeyTests: XCTestCase {

    // MARK: - PitchClass.semitone

    func testPitchClassSemitones() {
        XCTAssertEqual(PitchClass.C.semitone, 0)
        XCTAssertEqual(PitchClass.Cs.semitone, 1)
        XCTAssertEqual(PitchClass.D.semitone, 2)
        XCTAssertEqual(PitchClass.E.semitone, 4)
        XCTAssertEqual(PitchClass.F.semitone, 5)
        XCTAssertEqual(PitchClass.B.semitone, 11)
    }

    // MARK: - ScaleMode.intervals

    func testMajorIntervals() {
        XCTAssertEqual(ScaleMode.major.intervals, [0, 2, 4, 5, 7, 9, 11])
    }

    func testMinorIntervals() {
        XCTAssertEqual(ScaleMode.minor.intervals, [0, 2, 3, 5, 7, 8, 10])
    }

    func testChromaticIntervals() {
        XCTAssertEqual(ScaleMode.chromatic.intervals, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    func testPentatonicIntervals() {
        XCTAssertEqual(ScaleMode.pentatonic.intervals, [0, 2, 4, 7, 9])
    }

    func testPentatonicMinorIntervals() {
        XCTAssertEqual(ScaleMode.pentatonicMinor.intervals, [0, 3, 5, 7, 10])
    }

    func testWholeToneIntervals() {
        XCTAssertEqual(ScaleMode.wholeTone.intervals, [0, 2, 4, 6, 8, 10])
    }

    func testAllScaleModesHaveIntervals() {
        for mode in ScaleMode.allCases {
            XCTAssertFalse(mode.intervals.isEmpty, "\(mode) should have intervals")
            XCTAssertEqual(mode.intervals.first, 0, "\(mode) intervals should start at 0")
            // All intervals should be in ascending order
            for i in 1..<mode.intervals.count {
                XCTAssertGreaterThan(mode.intervals[i], mode.intervals[i - 1],
                                     "\(mode) intervals should be ascending")
            }
        }
    }

    // MARK: - notesInRange

    func testNotesInRangeCMajorOneOctave() {
        let key = MusicalKey(root: .C, mode: .major)
        let notes = key.notesInRange(low: 60, high: 72)
        // C4=60, D4=62, E4=64, F4=65, G4=67, A4=69, B4=71, C5=72
        XCTAssertEqual(notes, [60, 62, 64, 65, 67, 69, 71, 72])
    }

    func testNotesInRangeGMinor() {
        let key = MusicalKey(root: .G, mode: .minor)
        // G minor: G, A, Bb, C, D, Eb, F
        // G=7, intervals [0,2,3,5,7,8,10]
        // In MIDI: G3=55, A3=57, Bb3=58, C4=60, D4=62, Eb4=63, F4=65
        let notes = key.notesInRange(low: 55, high: 65)
        XCTAssertEqual(notes, [55, 57, 58, 60, 62, 63, 65])
    }

    func testNotesInRangeEmptyRange() {
        let key = MusicalKey(root: .C, mode: .major)
        let notes = key.notesInRange(low: 60, high: 60)
        XCTAssertEqual(notes, [60]) // C4 is in C major
    }

    // MARK: - quantize

    func testQuantizeInScale() {
        let key = MusicalKey(root: .C, mode: .major)
        // C4 is already in scale
        XCTAssertEqual(key.quantize(60), 60)
    }

    func testQuantizeOutOfScale() {
        let key = MusicalKey(root: .C, mode: .major)
        // C#4 = 61, should snap to C4=60 or D4=62
        let result = key.quantize(61)
        XCTAssertTrue(result == 60 || result == 62, "C#4 should snap to C4 or D4, got \(result)")
    }

    func testQuantizeBlackKeyInMinor() {
        let key = MusicalKey(root: .A, mode: .minor)
        // A minor: A B C D E F G — MIDI 69=A, 71=B, 72=C, 74=D, 76=E, 77=F, 79=G
        // Bb=70 should snap to A=69 or B=71
        let result = key.quantize(70)
        XCTAssertTrue(result == 69 || result == 71, "Bb should snap to A or B in A minor, got \(result)")
    }

    // MARK: - degree

    func testDegreeOfScaleNote() {
        let key = MusicalKey(root: .C, mode: .major)
        XCTAssertEqual(key.degree(of: 60), 0) // C = degree 0
        XCTAssertEqual(key.degree(of: 62), 1) // D = degree 1
        XCTAssertEqual(key.degree(of: 64), 2) // E = degree 2
        XCTAssertEqual(key.degree(of: 67), 4) // G = degree 4
    }

    func testDegreeOfNonScaleNote() {
        let key = MusicalKey(root: .C, mode: .major)
        XCTAssertNil(key.degree(of: 61)) // C# not in C major
    }

    func testDegreeOctaveInvariant() {
        let key = MusicalKey(root: .C, mode: .major)
        XCTAssertEqual(key.degree(of: 48), 0) // C3
        XCTAssertEqual(key.degree(of: 60), 0) // C4
        XCTAssertEqual(key.degree(of: 72), 0) // C5
    }

    // MARK: - shiftByDegrees

    func testShiftByDegreesUp() {
        let key = MusicalKey(root: .C, mode: .major)
        // C4 + 2 degrees = E4
        XCTAssertEqual(key.shiftByDegrees(60, degrees: 2), 64)
    }

    func testShiftByDegreesDown() {
        let key = MusicalKey(root: .C, mode: .major)
        // E4 - 2 degrees = C4
        XCTAssertEqual(key.shiftByDegrees(64, degrees: -2), 60)
    }

    func testShiftByDegreesAcrossOctave() {
        let key = MusicalKey(root: .C, mode: .major)
        // B4=71 + 1 degree = C5=72
        XCTAssertEqual(key.shiftByDegrees(71, degrees: 1), 72)
    }

    // MARK: - ScaleResolver

    func testScaleResolverNodeOverride() {
        let project = CanopyProject(globalKey: MusicalKey(root: .C, mode: .major))
        let tree = NodeTree(scale: MusicalKey(root: .D, mode: .minor))
        let node = Node(scaleOverride: MusicalKey(root: .E, mode: .dorian))
        let resolved = ScaleResolver.resolve(node: node, tree: tree, project: project)
        XCTAssertEqual(resolved, MusicalKey(root: .E, mode: .dorian))
    }

    func testScaleResolverTreeFallback() {
        let project = CanopyProject(globalKey: MusicalKey(root: .C, mode: .major))
        let tree = NodeTree(scale: MusicalKey(root: .D, mode: .minor))
        let node = Node()
        let resolved = ScaleResolver.resolve(node: node, tree: tree, project: project)
        XCTAssertEqual(resolved, MusicalKey(root: .D, mode: .minor))
    }

    func testScaleResolverProjectFallback() {
        let project = CanopyProject(globalKey: MusicalKey(root: .C, mode: .major))
        let tree = NodeTree()
        let node = Node()
        let resolved = ScaleResolver.resolve(node: node, tree: tree, project: project)
        XCTAssertEqual(resolved, MusicalKey(root: .C, mode: .major))
    }
}
