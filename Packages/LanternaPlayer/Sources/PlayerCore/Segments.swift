import Foundation

public struct Segment: Codable, Sendable, Equatable {
    public var index: Int
    /// Presentation time of the keyframe that opens the segment, in seconds.
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
}

public struct SegmentPlan: Codable, Sendable, Equatable {
    public var segments: [Segment]
    /// HLS EXT-X-TARGETDURATION: the longest segment rounded up.
    public var targetDurationSeconds: Int

    /// Index of the segment that contains `time`, clamped to the plan.
    public func segmentIndex(containing time: Double) -> Int {
        guard let last = segments.indices.last else { return 0 }
        var low = 0, high = last
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Plans a full VOD playlist from the keyframe index before playback starts, so duration and
/// seeking are known up front. Segments always open on a keyframe.
public struct SegmentPlanner: Sendable {
    public var targetDuration: Double
    /// A trailing segment shorter than this is merged into the one before it.
    public var minimumTail: Double

    public init(targetDuration: Double = 6, minimumTail: Double = 1) {
        self.targetDuration = targetDuration
        self.minimumTail = minimumTail
    }

    public func plan(keyframes: [Double], duration: Double) -> SegmentPlan {
        let sorted = keyframes.sorted()
        guard let first = sorted.first, duration > first else {
            return SegmentPlan(segments: [], targetDurationSeconds: Int(targetDuration.rounded(.up)))
        }
        var boundaries = [first]
        for keyframe in sorted.dropFirst() where keyframe < duration {
            if keyframe - boundaries[boundaries.count - 1] >= targetDuration - 1e-6 {
                boundaries.append(keyframe)
            }
        }
        if boundaries.count > 1, duration - boundaries[boundaries.count - 1] < minimumTail {
            boundaries.removeLast()
        }
        let segments = boundaries.enumerated().map { index, start in
            Segment(index: index, start: start, end: index + 1 < boundaries.count ? boundaries[index + 1] : duration)
        }
        let longest = segments.map(\.duration).max() ?? targetDuration
        return SegmentPlan(segments: segments, targetDurationSeconds: max(1, Int((longest - 1e-3).rounded(.up))))
    }
}
