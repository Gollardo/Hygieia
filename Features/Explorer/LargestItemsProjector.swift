import HygieiaDomain

protocol LargestItemsProjecting: Sendable {
    func project(tree: FileTree, root: NodeID, metric: SizeMetric, limit: Int) async throws -> [LargestItemRow]
}

struct LargestItemsProjector: LargestItemsProjecting {
    func project(tree: FileTree, root: NodeID, metric: SizeMetric, limit: Int) async throws -> [LargestItemRow] {
        try await Task.detached(priority: .userInitiated) {
            guard limit > 0, tree.node(for: root) != nil else { return [] }
            var heap = CandidateHeap(limit: limit)
            var visited = 0
            for id in tree.children(of: root) {
                if visited.isMultiple(of: 4_096), Task.isCancelled {
                    throw CancellationError()
                }
                let node = tree[id]
                heap.insert(.init(id: id, size: Self.size(of: node, metric: metric)))
                visited += 1
            }

            return heap.sortedDescending().map { candidate in
                let node = tree[candidate.id]
                let components = tree.pathComponents(to: candidate.id)
                return LargestItemRow(
                    id: candidate.id,
                    name: tree.name(for: candidate.id),
                    relativePath: components.dropFirst().joined(separator: "/"),
                    kind: node.kind,
                    logicalSize: node.logicalSize,
                    allocatedSize: node.allocatedSize,
                    flags: node.flags
                )
            }
        }.value
    }

    func project(tree: FileTree, metric: SizeMetric, limit: Int) async throws -> [LargestItemRow] {
        try await project(tree: tree, root: tree.root, metric: metric, limit: limit)
    }

    private static func size(of node: FileNode, metric: SizeMetric) -> UInt64 {
        switch metric {
        case .reportedAllocated: node.allocatedSize
        case .logical: node.logicalSize
        }
    }

}

private struct Candidate: Comparable, Sendable {
    let id: NodeID
    let size: UInt64

    static func < (lhs: Candidate, rhs: Candidate) -> Bool {
        lhs.size == rhs.size ? lhs.id > rhs.id : lhs.size < rhs.size
    }
}

private struct CandidateHeap: Sendable {
    private let limit: Int
    private var storage: [Candidate] = []

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(limit)
    }

    mutating func insert(_ candidate: Candidate) {
        if storage.count < limit {
            storage.append(candidate)
            siftUp(from: storage.count - 1)
        } else if let minimum = storage.first, minimum < candidate {
            storage[0] = candidate
            siftDown(from: 0)
        }
    }

    func sortedDescending() -> [Candidate] {
        storage.sorted { lhs, rhs in
            lhs.size == rhs.size ? lhs.id < rhs.id : lhs.size > rhs.size
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
