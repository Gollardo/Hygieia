import HygieiaDomain

public enum FileTreeBuildError: Error, Equatable, Sendable {
    case nodeCapacityExceeded
    case nameStoreCapacityExceeded
    case invalidParent
    case parentIsNotDirectory
    case sizeOverflow
    case invariantViolation(String)
}

/// Single-owner mutable construction state. It is deliberately not Sendable.
final class FileTreeBuilder {
    private struct MutableHardLinkGroup {
        let identity: FileIdentity
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let reportedLinkCount: UInt32
        var members: ContiguousArray<NodeID>
    }

    private var nodes: ContiguousArray<FileNode> = []
    private var names = NameStore()
    private var lastChildByParent: ContiguousArray<NodeID> = []
    private var hardLinkGroups: [FileIdentity: MutableHardLinkGroup] = [:]
    private var identities: ContiguousArray<FileIdentity?> = []
    private(set) var hardLinkGroupsOutsideRoot: ContiguousArray<NodeID> = []

    init(rootName: String, rootIdentity: FileIdentity) throws {
        let name = try appendName(rootName)
        nodes.append(FileNode(logicalSize: 0, allocatedSize: 0, parent: .invalid, name: name, kind: .directory))
        lastChildByParent.append(.invalid)
        identities.append(rootIdentity)
    }

    var count: Int { nodes.count }
    var root: NodeID { NodeID(rawValue: 0) }

    func node(_ id: NodeID) -> FileNode { nodes[Int(id.rawValue)] }

    func append(
        parent: NodeID,
        name: String,
        kind: NodeKind,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        flags: NodeFlags,
        identity: FileIdentity?,
        reportedLinkCount: UInt32
    ) throws -> NodeID {
        guard parent.isValid, Int(parent.rawValue) < nodes.count else { throw FileTreeBuildError.invalidParent }
        guard nodes[Int(parent.rawValue)].kind == .directory else { throw FileTreeBuildError.parentIsNotDirectory }
        guard nodes.count < Int(UInt32.max) else { throw FileTreeBuildError.nodeCapacityExceeded }
        let nameID = try appendName(name)
        let id = NodeID(rawValue: UInt32(nodes.count))
        nodes.append(FileNode(logicalSize: logicalSize, allocatedSize: allocatedSize, parent: parent, name: nameID, kind: kind, flags: flags))
        lastChildByParent.append(.invalid)
        identities.append(identity)
        let parentIndex = Int(parent.rawValue)
        let lastChild = lastChildByParent[parentIndex]
        if lastChild.isValid {
            nodes[Int(lastChild.rawValue)].nextSibling = id
        } else {
            nodes[parentIndex].firstChild = id
        }
        lastChildByParent[parentIndex] = id

        if kind == .regularFile, reportedLinkCount > 1, let identity {
            nodes[Int(id.rawValue)].flags.insert(.hardLink)
            if var group = hardLinkGroups[identity] {
                group.members.append(id)
                hardLinkGroups[identity] = group
            } else {
                hardLinkGroups[identity] = MutableHardLinkGroup(
                    identity: identity,
                    logicalSize: logicalSize,
                    allocatedSize: allocatedSize,
                    reportedLinkCount: reportedLinkCount,
                    members: [id]
                )
            }
        }
        return id
    }

    func mark(_ id: NodeID, adding flags: NodeFlags) {
        nodes[Int(id.rawValue)].flags.formUnion(flags)
    }

    func relativePath(for id: NodeID) -> String {
        var components: [String] = []
        var current = id
        while current != root {
            let node = nodes[Int(current.rawValue)]
            components.append(names.string(for: node.name)!)
            current = node.parent
        }
        return components.reversed().joined(separator: "/")
    }

    func finalize() throws -> FileTree {
        let table = try finalizeHardLinks()
        try aggregateSizesAndIncompleteFlags()
        try validate()
        return FileTree(
            root: root,
            nodes: nodes,
            names: names,
            hardLinks: table,
            identities: .init(identities: identities)
        )
    }

    private func appendName(_ name: String) throws -> NameID {
        do { return try names.append(name) }
        catch { throw FileTreeBuildError.nameStoreCapacityExceeded }
    }

    private func finalizeHardLinks() throws -> HardLinkTable {
        var groups: ContiguousArray<HardLinkGroup> = []
        var memberships: ContiguousArray<HardLinkMembership> = []
        for group in hardLinkGroups.values.sorted(by: { lhs, rhs in
            if lhs.identity.device != rhs.identity.device { return lhs.identity.device < rhs.identity.device }
            return lhs.identity.inode < rhs.identity.inode
        }) {
            guard groups.count < Int(UInt32.max) else { throw FileTreeBuildError.nodeCapacityExceeded }
            guard let canonical = group.members.min(by: { relativePath(for: $0).utf8.lexicographicallyPrecedes(relativePath(for: $1).utf8) }) else { continue }
            for member in group.members where member != canonical {
                let index = Int(member.rawValue)
                nodes[index].logicalSize = 0
                nodes[index].allocatedSize = 0
                nodes[index].flags.insert(.hardLinkAlias)
            }
            let groupID = HardLinkGroupID(rawValue: UInt32(groups.count))
            if group.members.count < Int(group.reportedLinkCount) { hardLinkGroupsOutsideRoot.append(canonical) }
            groups.append(HardLinkGroup(
                identity: group.identity,
                canonicalNode: canonical,
                logicalSize: group.logicalSize,
                allocatedSize: group.allocatedSize,
                reportedLinkCount: group.reportedLinkCount,
                observedLinkCount: UInt32(clamping: group.members.count)
            ))
            memberships.append(contentsOf: group.members.map { HardLinkMembership(node: $0, group: groupID) })
        }
        memberships.sort { $0.node < $1.node }
        return HardLinkTable(groups: groups, membershipsByNode: memberships)
    }

    private func aggregateSizesAndIncompleteFlags() throws {
        guard nodes.count > 1 else { return }
        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            let child = nodes[index]
            let parentIndex = Int(child.parent.rawValue)
            let logical = nodes[parentIndex].logicalSize.addingReportingOverflow(child.logicalSize)
            let allocated = nodes[parentIndex].allocatedSize.addingReportingOverflow(child.allocatedSize)
            guard !logical.overflow, !allocated.overflow else { throw FileTreeBuildError.sizeOverflow }
            nodes[parentIndex].logicalSize = logical.partialValue
            nodes[parentIndex].allocatedSize = allocated.partialValue
            if child.flags.contains(.incompleteSubtree) {
                nodes[parentIndex].flags.insert(.incompleteSubtree)
            }
        }
    }

    private func validate() throws {
        guard nodes.indices.contains(0), nodes[0].parent == .invalid, nodes[0].kind == .directory else {
            throw FileTreeBuildError.invariantViolation("invalid root")
        }
        var reached = ContiguousArray(repeating: false, count: nodes.count)
        var stack: ContiguousArray<NodeID> = [root]
        reached[0] = true
        while let parent = stack.popLast() {
            var child = nodes[Int(parent.rawValue)].firstChild
            while child.isValid {
                let index = Int(child.rawValue)
                guard index < nodes.count, !reached[index], nodes[index].parent == parent, child > parent else {
                    throw FileTreeBuildError.invariantViolation("broken child chain")
                }
                reached[index] = true
                stack.append(child)
                child = nodes[index].nextSibling
            }
        }
        guard reached.allSatisfy({ $0 }) else { throw FileTreeBuildError.invariantViolation("unreachable node") }
    }
}
