import HygieiaDomain

public enum FileActionDenial: Hashable, Sendable {
    case noRealSelection
    case snapshotNotCurrent
    case scanOrRefreshActive
    case identityUnavailable
    case scanRootProtected
    case visibleRootProtected
    case incompleteSubtree
    case inaccessible
    case volumeBoundary
    case unsupportedKind
    case actionAlreadyInProgress
    case invalidatedByEarlierAction
}

public enum FileActionEligibility: Hashable, Sendable {
    case allowed
    case denied(FileActionDenial)
}

public enum FileActionSnapshotFreshness: Hashable, Sendable {
    case current
    case staleWhileScanning
    case previousAfterFailedRescan
    case partial
    case staleAfterFileAction
}

public struct FileActionEligibilityContext: Sendable {
    public let action: FileActionKind
    public let selectedNode: NodeID?
    public let scanRoot: NodeID
    public let visibleRoot: NodeID
    public let freshness: FileActionSnapshotFreshness
    public let scanOrRefreshActive: Bool
    public let identityAvailable: Bool
    public let nodeKind: NodeKind?
    public let nodeFlags: NodeFlags
    public let actionInProgress: Bool
    public let invalidatedByEarlierAction: Bool

    public init(
        action: FileActionKind,
        selectedNode: NodeID?,
        scanRoot: NodeID,
        visibleRoot: NodeID,
        freshness: FileActionSnapshotFreshness,
        scanOrRefreshActive: Bool,
        identityAvailable: Bool,
        nodeKind: NodeKind?,
        nodeFlags: NodeFlags,
        actionInProgress: Bool,
        invalidatedByEarlierAction: Bool
    ) {
        self.action = action
        self.selectedNode = selectedNode
        self.scanRoot = scanRoot
        self.visibleRoot = visibleRoot
        self.freshness = freshness
        self.scanOrRefreshActive = scanOrRefreshActive
        self.identityAvailable = identityAvailable
        self.nodeKind = nodeKind
        self.nodeFlags = nodeFlags
        self.actionInProgress = actionInProgress
        self.invalidatedByEarlierAction = invalidatedByEarlierAction
    }
}

public enum FileActionEligibilityPolicy {
    public static func evaluate(_ context: FileActionEligibilityContext) -> FileActionEligibility {
        guard let node = context.selectedNode, let kind = context.nodeKind else { return .denied(.noRealSelection) }
        guard context.identityAvailable else { return .denied(.identityUnavailable) }
        guard !context.actionInProgress else { return .denied(.actionAlreadyInProgress) }
        guard !context.invalidatedByEarlierAction else { return .denied(.invalidatedByEarlierAction) }

        switch context.action {
        case .revealInFinder:
            return .allowed
        case .moveToTrash:
            guard context.freshness == .current else { return .denied(.snapshotNotCurrent) }
            guard !context.scanOrRefreshActive else { return .denied(.scanOrRefreshActive) }
            guard node != context.scanRoot else { return .denied(.scanRootProtected) }
            guard node != context.visibleRoot else { return .denied(.visibleRootProtected) }
            guard !context.nodeFlags.contains(.incompleteSubtree) else { return .denied(.incompleteSubtree) }
            guard !context.nodeFlags.contains(.inaccessible) else { return .denied(.inaccessible) }
            guard !context.nodeFlags.contains(.volumeBoundary) else { return .denied(.volumeBoundary) }
            guard kind != .other else { return .denied(.unsupportedKind) }
            return .allowed
        }
    }
}
