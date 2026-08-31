/// Rebuilds an immutable snapshot after a confirmed, known deletion without
/// reading the filesystem. It is intentionally limited to roots whose system
/// Trash operations have already succeeded.
public enum KnownDeletionReconciliationError: Error, Equatable, Sendable {
    case invalidMovedRoot(NodeID)
    case rootRemoval
    case overlappingMovedRoots
    case nameStoreCapacityExceeded
    case sizeOverflow
    case invariantViolation(String)
}

public struct KnownDeletionReconciliation: Sendable {
    public let tree: FileTree
    /// IDs are valid only for nodes that survived the rebuild.
    public let survivingNodeIDMap: [NodeID: NodeID]
}

public enum KnownDeletionReconciler {
    public static func reconcile(
        tree: FileTree,
        removing movedRoots: [NodeID]
    ) throws -> KnownDeletionReconciliation {
        guard !movedRoots.isEmpty else {
            return .init(tree: tree, survivingNodeIDMap: Dictionary(uniqueKeysWithValues: (0..<tree.count).map {
                let id = NodeID(rawValue: UInt32($0)); return (id, id)
            }))
        }

        var roots = Set<NodeID>()
        for root in movedRoots {
            guard tree.node(for: root) != nil else { throw KnownDeletionReconciliationError.invalidMovedRoot(root) }
            guard root != tree.root else { throw KnownDeletionReconciliationError.rootRemoval }
            roots.insert(root)
        }
        for root in roots {
            var parent = tree[root].parent
            while parent.isValid {
                if roots.contains(parent) { throw KnownDeletionReconciliationError.overlappingMovedRoots }
                parent = tree[parent].parent
            }
        }

        var removed = ContiguousArray(repeating: false, count: tree.count)
        var stack = Array(roots)
        while let current = stack.popLast() {
            let index = Int(current.rawValue)
            guard !removed[index] else { continue }
            removed[index] = true
            stack.append(contentsOf: tree.children(of: current))
        }

        var nodes: ContiguousArray<FileNode> = []
        var names = NameStore()
        var identities: ContiguousArray<FileIdentity?> = []
        var oldToNew: [NodeID: NodeID] = [:]
        var oldIDs: ContiguousArray<NodeID> = []
        for raw in 0..<tree.count where !removed[raw] {
            let oldID = NodeID(rawValue: UInt32(raw))
            var node = tree[oldID]
            do { node.name = try names.append(tree.name(for: oldID)) }
            catch { throw KnownDeletionReconciliationError.nameStoreCapacityExceeded }
            if node.kind == .directory {
                node.logicalSize = 0
                node.allocatedSize = 0
            }
            if let group = tree.hardLinkGroup(for: oldID) {
                node.logicalSize = group.logicalSize
                node.allocatedSize = group.allocatedSize
                node.flags.remove(.hardLinkAlias)
            }
            node.parent = oldID == tree.root ? .invalid : (oldToNew[tree[oldID].parent] ?? .invalid)
            guard oldID == tree.root || node.parent.isValid else {
                throw KnownDeletionReconciliationError.invariantViolation("surviving node has no surviving parent")
            }
            node.firstChild = .invalid
            node.nextSibling = .invalid
            let newID = NodeID(rawValue: UInt32(nodes.count))
            nodes.append(node)
            identities.append(tree.identity(for: oldID))
            oldToNew[oldID] = newID
            oldIDs.append(oldID)
        }
        guard !nodes.isEmpty else { throw KnownDeletionReconciliationError.invariantViolation("missing root") }

        var lastChild = ContiguousArray(repeating: NodeID.invalid, count: nodes.count)
        for index in nodes.indices where index != 0 {
            let child = NodeID(rawValue: UInt32(index))
            let parent = nodes[index].parent
            let parentIndex = Int(parent.rawValue)
            if lastChild[parentIndex].isValid {
                nodes[Int(lastChild[parentIndex].rawValue)].nextSibling = child
            } else {
                nodes[parentIndex].firstChild = child
            }
            lastChild[parentIndex] = child
        }

        struct MutableGroup {
            let identity: FileIdentity
            let logicalSize: UInt64
            let allocatedSize: UInt64
            let reportedLinkCount: UInt32
            var members: ContiguousArray<NodeID>
        }
        var mutableGroups: [FileIdentity: MutableGroup] = [:]
        for (index, oldID) in oldIDs.enumerated() {
            guard let group = tree.hardLinkGroup(for: oldID) else { continue }
            let newID = NodeID(rawValue: UInt32(index))
            if var existing = mutableGroups[group.identity] {
                existing.members.append(newID)
                mutableGroups[group.identity] = existing
            } else {
                mutableGroups[group.identity] = .init(identity: group.identity, logicalSize: group.logicalSize, allocatedSize: group.allocatedSize, reportedLinkCount: group.reportedLinkCount, members: [newID])
            }
        }
        var groups: ContiguousArray<HardLinkGroup> = []
        var memberships: ContiguousArray<HardLinkMembership> = []
        for group in mutableGroups.values.sorted(by: {
            $0.identity.device == $1.identity.device ? $0.identity.inode < $1.identity.inode : $0.identity.device < $1.identity.device
        }) {
            guard let canonical = group.members.min(by: { relativePath($0, nodes: nodes, names: names).utf8.lexicographicallyPrecedes(relativePath($1, nodes: nodes, names: names).utf8) }) else { continue }
            for member in group.members where member != canonical {
                let index = Int(member.rawValue)
                nodes[index].logicalSize = 0
                nodes[index].allocatedSize = 0
                nodes[index].flags.insert(.hardLinkAlias)
            }
            let groupID = HardLinkGroupID(rawValue: UInt32(groups.count))
            groups.append(.init(identity: group.identity, canonicalNode: canonical, logicalSize: group.logicalSize, allocatedSize: group.allocatedSize, reportedLinkCount: group.reportedLinkCount, observedLinkCount: UInt32(clamping: group.members.count)))
            memberships.append(contentsOf: group.members.map { .init(node: $0, group: groupID) })
        }
        memberships.sort { $0.node < $1.node }

        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            let child = nodes[index]
            let parentIndex = Int(child.parent.rawValue)
            let logical = nodes[parentIndex].logicalSize.addingReportingOverflow(child.logicalSize)
            let allocated = nodes[parentIndex].allocatedSize.addingReportingOverflow(child.allocatedSize)
            guard !logical.overflow, !allocated.overflow else { throw KnownDeletionReconciliationError.sizeOverflow }
            nodes[parentIndex].logicalSize = logical.partialValue
            nodes[parentIndex].allocatedSize = allocated.partialValue
            if child.flags.contains(.incompleteSubtree) { nodes[parentIndex].flags.insert(.incompleteSubtree) }
        }
        try validate(nodes)
        return .init(tree: .init(root: .init(rawValue: 0), nodes: nodes, names: names, hardLinks: .init(groups: groups, membershipsByNode: memberships), identities: .init(identities: identities)), survivingNodeIDMap: oldToNew)
    }

    private static func relativePath(_ id: NodeID, nodes: ContiguousArray<FileNode>, names: NameStore) -> String {
        var parts: [String] = []
        var current = id
        while current.isValid && current.rawValue != 0 {
            let node = nodes[Int(current.rawValue)]
            parts.append(names.string(for: node.name) ?? "")
            current = node.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    private static func validate(_ nodes: ContiguousArray<FileNode>) throws {
        guard nodes.first?.parent == .invalid, nodes.first?.kind == .directory else { throw KnownDeletionReconciliationError.invariantViolation("invalid root") }
        var reached = ContiguousArray(repeating: false, count: nodes.count)
        var stack: ContiguousArray<NodeID> = [.init(rawValue: 0)]
        reached[0] = true
        while let parent = stack.popLast() {
            var child = nodes[Int(parent.rawValue)].firstChild
            while child.isValid {
                let index = Int(child.rawValue)
                guard nodes.indices.contains(index), !reached[index], nodes[index].parent == parent, child > parent else { throw KnownDeletionReconciliationError.invariantViolation("broken child chain") }
                reached[index] = true
                stack.append(child)
                child = nodes[index].nextSibling
            }
        }
        guard reached.allSatisfy({ $0 }) else { throw KnownDeletionReconciliationError.invariantViolation("unreachable node") }
    }
}
