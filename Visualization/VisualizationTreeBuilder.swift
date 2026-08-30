import HygieiaDomain

public enum SunburstProjectionError: Error, Equatable, Sendable {
    case invalidRoot(NodeID)
    case invalidMaximumNodeCount(Int)
    case missingMinimumAngularSpan(depth: UInt16)
    case invalidMinimumAngularSpan(depth: UInt16)
    case inconsistentAccounting(parent: NodeID)
    case sizeOverflow(parent: NodeID)
    case cancelled
}

public protocol SunburstProjectionBuilding: Sendable {
    func build(tree: FileTree, request: SunburstProjectionRequest) async throws -> SunburstProjection
}

/// Builds a bounded, renderer-neutral view of an immutable `FileTree`.
public struct VisualizationTreeBuilder: SunburstProjectionBuilding {
    public init() {}

    public func build(tree: FileTree, request: SunburstProjectionRequest) async throws -> SunburstProjection {
        try await Task.detached(priority: .userInitiated) {
            try Self.buildSynchronously(tree: tree, request: request)
        }.value
    }

    private static func buildSynchronously(tree: FileTree, request: SunburstProjectionRequest) throws -> SunburstProjection {
        guard tree.node(for: request.root) != nil else { throw SunburstProjectionError.invalidRoot(request.root) }
        guard request.maximumNodeCount > 0, request.maximumNodeCount <= Int(UInt32.max) else {
            throw SunburstProjectionError.invalidMaximumNodeCount(request.maximumNodeCount)
        }
        try validate(request)

        let rootSource = tree[request.root]
        let rootValue = value(of: rootSource, metric: request.metric)
        var nodes: ContiguousArray<ProjectionNode> = [
            .init(
                item: .node(request.root),
                parent: nil,
                firstChild: nil,
                nextSibling: nil,
                value: rootValue,
                aggregatedDirectChildCount: 0,
                zeroValueDirectChildCount: 0,
                hiddenPositiveDirectChildCount: 0,
                hiddenPositiveDirectChildValue: 0,
                depth: 0,
                flags: sourceFlags(for: rootSource)
            ),
        ]

        var visitedSourceNodeCount: UInt64 = 1
        var observedZeroValueNodeCount: UInt64 = rootValue == 0 ? 1 : 0
        var observedHiddenPositiveNodeCount: UInt64 = 0
        var observedHiddenPositiveValue: UInt64 = 0
        var otherNodeCount = 0
        var hasDepthLimitedBranches = false
        var hasBudgetLimitedBranches = false

        guard rootValue > 0 else {
            return projection()
        }
        if request.maximumDepth == 0 {
            if rootSource.firstChild.isValid {
                nodes[0] = updating(nodes[0], flags: [.childrenHiddenByDepth])
                hasDepthLimitedBranches = true
            }
            return projection()
        }

        var currentRing: [ParentWork] = [.init(index: .init(rawValue: 0), source: request.root, span: .twoPi)]
        for depth in 0..<request.maximumDepth {
            if Task.isCancelled { throw SunburstProjectionError.cancelled }
            let nextDepth = depth + 1
            let minimumSpan = request.minimumAngularSpanByDepth[Int(depth)]
            currentRing.sort { lhs, rhs in
                lhs.span == rhs.span ? lhs.source < rhs.source : lhs.span > rhs.span
            }
            var nextRing: [ParentWork] = []

            for work in currentRing {
                if Task.isCancelled { throw SunburstProjectionError.cancelled }
                let parentIndex = Int(work.index.rawValue)
                let parentSource = tree[work.source]
                guard parentSource.firstChild.isValid else { continue }

                if nodes.count >= request.maximumNodeCount || request.maximumNodeCount - nodes.count < 2 {
                    nodes[parentIndex] = updating(nodes[parentIndex], flags: [.childrenHiddenByBudget])
                    hasBudgetLimitedBranches = true
                    continue
                }

                let angularCapacity = work.span / minimumSpan
                let boundedAngularCapacity = angularCapacity >= Double(Int.max) ? Int.max : Int(angularCapacity.rounded(.down))
                let localCapacity = min(boundedAngularCapacity, request.maximumNodeCount - nodes.count)
                guard localCapacity >= 2 else {
                    nodes[parentIndex] = updating(nodes[parentIndex], flags: [.childrenHiddenByBudget])
                    hasBudgetLimitedBranches = true
                    continue
                }

                var candidates = CandidateHeap(limit: localCapacity)
                var positiveValue: UInt64 = 0
                var zeroCount: UInt64 = 0
                var omittedCount: UInt64 = 0
                var omittedValue: UInt64 = 0
                var child = parentSource.firstChild
                var streamedChildren = 0

                while child.isValid {
                    if streamedChildren.isMultiple(of: 4_096), Task.isCancelled {
                        throw SunburstProjectionError.cancelled
                    }
                    streamedChildren += 1
                    visitedSourceNodeCount &+= 1
                    let source = tree[child]
                    let childValue = value(of: source, metric: request.metric)
                    if childValue == 0 {
                        zeroCount &+= 1
                        observedZeroValueNodeCount &+= 1
                    } else {
                        let addition = positiveValue.addingReportingOverflow(childValue)
                        guard !addition.overflow else { throw SunburstProjectionError.sizeOverflow(parent: work.source) }
                        positiveValue = addition.partialValue
                        let childSpan = work.span * Double(childValue) / Double(nodes[parentIndex].value)
                        if childSpan < minimumSpan {
                            try appendOmitted(value: childValue, toCount: &omittedCount, toValue: &omittedValue, parent: work.source)
                        } else if let displaced = candidates.insert(.init(source: child, value: childValue)) {
                            try appendOmitted(value: displaced.value, toCount: &omittedCount, toValue: &omittedValue, parent: work.source)
                        }
                    }
                    child = source.nextSibling
                }

                guard positiveValue == nodes[parentIndex].value else {
                    throw SunburstProjectionError.inconsistentAccounting(parent: work.source)
                }

                var retained = candidates.sortedDescending()
                if omittedCount > 0, retained.count == localCapacity, let displaced = retained.popLast() {
                    try appendOmitted(value: displaced.value, toCount: &omittedCount, toValue: &omittedValue, parent: work.source)
                }

                let omittedSpan = work.span * Double(omittedValue) / Double(nodes[parentIndex].value)
                let materializesOther = omittedCount > 0 && omittedSpan >= minimumSpan && retained.count < localCapacity
                if !materializesOther, omittedCount > 0 {
                    nodes[parentIndex] = updating(
                        nodes[parentIndex],
                        zeroCount: zeroCount,
                        hiddenCount: omittedCount,
                        hiddenValue: omittedValue,
                        flags: [.childrenHiddenByBudget]
                    )
                    hasBudgetLimitedBranches = true
                    observedHiddenPositiveNodeCount &+= omittedCount
                    let addition = observedHiddenPositiveValue.addingReportingOverflow(omittedValue)
                    guard !addition.overflow else { throw SunburstProjectionError.sizeOverflow(parent: work.source) }
                    observedHiddenPositiveValue = addition.partialValue
                } else {
                    nodes[parentIndex] = updating(nodes[parentIndex], zeroCount: zeroCount)
                }

                var childIndexes: [ProjectionNodeIndex] = []
                childIndexes.reserveCapacity(retained.count + (materializesOther ? 1 : 0))
                for candidate in retained {
                    let source = tree[candidate.source]
                    let index = ProjectionNodeIndex(rawValue: UInt32(nodes.count))
                    nodes.append(
                        .init(
                            item: .node(candidate.source),
                            parent: work.index,
                            firstChild: nil,
                            nextSibling: nil,
                            value: candidate.value,
                            aggregatedDirectChildCount: 0,
                            zeroValueDirectChildCount: 0,
                            hiddenPositiveDirectChildCount: 0,
                            hiddenPositiveDirectChildValue: 0,
                            depth: nextDepth,
                            flags: sourceFlags(for: source)
                        )
                    )
                    childIndexes.append(index)
                    nextRing.append(.init(index: index, source: candidate.source, span: work.span * Double(candidate.value) / Double(nodes[parentIndex].value)))
                }

                if materializesOther {
                    let index = ProjectionNodeIndex(rawValue: UInt32(nodes.count))
                    nodes.append(
                        .init(
                            item: .other(parent: work.source),
                            parent: work.index,
                            firstChild: nil,
                            nextSibling: nil,
                            value: omittedValue,
                            aggregatedDirectChildCount: omittedCount,
                            zeroValueDirectChildCount: 0,
                            hiddenPositiveDirectChildCount: 0,
                            hiddenPositiveDirectChildValue: 0,
                            depth: nextDepth,
                            flags: []
                        )
                    )
                    childIndexes.append(index)
                    otherNodeCount += 1
                }

                if let first = childIndexes.first {
                    nodes[parentIndex] = updating(nodes[parentIndex], firstChild: first)
                }
                for (offset, index) in childIndexes.enumerated() where offset + 1 < childIndexes.count {
                    let nodeIndex = Int(index.rawValue)
                    nodes[nodeIndex] = updating(nodes[nodeIndex], nextSibling: childIndexes[offset + 1])
                }
            }
            currentRing = nextRing
        }

        for work in currentRing where tree[work.source].firstChild.isValid {
            let index = Int(work.index.rawValue)
            nodes[index] = updating(nodes[index], flags: [.childrenHiddenByDepth])
            hasDepthLimitedBranches = true
        }

        return projection()

        func projection() -> SunburstProjection {
            let summary = ProjectionSummary(
                visitedSourceNodeCount: visitedSourceNodeCount,
                representedRealNodeCount: nodes.count - otherNodeCount,
                otherNodeCount: otherNodeCount,
                observedZeroValueNodeCount: observedZeroValueNodeCount,
                observedHiddenPositiveNodeCount: observedHiddenPositiveNodeCount,
                observedHiddenPositiveValue: observedHiddenPositiveValue,
                hasDepthLimitedBranches: hasDepthLimitedBranches,
                hasBudgetLimitedBranches: hasBudgetLimitedBranches
            )
            return .init(sourceRoot: request.root, metric: request.metric, nodes: nodes, summary: summary)
        }
    }

    private static func validate(_ request: SunburstProjectionRequest) throws {
        for depth in 0..<request.maximumDepth {
            guard request.minimumAngularSpanByDepth.indices.contains(Int(depth)) else {
                throw SunburstProjectionError.missingMinimumAngularSpan(depth: depth + 1)
            }
            let value = request.minimumAngularSpanByDepth[Int(depth)]
            guard value.isFinite, value > 0 else {
                throw SunburstProjectionError.invalidMinimumAngularSpan(depth: depth + 1)
            }
        }
    }

    private static func value(of node: FileNode, metric: SunburstSizeMetric) -> UInt64 {
        switch metric {
        case .logical: node.logicalSize
        case .reportedAllocated: node.allocatedSize
        }
    }

    private static func sourceFlags(for node: FileNode) -> ProjectionFlags {
        node.flags.contains(.incompleteSubtree) ? [.incompleteSource] : []
    }

    private static func appendOmitted(value: UInt64, toCount count: inout UInt64, toValue total: inout UInt64, parent: NodeID) throws {
        let nextCount = count.addingReportingOverflow(1)
        let nextTotal = total.addingReportingOverflow(value)
        guard !nextCount.overflow, !nextTotal.overflow else { throw SunburstProjectionError.sizeOverflow(parent: parent) }
        count = nextCount.partialValue
        total = nextTotal.partialValue
    }

    private static func updating(
        _ node: ProjectionNode,
        firstChild: ProjectionNodeIndex? = nil,
        nextSibling: ProjectionNodeIndex? = nil,
        zeroCount: UInt64? = nil,
        hiddenCount: UInt64? = nil,
        hiddenValue: UInt64? = nil,
        flags additionalFlags: ProjectionFlags = []
    ) -> ProjectionNode {
        .init(
            item: node.item,
            parent: node.parent,
            firstChild: firstChild ?? node.firstChild,
            nextSibling: nextSibling ?? node.nextSibling,
            value: node.value,
            aggregatedDirectChildCount: node.aggregatedDirectChildCount,
            zeroValueDirectChildCount: zeroCount ?? node.zeroValueDirectChildCount,
            hiddenPositiveDirectChildCount: hiddenCount ?? node.hiddenPositiveDirectChildCount,
            hiddenPositiveDirectChildValue: hiddenValue ?? node.hiddenPositiveDirectChildValue,
            depth: node.depth,
            flags: node.flags.union(additionalFlags)
        )
    }
}

private struct ParentWork {
    let index: ProjectionNodeIndex
    let source: NodeID
    let span: Double
}

private struct ProjectionCandidate: Comparable {
    let source: NodeID
    let value: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value ? lhs.source > rhs.source : lhs.value < rhs.value
    }
}

private struct CandidateHeap {
    private let limit: Int
    private var storage: ContiguousArray<ProjectionCandidate> = []

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(limit)
    }

    mutating func insert(_ candidate: ProjectionCandidate) -> ProjectionCandidate? {
        if storage.count < limit {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
            return nil
        }
        guard let minimum = storage.first, minimum < candidate else { return candidate }
        storage[0] = candidate
        siftDown(from: 0)
        return minimum
    }

    func sortedDescending() -> [ProjectionCandidate] {
        storage.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.source < rhs.source : lhs.value > rhs.value
        }
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child] < storage[parent] else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { return }
            let right = left + 1
            let child = right < storage.count && storage[right] < storage[left] ? right : left
            guard storage[child] < storage[parent] else { return }
            storage.swapAt(parent, child)
            parent = child
        }
    }
}

private extension Double {
    static let twoPi = Double.pi * 2
}
