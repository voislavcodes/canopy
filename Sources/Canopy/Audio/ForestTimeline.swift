import Foundation

/// A region on the forest timeline representing one tree's playback window.
struct TimelineRegion {
    let treeID: UUID
    let startSample: Int64    // absolute position on timeline
    let endSample: Int64      // startSample + lengthInSamples
    let lengthInBeats: Double // tree cycle length (LCM of branch lengths)
}

/// Main-thread timeline model for forest mode.
/// Maps trees to contiguous sample regions on a single continuous clock.
/// Audio thread never sees this — it gets region bounds pushed via ring buffer commands.
class ForestTimeline {
    private(set) var regions: [TimelineRegion] = []

    var totalLengthInSamples: Int64 { regions.last?.endSample ?? 0 }

    /// Append a new region to the end of the timeline.
    func appendRegion(_ region: TimelineRegion) {
        regions.append(region)
    }

    /// Find the region that contains the given sample position.
    func regionForSample(_ sample: Int64) -> TimelineRegion? {
        // Walk backwards — most likely we're in the latest region
        for i in stride(from: regions.count - 1, through: 0, by: -1) {
            let r = regions[i]
            if sample >= r.startSample && sample < r.endSample {
                return r
            }
        }
        return nil
    }

    /// Find the next region boundary after the given sample position.
    /// Returns the startSample of the next region, or nil if no future boundary exists.
    func nextBoundaryAfter(_ sample: Int64) -> Int64? {
        for r in regions {
            if r.startSample > sample {
                return r.startSample
            }
        }
        return nil
    }

    /// Remove regions that end before the given sample position.
    /// Keeps the timeline from growing unbounded during long sessions.
    func pruneRegionsBefore(_ sample: Int64) {
        regions.removeAll { $0.endSample <= sample }
    }
}
