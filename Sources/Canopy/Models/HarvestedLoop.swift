import Foundation

// MARK: - Harvest Mode

/// Distinguishes how a loop was captured.
enum HarvestMode: String, Codable, Equatable {
    /// Catch — captured from rolling audio buffer (estimated metadata).
    case wild
    /// Harvest — intentional performance capture (perfect metadata, future build).
    case live
    /// Full tree rendered to stereo.
    case fullTree
    /// Single branch isolated.
    case branch
    /// Probability variation of a tree.
    case ghost
}

// MARK: - Harvest Settings

/// Provenance metadata for a harvested loop.
struct HarvestSettings: Codable, Equatable {
    var mode: HarvestMode
    var ghostSeed: UInt64?
    var ghostIndex: Int?

    init(mode: HarvestMode, ghostSeed: UInt64? = nil, ghostIndex: Int? = nil) {
        self.mode = mode
        self.ghostSeed = ghostSeed
        self.ghostIndex = ghostIndex
    }
}

// MARK: - Loop Metadata

/// Estimated or exact musical metadata for a harvested loop.
/// All fields are optional — wild harvests populate them asynchronously via analysis.
struct LoopMetadata: Codable, Equatable {
    var detectedBPM: Double?
    var bpmConfidence: Double?
    var detectedKey: MusicalKey?
    var keyConfidence: Double?
    var chordProgression: [String]?
    var densityPerBeat: [Double]?
    var spectralCentroid: Double?
    var lengthInBeats: Int?

    init(
        detectedBPM: Double? = nil,
        bpmConfidence: Double? = nil,
        detectedKey: MusicalKey? = nil,
        keyConfidence: Double? = nil,
        chordProgression: [String]? = nil,
        densityPerBeat: [Double]? = nil,
        spectralCentroid: Double? = nil,
        lengthInBeats: Int? = nil
    ) {
        self.detectedBPM = detectedBPM
        self.bpmConfidence = bpmConfidence
        self.detectedKey = detectedKey
        self.keyConfidence = keyConfidence
        self.chordProgression = chordProgression
        self.densityPerBeat = densityPerBeat
        self.spectralCentroid = spectralCentroid
        self.lengthInBeats = lengthInBeats
    }
}

// MARK: - Harvested Loop

/// A captured audio loop — either from Catch (wild) or Harvest (live/tree/branch/ghost).
/// Lives on the loop shelf in River.
struct HarvestedLoop: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var harvestSettings: HarvestSettings
    var durationSeconds: Double
    var sampleRate: Double
    var channelCount: Int
    var createdAt: Date
    /// Relative filename within the project's Catches/ directory.
    var fileName: String
    var metadata: LoopMetadata?
    var isAnalysing: Bool

    /// Source tree ID (nil for wild harvests).
    var sourceTreeID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        harvestSettings: HarvestSettings,
        durationSeconds: Double,
        sampleRate: Double,
        channelCount: Int = 2,
        createdAt: Date = Date(),
        fileName: String,
        metadata: LoopMetadata? = nil,
        isAnalysing: Bool = false,
        sourceTreeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.harvestSettings = harvestSettings
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.createdAt = createdAt
        self.fileName = fileName
        self.metadata = metadata
        self.isAnalysing = isAnalysing
        self.sourceTreeID = sourceTreeID
    }

    // Backward-compatible decoding.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        harvestSettings = try container.decode(HarvestSettings.self, forKey: .harvestSettings)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decodeIfPresent(Int.self, forKey: .channelCount) ?? 2
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        metadata = try container.decodeIfPresent(LoopMetadata.self, forKey: .metadata)
        isAnalysing = try container.decodeIfPresent(Bool.self, forKey: .isAnalysing) ?? false
        sourceTreeID = try container.decodeIfPresent(UUID.self, forKey: .sourceTreeID)
    }
}
