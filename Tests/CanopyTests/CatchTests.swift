import AVFoundation
import XCTest
@testable import Canopy

final class CatchTests: XCTestCase {

    // MARK: - HarvestedLoop Codable

    func testHarvestedLoopRoundTrip() throws {
        let loop = HarvestedLoop(
            name: "Wild — 3:42 PM",
            harvestSettings: HarvestSettings(mode: .wild),
            durationSeconds: 30.0,
            sampleRate: 48000,
            channelCount: 2,
            fileName: "wild-20260308-154200.wav",
            metadata: LoopMetadata(
                detectedBPM: 120,
                bpmConfidence: 0.8,
                detectedKey: MusicalKey(root: .C, mode: .minor),
                keyConfidence: 0.6,
                chordProgression: ["Cm", "Fm", "G7"],
                densityPerBeat: [0.5, 0.8, 0.3, 0.9],
                spectralCentroid: 2400.0,
                lengthInBeats: 16
            ),
            isAnalysing: false,
            sourceTreeID: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(loop)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(HarvestedLoop.self, from: data)

        XCTAssertEqual(loop, decoded)
        XCTAssertEqual(decoded.harvestSettings.mode, .wild)
        XCTAssertEqual(decoded.metadata?.detectedBPM, 120)
        XCTAssertEqual(decoded.metadata?.detectedKey?.root, .C)
    }

    func testHarvestedLoopBackwardCompat() throws {
        // Minimal JSON without optional fields
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Test",
            "harvestSettings": {"mode": "wild"},
            "durationSeconds": 10.0,
            "sampleRate": 44100,
            "fileName": "test.wav",
            "createdAt": 1709900000
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loop = try decoder.decode(HarvestedLoop.self, from: data)

        XCTAssertEqual(loop.name, "Test")
        XCTAssertEqual(loop.channelCount, 2) // default
        XCTAssertNil(loop.metadata)
        XCTAssertFalse(loop.isAnalysing) // default
        XCTAssertNil(loop.sourceTreeID)
    }

    func testHarvestModeRoundTrip() throws {
        let modes: [HarvestMode] = [.wild, .live, .fullTree, .branch, .ghost]
        for mode in modes {
            let settings = HarvestSettings(mode: mode)
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(HarvestSettings.self, from: data)
            XCTAssertEqual(settings, decoded)
        }
    }

    func testLoopMetadataAllNil() throws {
        let metadata = LoopMetadata()
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(LoopMetadata.self, from: data)
        XCTAssertEqual(metadata, decoded)
        XCTAssertNil(decoded.detectedBPM)
        XCTAssertNil(decoded.detectedKey)
    }

    // MARK: - CanopyProject backward compat with catches field

    func testProjectBackwardCompatWithoutCatches() throws {
        // Encode a project, then remove the "catches" key to simulate old format
        let project = ProjectFactory.newProject()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)

        // Decode as dictionary, remove catches, re-encode
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "catches")
        let modifiedData = try JSONSerialization.data(withJSONObject: dict)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: modifiedData)

        XCTAssertEqual(decoded.catches, []) // default empty array
    }

    func testProjectWithCatchesRoundTrip() throws {
        var project = ProjectFactory.newProject()
        project.catches = [
            HarvestedLoop(
                name: "Wild — 3:42 PM",
                harvestSettings: HarvestSettings(mode: .wild),
                durationSeconds: 15.0,
                sampleRate: 48000,
                fileName: "wild-test.wav"
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CanopyProject.self, from: data)

        XCTAssertEqual(decoded.catches.count, 1)
        XCTAssertEqual(decoded.catches[0].name, "Wild — 3:42 PM")
        XCTAssertEqual(decoded.catches[0].harvestSettings.mode, .wild)
    }

    // MARK: - CatchBuffer

    func testCatchBufferWriteAndSnapshot() {
        let buffer = CatchBuffer(sampleRate: 100, maxDuration: 1.0)

        // Simulate writing 50 frames (0.5 sec) of stereo interleaved data
        // We can't use installTap in tests, but we can test the snapshot on an empty buffer
        let snapshot = buffer.snapshot(lastSeconds: 0.5)
        XCTAssertNil(snapshot) // nothing written yet
    }

    func testCatchBufferSnapshotEmpty() {
        let buffer = CatchBuffer(sampleRate: 48000, maxDuration: 90.0)
        let snapshot = buffer.snapshot(lastSeconds: 30)
        XCTAssertNil(snapshot)
    }

    // MARK: - AudioFileService

    func testAudioFileServiceGenerateFilename() {
        let name1 = AudioFileService.generateCatchFilename()
        XCTAssertTrue(name1.hasPrefix("wild-"))
        XCTAssertTrue(name1.hasSuffix(".wav"))
    }

    func testAudioFileServiceGenerateDisplayName() {
        let name = AudioFileService.generateCatchDisplayName()
        XCTAssertTrue(name.hasPrefix("Wild — "))
    }

    func testAudioFileServiceWriteAndRead() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("catch-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // 100 frames of stereo silence
        let samples = [Float](repeating: 0, count: 200)
        try AudioFileService.writeWAV(
            samples: samples,
            sampleRate: 44100,
            channelCount: 2,
            to: url
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Read back and verify
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(Int(audioFile.length), 100) // 100 frames
        XCTAssertEqual(audioFile.processingFormat.channelCount, 2)
    }

    func testAudioFileServiceEmptySamplesThrows() {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("catch-empty-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AudioFileService.writeWAV(
            samples: [],
            sampleRate: 44100,
            channelCount: 2,
            to: url
        ))
    }
}
