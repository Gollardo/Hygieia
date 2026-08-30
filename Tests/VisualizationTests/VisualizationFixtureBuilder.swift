import HygieiaDomain

/// Test-only builder for small, exact `FileTree` fixtures.
struct VisualizationFixtureBuilder {
    struct Node {
        let name: String
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let kind: NodeKind
        let flags: NodeFlags
        let children: [Node]

        init(
            name: String,
            logicalSize: UInt64,
            allocatedSize: UInt64,
            kind: NodeKind = .regularFile,
            flags: NodeFlags = [],
            children: [Node] = []
        ) {
            self.name = name
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.kind = kind
            self.flags = flags
            self.children = children
        }

        static func directory(
            _ name: String,
            logicalSize: UInt64,
            allocatedSize: UInt64,
            flags: NodeFlags = [],
            children: [Node] = []
        ) -> Self {
            .init(
                name: name,
                logicalSize: logicalSize,
                allocatedSize: allocatedSize,
                kind: .directory,
                flags: flags,
                children: children
            )
        }
    }

    enum Error: Swift.Error, Equatable {
        case rootMustBeDirectory
        case childrenOnNonDirectory(name: String)
    }

    static func build(root: Node) throws -> FileTree {
        guard root.kind == .directory else { throw Error.rootMustBeDirectory }

        var names = NameStore()
        var nodes: ContiguousArray<FileNode> = []

        @discardableResult
        func append(_ fixture: Node, parent: NodeID) throws -> NodeID {
            guard fixture.kind == .directory || fixture.children.isEmpty else {
                throw Error.childrenOnNonDirectory(name: fixture.name)
            }

            let id = NodeID(rawValue: UInt32(nodes.count))
            let name = try names.append(fixture.name)
            nodes.append(
                .init(
                    logicalSize: fixture.logicalSize,
                    allocatedSize: fixture.allocatedSize,
                    parent: parent,
                    name: name,
                    kind: fixture.kind,
                    flags: fixture.flags
                )
            )

            var previousChild: NodeID?
            for child in fixture.children {
                let childID = try append(child, parent: id)
                if let previousChild {
                    nodes[Int(previousChild.rawValue)].nextSibling = childID
                } else {
                    nodes[Int(id.rawValue)].firstChild = childID
                }
                previousChild = childID
            }

            return id
        }

        let rootID = try append(root, parent: .invalid)
        return FileTree(root: rootID, nodes: nodes, names: names)
    }
}
