/// Compact immutable snapshot record. Sizes are inclusive accounted subtree totals.
public struct FileNode: Hashable, Sendable {
    public var logicalSize: UInt64
    public var allocatedSize: UInt64
    public var parent: NodeID
    public var firstChild: NodeID
    public var nextSibling: NodeID
    public var name: NameID
    public var kind: NodeKind
    public var flags: NodeFlags

    public init(
        logicalSize: UInt64,
        allocatedSize: UInt64,
        parent: NodeID,
        firstChild: NodeID = .invalid,
        nextSibling: NodeID = .invalid,
        name: NameID,
        kind: NodeKind,
        flags: NodeFlags = []
    ) {
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.parent = parent
        self.firstChild = firstChild
        self.nextSibling = nextSibling
        self.name = name
        self.kind = kind
        self.flags = flags
    }
}

public enum NodeKind: UInt8, Hashable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}
