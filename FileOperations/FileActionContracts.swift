import Foundation
import HygieiaDomain

public enum FileActionKind: Hashable, Sendable {
    case revealInFinder
    case moveToTrash
}

public struct SnapshotPathComponent: Hashable, Sendable {
    public let node: NodeID
    public let name: String
    public let expectedIdentity: FileIdentity
    public let expectedKind: NodeKind

    public init(node: NodeID, name: String, expectedIdentity: FileIdentity, expectedKind: NodeKind) {
        self.node = node
        self.name = name
        self.expectedIdentity = expectedIdentity
        self.expectedKind = expectedKind
    }
}

public struct SnapshotFileActionTarget: Sendable {
    public let node: NodeID
    public let rootURL: URL
    public let rootIdentity: FileIdentity
    public let componentsFromRootChild: ContiguousArray<SnapshotPathComponent>
    public let expectedKind: NodeKind
    public let snapshotFlags: NodeFlags
    public let logicalSize: UInt64
    public let reportedAllocatedSize: UInt64

    public init(
        node: NodeID,
        rootURL: URL,
        rootIdentity: FileIdentity,
        componentsFromRootChild: ContiguousArray<SnapshotPathComponent>,
        expectedKind: NodeKind,
        snapshotFlags: NodeFlags,
        logicalSize: UInt64,
        reportedAllocatedSize: UInt64
    ) {
        self.node = node
        self.rootURL = rootURL
        self.rootIdentity = rootIdentity
        self.componentsFromRootChild = componentsFromRootChild
        self.expectedKind = expectedKind
        self.snapshotFlags = snapshotFlags
        self.logicalSize = logicalSize
        self.reportedAllocatedSize = reportedAllocatedSize
    }
}

public struct ValidatedFileActionTarget: Sendable {
    public let snapshot: SnapshotFileActionTarget
    public let itemURL: URL
    public let validatedIdentity: FileIdentity
    public let validatedKind: NodeKind
    public let validatedAt: ContinuousClock.Instant

    public init(
        snapshot: SnapshotFileActionTarget,
        itemURL: URL,
        validatedIdentity: FileIdentity,
        validatedKind: NodeKind,
        validatedAt: ContinuousClock.Instant
    ) {
        self.snapshot = snapshot
        self.itemURL = itemURL
        self.validatedIdentity = validatedIdentity
        self.validatedKind = validatedKind
        self.validatedAt = validatedAt
    }
}

public enum FileActionError: Error, Equatable, Sendable {
    case invalidTarget
    case invalidPathComponent(node: NodeID)
    case rootMissing
    case rootChanged
    case ancestorMissing(node: NodeID)
    case ancestorChanged(node: NodeID)
    case symbolicLinkInAncestor(node: NodeID)
    case targetMissing
    case targetChanged
    case permissionDenied(code: Int32)
    case readOnlyFileSystem(code: Int32)
    case volumeUnavailable(code: Int32)
    case trashUnavailable(code: Int32?)
    case system(domain: String, code: Int)
}

public protocol FileActionTargetValidating: Sendable {
    func validate(_ target: SnapshotFileActionTarget) async throws -> ValidatedFileActionTarget
}

public enum SnapshotFileActionTargetBuilder {
    /// Builds a target from the immutable displayed snapshot. The URL authority
    /// remains the original selected root; no absolute path is retained in it.
    public static func make(node: NodeID, tree: FileTree, rootURL: URL) throws -> SnapshotFileActionTarget {
        guard rootURL.isFileURL, let targetNode = tree.node(for: node), let rootIdentity = tree.identity(for: tree.root) else {
            throw FileActionError.invalidTarget
        }

        var reversed: ContiguousArray<SnapshotPathComponent> = []
        var current = node
        var remainingNodes = tree.count
        while current != tree.root {
            guard remainingNodes > 0 else { throw FileActionError.invalidTarget }
            remainingNodes -= 1
            guard let identity = tree.identity(for: current) else { throw FileActionError.invalidTarget }
            let fileNode = tree[current]
            reversed.append(.init(node: current, name: tree.name(for: current), expectedIdentity: identity, expectedKind: fileNode.kind))
            current = fileNode.parent
            guard current.isValid else { throw FileActionError.invalidTarget }
        }

        return .init(
            node: node,
            rootURL: rootURL,
            rootIdentity: rootIdentity,
            componentsFromRootChild: ContiguousArray(reversed.reversed()),
            expectedKind: targetNode.kind,
            snapshotFlags: targetNode.flags,
            logicalSize: targetNode.logicalSize,
            reportedAllocatedSize: targetNode.allocatedSize
        )
    }
}
