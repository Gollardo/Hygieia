public struct FileSizes: Hashable, Sendable {
    public let logical: UInt64
    public let allocated: UInt64
    public init(logical: UInt64, allocated: UInt64) { self.logical = logical; self.allocated = allocated }
}

public struct FileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

/// A rare per-node device override for snapshots that contain an explicitly
/// represented volume boundary. Most nodes share `NodeIdentityStore.primaryDevice`.
public struct NodeDeviceOverride: Hashable, Sendable {
    public let node: NodeID
    public let device: UInt64

    public init(node: NodeID, device: UInt64) {
        self.node = node
        self.device = device
    }
}

/// Compact snapshot-local identity evidence. It intentionally lives outside
/// `FileNode` so action safety does not enlarge the scanner hot record.
public struct NodeIdentityStore: Sendable {
    public let primaryDevice: UInt64
    private let inodes: ContiguousArray<UInt64>
    private let knownWords: ContiguousArray<UInt64>
    private let deviceOverridesByNode: ContiguousArray<NodeDeviceOverride>

    public init(identities: ContiguousArray<FileIdentity?>, primaryDevice: UInt64? = nil) {
        precondition(identities.count <= Int(UInt32.max), "Identity sidecar exceeds NodeID capacity")
        let resolvedPrimaryDevice = primaryDevice ?? identities.compactMap { $0?.device }.first ?? 0
        self.primaryDevice = resolvedPrimaryDevice
        self.inodes = ContiguousArray(identities.map { $0?.inode ?? 0 })

        var words = ContiguousArray<UInt64>(repeating: 0, count: (identities.count + 63) / 64)
        var overrides: ContiguousArray<NodeDeviceOverride> = []
        for (index, identity) in identities.enumerated() {
            guard let identity else { continue }
            words[index / 64] |= UInt64(1) << UInt64(index % 64)
            if identity.device != resolvedPrimaryDevice {
                overrides.append(.init(node: NodeID(rawValue: UInt32(index)), device: identity.device))
            }
        }
        self.knownWords = words
        self.deviceOverridesByNode = overrides
    }

    public static func unavailable(count: Int) -> Self {
        precondition(count >= 0)
        return .init(identities: ContiguousArray(repeating: nil, count: count), primaryDevice: 0)
    }

    public var count: Int { inodes.count }

    public func identity(for node: NodeID) -> FileIdentity? {
        let index = Int(node.rawValue)
        guard node.isValid, inodes.indices.contains(index), isKnown(index) else { return nil }
        return .init(device: device(for: node), inode: inodes[index])
    }

    private func isKnown(_ index: Int) -> Bool {
        let word = index / 64
        let bit = index % 64
        guard knownWords.indices.contains(word) else { return false }
        return (knownWords[word] & (UInt64(1) << UInt64(bit))) != 0
    }

    private func device(for node: NodeID) -> UInt64 {
        var low = 0
        var high = deviceOverridesByNode.count
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = deviceOverridesByNode[middle]
            if candidate.node == node { return candidate.device }
            if candidate.node < node { low = middle + 1 } else { high = middle }
        }
        return primaryDevice
    }
}

public struct HardLinkGroupID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct HardLinkGroup: Hashable, Sendable {
    public let identity: FileIdentity
    public let canonicalNode: NodeID
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let reportedLinkCount: UInt32
    public let observedLinkCount: UInt32
    public init(identity: FileIdentity, canonicalNode: NodeID, logicalSize: UInt64, allocatedSize: UInt64, reportedLinkCount: UInt32, observedLinkCount: UInt32) {
        self.identity = identity
        self.canonicalNode = canonicalNode
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.reportedLinkCount = reportedLinkCount
        self.observedLinkCount = observedLinkCount
    }
}

public struct HardLinkMembership: Hashable, Sendable {
    public let node: NodeID
    public let group: HardLinkGroupID
    public init(node: NodeID, group: HardLinkGroupID) { self.node = node; self.group = group }
}

public struct HardLinkTable: Sendable {
    private let groups: ContiguousArray<HardLinkGroup>
    private let membershipsByNode: ContiguousArray<HardLinkMembership>

    public init(groups: ContiguousArray<HardLinkGroup> = [], membershipsByNode: ContiguousArray<HardLinkMembership> = []) {
        self.groups = groups
        self.membershipsByNode = membershipsByNode
    }

    public var count: Int { groups.count }
    public func group(for id: HardLinkGroupID) -> HardLinkGroup? {
        let index = Int(id.rawValue)
        return groups.indices.contains(index) ? groups[index] : nil
    }

    public func groupID(for node: NodeID) -> HardLinkGroupID? {
        var low = 0
        var high = membershipsByNode.count
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = membershipsByNode[middle]
            if candidate.node == node { return candidate.group }
            if candidate.node < node { low = middle + 1 } else { high = middle }
        }
        return nil
    }
}

public struct FileTree: Sendable {
    public let root: NodeID
    private let nodes: ContiguousArray<FileNode>
    private let names: NameStore
    private let hardLinks: HardLinkTable
    private let identities: NodeIdentityStore

    public init(
        root: NodeID,
        nodes: ContiguousArray<FileNode>,
        names: NameStore,
        hardLinks: HardLinkTable = .init(),
        identities: NodeIdentityStore? = nil
    ) {
        precondition(root == NodeID(rawValue: 0), "FileTree root must be NodeID(0)")
        precondition(nodes.count <= Int(UInt32.max), "FileTree exceeds NodeID capacity")
        precondition(!nodes.isEmpty, "FileTree must contain a root")
        precondition(nodes[0].parent == .invalid && nodes[0].kind == .directory, "FileTree root must be a directory with an invalid parent")
        self.root = root
        self.nodes = nodes
        self.names = names
        self.hardLinks = hardLinks
        let identities = identities ?? .unavailable(count: nodes.count)
        precondition(identities.count == nodes.count, "Identity sidecar must match FileTree node count")
        self.identities = identities
    }

    public var count: Int { nodes.count }
    public var hardLinkGroupCount: Int { hardLinks.count }

    public func identity(for id: NodeID) -> FileIdentity? { identities.identity(for: id) }

    /// Returns the accounting group for a node when it is a tracked hard link.
    /// The group is snapshot-local, just like the node ID.
    public func hardLinkGroup(for id: NodeID) -> HardLinkGroup? {
        guard let groupID = hardLinks.groupID(for: id) else { return nil }
        return hardLinks.group(for: groupID)
    }

    public subscript(id: NodeID) -> FileNode {
        precondition(id.isValid && Int(id.rawValue) < nodes.count, "Invalid snapshot-local NodeID")
        return nodes[Int(id.rawValue)]
    }

    public func node(for id: NodeID) -> FileNode? {
        guard id.isValid, Int(id.rawValue) < nodes.count else { return nil }
        return nodes[Int(id.rawValue)]
    }

    public func name(for id: NodeID) -> String {
        guard let name = names.string(for: self[id].name) else { preconditionFailure("Validated tree has invalid NameID") }
        return name
    }

    public func children(of id: NodeID) -> ChildSequence { ChildSequence(tree: self, parent: id) }

    public func pathComponents(to id: NodeID) -> [String] {
        _ = self[id]
        var result: [String] = []
        var current = id
        while current != root {
            result.append(name(for: current))
            current = self[current].parent
        }
        result.append(name(for: root))
        return result.reversed()
    }

    public func intrinsicSizes(for id: NodeID) -> FileSizes {
        let node = self[id]
        guard node.flags.contains(.hardLinkAlias), let groupID = hardLinks.groupID(for: id), let group = hardLinks.group(for: groupID) else {
            return FileSizes(logical: node.logicalSize, allocated: node.allocatedSize)
        }
        return FileSizes(logical: group.logicalSize, allocated: group.allocatedSize)
    }

    public struct ChildSequence: Sequence, Sendable {
        private let tree: FileTree
        private let parent: NodeID
        fileprivate init(tree: FileTree, parent: NodeID) { self.tree = tree; self.parent = parent }
        public func makeIterator() -> Iterator { Iterator(tree: tree, next: tree[parent].firstChild) }
        public struct Iterator: IteratorProtocol {
            private let tree: FileTree
            private var nextID: NodeID
            fileprivate init(tree: FileTree, next: NodeID) { self.tree = tree; self.nextID = next }
            public mutating func next() -> NodeID? {
                guard nextID.isValid else { return nil }
                let result = nextID
                nextID = tree[result].nextSibling
                return result
            }
        }
    }
}
