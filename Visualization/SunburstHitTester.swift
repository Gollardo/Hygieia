import Foundation

public enum SunburstHitTester {
    /// Hit tests logical sector bounds; renderer-only visual gaps never create dead zones.
    public static func hitTest(layout: SunburstLayoutResult, x: Double, y: Double) -> SunburstHit? {
        let dx = x - layout.viewport.width / 2
        let dy = y - layout.viewport.height / 2
        let radius = hypot(dx, dy)
        guard radius.isFinite else { return nil }
        if radius < layout.centerRadius { return .center(layout.sourceRoot) }
        guard radius <= layout.outerRadius else { return nil }

        guard let range = ringRange(containing: radius, layout: layout), !range.isEmpty else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += .twoPi }
        guard angle.isFinite else { return nil }

        let segmentOffset = lastSegmentStarting(atOrBefore: angle, in: layout.segments, range: range)
        guard let segmentOffset else { return nil }
        let segment = layout.segments[segmentOffset]
        return angle < segment.endAngle || (segment.endAngle == .twoPi && angle == 0) ? .segment(.init(rawValue: UInt32(segmentOffset))) : nil
    }

    private static func ringRange(containing radius: Double, layout: SunburstLayoutResult) -> Range<Int>? {
        for range in layout.ringRanges.dropFirst() where !range.isEmpty {
            let segment = layout.segments[range.lowerBound]
            let isOutermost = range == layout.ringRanges.last
            if radius >= segment.innerRadius, radius < segment.outerRadius || (isOutermost && radius == segment.outerRadius) {
                return range
            }
        }
        return nil
    }

    private static func lastSegmentStarting(atOrBefore angle: Double, in segments: ContiguousArray<SunburstSegment>, range: Range<Int>) -> Int? {
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].startAngle <= angle {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let candidate = low - 1
        return range.contains(candidate) ? candidate : nil
    }
}

private extension Double {
    static let twoPi = Double.pi * 2
}
