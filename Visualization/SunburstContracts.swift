import HygieiaDomain

public enum SunburstSizeMetric: Hashable, Sendable {
    case logical
    case reportedAllocated
}

public enum SunburstItemID: Hashable, Sendable {
    case node(NodeID)
    case other(parent: NodeID)
}

public struct ProjectionNodeIndex: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct ProjectionFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let incompleteSource = Self(rawValue: 1 << 0)
    public static let childrenHiddenByDepth = Self(rawValue: 1 << 1)
    public static let childrenHiddenByBudget = Self(rawValue: 1 << 2)
}

public struct ProjectionNode: Hashable, Sendable {
    public let item: SunburstItemID
    public let parent: ProjectionNodeIndex?
    public let firstChild: ProjectionNodeIndex?
    public let nextSibling: ProjectionNodeIndex?
    public let value: UInt64
    public let aggregatedDirectChildCount: UInt64
    public let zeroValueDirectChildCount: UInt64
    public let hiddenPositiveDirectChildCount: UInt64
    public let hiddenPositiveDirectChildValue: UInt64
    public let depth: UInt16
    public let flags: ProjectionFlags

    public init(
        item: SunburstItemID,
        parent: ProjectionNodeIndex?,
        firstChild: ProjectionNodeIndex?,
        nextSibling: ProjectionNodeIndex?,
        value: UInt64,
        aggregatedDirectChildCount: UInt64,
        zeroValueDirectChildCount: UInt64,
        hiddenPositiveDirectChildCount: UInt64,
        hiddenPositiveDirectChildValue: UInt64,
        depth: UInt16,
        flags: ProjectionFlags
    ) {
        self.item = item
        self.parent = parent
        self.firstChild = firstChild
        self.nextSibling = nextSibling
        self.value = value
        self.aggregatedDirectChildCount = aggregatedDirectChildCount
        self.zeroValueDirectChildCount = zeroValueDirectChildCount
        self.hiddenPositiveDirectChildCount = hiddenPositiveDirectChildCount
        self.hiddenPositiveDirectChildValue = hiddenPositiveDirectChildValue
        self.depth = depth
        self.flags = flags
    }
}

public struct ProjectionSummary: Hashable, Sendable {
    public let visitedSourceNodeCount: UInt64
    public let representedRealNodeCount: Int
    public let otherNodeCount: Int
    public let observedZeroValueNodeCount: UInt64
    public let observedHiddenPositiveNodeCount: UInt64
    public let observedHiddenPositiveValue: UInt64
    public let hasDepthLimitedBranches: Bool
    public let hasBudgetLimitedBranches: Bool

    public init(
        visitedSourceNodeCount: UInt64,
        representedRealNodeCount: Int,
        otherNodeCount: Int,
        observedZeroValueNodeCount: UInt64,
        observedHiddenPositiveNodeCount: UInt64,
        observedHiddenPositiveValue: UInt64,
        hasDepthLimitedBranches: Bool,
        hasBudgetLimitedBranches: Bool
    ) {
        self.visitedSourceNodeCount = visitedSourceNodeCount
        self.representedRealNodeCount = representedRealNodeCount
        self.otherNodeCount = otherNodeCount
        self.observedZeroValueNodeCount = observedZeroValueNodeCount
        self.observedHiddenPositiveNodeCount = observedHiddenPositiveNodeCount
        self.observedHiddenPositiveValue = observedHiddenPositiveValue
        self.hasDepthLimitedBranches = hasDepthLimitedBranches
        self.hasBudgetLimitedBranches = hasBudgetLimitedBranches
    }
}

public struct SunburstProjection: Sendable {
    public let sourceRoot: NodeID
    public let metric: SunburstSizeMetric
    public let nodes: ContiguousArray<ProjectionNode>
    public let summary: ProjectionSummary

    public init(
        sourceRoot: NodeID,
        metric: SunburstSizeMetric,
        nodes: ContiguousArray<ProjectionNode>,
        summary: ProjectionSummary
    ) {
        self.sourceRoot = sourceRoot
        self.metric = metric
        self.nodes = nodes
        self.summary = summary
    }
}

public struct SunburstProjectionRequest: Hashable, Sendable {
    public let root: NodeID
    public let metric: SunburstSizeMetric
    public let maximumDepth: UInt16
    public let maximumNodeCount: Int
    public let minimumAngularSpanByDepth: ContiguousArray<Double>

    public init(
        root: NodeID,
        metric: SunburstSizeMetric,
        maximumDepth: UInt16,
        maximumNodeCount: Int,
        minimumAngularSpanByDepth: ContiguousArray<Double>
    ) {
        self.root = root
        self.metric = metric
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
        self.minimumAngularSpanByDepth = minimumAngularSpanByDepth
    }
}

public struct SunburstViewport: Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct SunburstSegmentIndex: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct SunburstSegment: Hashable, Sendable {
    public let item: SunburstItemID
    public let projectionIndex: ProjectionNodeIndex
    public let parentSegment: SunburstSegmentIndex?
    public let value: UInt64
    public let depth: UInt16
    public let startAngle: Double
    public let endAngle: Double
    public let innerRadius: Double
    public let outerRadius: Double

    public init(
        item: SunburstItemID,
        projectionIndex: ProjectionNodeIndex,
        parentSegment: SunburstSegmentIndex?,
        value: UInt64,
        depth: UInt16,
        startAngle: Double,
        endAngle: Double,
        innerRadius: Double,
        outerRadius: Double
    ) {
        self.item = item
        self.projectionIndex = projectionIndex
        self.parentSegment = parentSegment
        self.value = value
        self.depth = depth
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
    }
}

public struct NodeSegmentEntry: Hashable, Sendable {
    public let node: NodeID
    public let segment: SunburstSegmentIndex

    public init(node: NodeID, segment: SunburstSegmentIndex) {
        self.node = node
        self.segment = segment
    }
}

public struct SunburstLayoutResult: Sendable {
    public let sourceRoot: NodeID
    public let viewport: SunburstViewport
    public let centerRadius: Double
    public let outerRadius: Double
    public let segments: ContiguousArray<SunburstSegment>
    public let ringRanges: ContiguousArray<Range<Int>>
    public let nodeSegmentsByNodeID: ContiguousArray<NodeSegmentEntry>

    public init(
        sourceRoot: NodeID,
        viewport: SunburstViewport,
        centerRadius: Double,
        outerRadius: Double,
        segments: ContiguousArray<SunburstSegment>,
        ringRanges: ContiguousArray<Range<Int>>,
        nodeSegmentsByNodeID: ContiguousArray<NodeSegmentEntry>
    ) {
        self.sourceRoot = sourceRoot
        self.viewport = viewport
        self.centerRadius = centerRadius
        self.outerRadius = outerRadius
        self.segments = segments
        self.ringRanges = ringRanges
        self.nodeSegmentsByNodeID = nodeSegmentsByNodeID
    }
}

public enum SunburstHit: Hashable, Sendable {
    case center(NodeID)
    case segment(SunburstSegmentIndex)
}
