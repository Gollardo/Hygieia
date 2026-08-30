import Foundation
import HygieiaDomain

public enum SunburstLayoutError: Error, Equatable, Sendable {
    case invalidViewport
    case insufficientRingCapacity(requiredDepth: UInt16, availableDepth: UInt16)
    case invalidProjection
    case nonFiniteGeometry
}

public protocol SunburstLayouting: Sendable {
    func layout(projection: SunburstProjection, viewport: SunburstViewport) async throws -> SunburstLayoutResult
}

public struct SunburstLayout: SunburstLayouting {
    public init() {}

    public func layout(projection: SunburstProjection, viewport: SunburstViewport) async throws -> SunburstLayoutResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.layoutSynchronously(projection: projection, viewport: viewport)
        }.value
    }

    private static func layoutSynchronously(projection: SunburstProjection, viewport: SunburstViewport) throws -> SunburstLayoutResult {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else {
            throw SunburstLayoutError.invalidViewport
        }
        guard let root = projection.nodes.first, root.item == .node(projection.sourceRoot), root.depth == 0 else {
            throw SunburstLayoutError.invalidProjection
        }

        let outerRadius = min(viewport.width, viewport.height) / 2 - 12
        guard outerRadius.isFinite, outerRadius > 0 else { throw SunburstLayoutError.invalidViewport }
        let centerRadius = min(max(outerRadius * 0.18, 44), 84)
        let requiredDepth = projection.nodes.map(\.depth).max() ?? 0
        if requiredDepth == 0 {
            return .init(
                sourceRoot: projection.sourceRoot,
                viewport: viewport,
                centerRadius: min(centerRadius, outerRadius),
                outerRadius: outerRadius,
                segments: [],
                ringRanges: [0..<0],
                nodeSegmentsByNodeID: []
            )
        }

        let usableRadius = outerRadius - centerRadius
        let availableDepth = UInt16(max(0, min(7, Int((usableRadius / 28).rounded(.down)))))
        guard requiredDepth <= availableDepth else {
            throw SunburstLayoutError.insufficientRingCapacity(requiredDepth: requiredDepth, availableDepth: availableDepth)
        }
        let ringThickness = usableRadius / Double(requiredDepth)
        guard ringThickness.isFinite, ringThickness >= 28 else {
            throw SunburstLayoutError.insufficientRingCapacity(requiredDepth: requiredDepth, availableDepth: availableDepth)
        }

        var segments: ContiguousArray<SunburstSegment> = []
        var ranges: ContiguousArray<Range<Int>> = [0..<0]
        var entries: ContiguousArray<NodeSegmentEntry> = []
        var parents: [LayoutParent] = [.init(projectionIndex: .init(rawValue: 0), segmentIndex: nil, startAngle: 0, endAngle: .twoPi)]

        for depth in 1...requiredDepth {
            if Task.isCancelled { throw CancellationError() }
            let start = segments.count
            var children: [LayoutParent] = []
            for parent in parents {
                let projectionParent = try node(at: parent.projectionIndex, in: projection)
                guard projectionParent.depth + 1 == depth else { throw SunburstLayoutError.invalidProjection }
                var childIndex = projectionParent.firstChild
                var cursor = parent.startAngle
                var lastSegmentIndex: Int?
                while let current = childIndex {
                    let child = try node(at: current, in: projection)
                    guard child.parent == parent.projectionIndex, child.depth == depth, child.value > 0 else {
                        throw SunburstLayoutError.invalidProjection
                    }
                    let span = (parent.endAngle - parent.startAngle) * Double(child.value) / Double(projectionParent.value)
                    let end = cursor + span
                    let segmentIndex = SunburstSegmentIndex(rawValue: UInt32(segments.count))
                    let segment = SunburstSegment(
                        item: child.item,
                        projectionIndex: current,
                        parentSegment: parent.segmentIndex,
                        value: child.value,
                        depth: depth,
                        startAngle: cursor,
                        endAngle: end,
                        innerRadius: centerRadius + Double(depth - 1) * ringThickness,
                        outerRadius: centerRadius + Double(depth) * ringThickness
                    )
                    guard isFinite(segment) else { throw SunburstLayoutError.nonFiniteGeometry }
                    segments.append(segment)
                    lastSegmentIndex = segments.count - 1
                    if case .node(let node) = child.item {
                        entries.append(.init(node: node, segment: segmentIndex))
                    }
                    children.append(.init(projectionIndex: current, segmentIndex: segmentIndex, startAngle: cursor, endAngle: end))
                    cursor = end
                    childIndex = child.nextSibling
                }
                if projectionParent.hiddenPositiveDirectChildCount == 0, let lastSegmentIndex {
                    let last = segments[lastSegmentIndex]
                    segments[lastSegmentIndex] = SunburstSegment(
                        item: last.item,
                        projectionIndex: last.projectionIndex,
                        parentSegment: last.parentSegment,
                        value: last.value,
                        depth: last.depth,
                        startAngle: last.startAngle,
                        endAngle: parent.endAngle,
                        innerRadius: last.innerRadius,
                        outerRadius: last.outerRadius
                    )
                    if let lastChild = children.indices.last {
                        children[lastChild] = .init(projectionIndex: children[lastChild].projectionIndex, segmentIndex: children[lastChild].segmentIndex, startAngle: children[lastChild].startAngle, endAngle: parent.endAngle)
                    }
                }
            }
            ranges.append(start..<segments.count)
            parents = children
        }

        entries.sort { $0.node < $1.node }
        return .init(
            sourceRoot: projection.sourceRoot,
            viewport: viewport,
            centerRadius: centerRadius,
            outerRadius: outerRadius,
            segments: segments,
            ringRanges: ranges,
            nodeSegmentsByNodeID: entries
        )
    }

    private static func node(at index: ProjectionNodeIndex, in projection: SunburstProjection) throws -> ProjectionNode {
        let offset = Int(index.rawValue)
        guard projection.nodes.indices.contains(offset) else { throw SunburstLayoutError.invalidProjection }
        return projection.nodes[offset]
    }

    private static func isFinite(_ segment: SunburstSegment) -> Bool {
        segment.startAngle.isFinite && segment.endAngle.isFinite && segment.innerRadius.isFinite && segment.outerRadius.isFinite
    }
}

private struct LayoutParent {
    let projectionIndex: ProjectionNodeIndex
    let segmentIndex: SunburstSegmentIndex?
    let startAngle: Double
    let endAngle: Double
}

private extension Double {
    static let twoPi = Double.pi * 2
}
