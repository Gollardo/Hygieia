import Foundation
import Observation
import HygieiaDomain
import HygieiaScannerCore
import HygieiaVisualization
import HygieiaFileOperations

struct DisplayedScanResult: Sendable {
    enum Freshness: Equatable, Sendable {
        case current
        case staleWhileScanning
        case previousAfterFailedRescan
        case partial
        case staleAfterFileAction
        case sourceUnavailable
    }

    let result: ScanResult
    let freshness: Freshness

    var statusTitle: String {
        switch freshness {
        case .current: result.hasIncompleteCoverage ? "Coverage incomplete" : "Scan finished"
        case .partial: "Scan cancelled · partial result"
        case .sourceUnavailable: "Source unavailable"
        case .staleWhileScanning: "Rescanning · previous result"
        case .previousAfterFailedRescan: "Rescan failed · previous result"
        case .staleAfterFileAction: "File changed · sizes are stale"
        }
    }

    var hasWarning: Bool { freshness != .current || result.hasIncompleteCoverage }
}

struct ScanFailurePresentation: Equatable, Sendable {
    let title: String
    let message: String

    static func make(from error: Error) -> Self {
        switch error {
        case ScanError.rootMissing:
            .init(title: "Folder is no longer available", message: "Choose another folder and try again.")
        case ScanError.rootIsNotDirectory:
            .init(title: "Selected item is not a folder", message: "Choose a local folder.")
        case ScanError.rootIsSymbolicLink:
            .init(title: "Symbolic-link roots are not scanned", message: "Choose the actual local folder.")
        case ScanError.rootIsNotLocalVolume:
            .init(title: "Network volumes are not scanned", message: "Choose a local disk or a folder on one.")
        case ScanError.rootLocalityUnknown:
            .init(title: "Disk availability could not be verified", message: "Reconnect the disk, then choose the folder again.")
        case ScanError.rootPermissionDenied:
            .init(title: "Access to the selected folder was denied", message: "Choose the folder again or check its permissions. This error does not establish Full Disk Access status.")
        case ScanError.rootChanged:
            .init(title: "Selected source has changed", message: "The folder or disk no longer matches this snapshot. Choose it again to start a new scan.")
        case ScanError.rootMetadataFailed:
            .init(title: "Folder metadata could not be read", message: "Retry or choose another folder.")
        case ScanError.builder:
            .init(title: "Scan could not produce a valid result", message: "Retry the scan. The invalid snapshot was not shown.")
        default:
            .init(title: "Scan failed", message: "Retry or choose another folder.")
        }
    }
}

enum ExplorerSelection: Hashable, Sendable {
    case node(NodeID)
    case other(parent: NodeID)

    var item: SunburstItemID {
        switch self {
        case .node(let node): .node(node)
        case .other(let parent): .other(parent: parent)
        }
    }
}

struct ExplorerState: Sendable {
    var visibleRoot: NodeID
    var selection: ExplorerSelection?
    var hoveredItem: SunburstItemID?
    var backStack: [NodeID]
    var forwardStack: [NodeID]
}

enum ProjectionPhase: Equatable, Sendable {
    case idle
    case preparingProjection
    case layingOut
    case ready
    case failed(String)
}

struct ExplorerDetails: Sendable {
    let selection: ExplorerSelection
    let name: String
    let relativePath: String
    let kind: NodeKind?
    let logicalSize: UInt64?
    let allocatedSize: UInt64?
    let flags: NodeFlags
    let aggregatedDirectChildCount: UInt64?
    let aggregatedValue: UInt64?
    let nodeID: NodeID?
}

struct ScanTimeEstimate: Equatable, Sendable {
    let lowerBoundSeconds: UInt64
    let upperBoundSeconds: UInt64
}

struct ScanTimeEstimator: Sendable {
    private struct Sample: Sendable {
        let completedDirectories: UInt64
        let remainingKnownDirectories: UInt64
        let elapsedSeconds: Double
    }

    private var previous: Sample?
    private var smoothedDirectoriesPerSecond: Double?
    private var consecutiveQueueContractions = 0

    mutating func reset() {
        previous = nil
        smoothedDirectoriesPerSecond = nil
        consecutiveQueueContractions = 0
    }

    mutating func update(
        completedDirectories: UInt64,
        pendingDirectories: UInt64,
        inFlightDirectories: UInt64,
        elapsed: Duration
    ) -> ScanTimeEstimate? {
        let elapsedSeconds = Self.seconds(elapsed)
        let remaining = pendingDirectories.addingReportingOverflow(inFlightDirectories).partialValue
        let current = Sample(
            completedDirectories: completedDirectories,
            remainingKnownDirectories: remaining,
            elapsedSeconds: elapsedSeconds
        )
        defer { previous = current }

        guard let previous,
              elapsedSeconds > previous.elapsedSeconds,
              completedDirectories >= previous.completedDirectories else { return nil }

        let completedDelta = completedDirectories - previous.completedDirectories
        let timeDelta = elapsedSeconds - previous.elapsedSeconds
        if completedDelta > 0, timeDelta > 0 {
            let instantaneousRate = Double(completedDelta) / timeDelta
            if instantaneousRate.isFinite, instantaneousRate > 0 {
                smoothedDirectoriesPerSecond = smoothedDirectoriesPerSecond
                    .map { $0 * 0.72 + instantaneousRate * 0.28 }
                    ?? instantaneousRate
            }
        }

        if remaining <= previous.remainingKnownDirectories {
            consecutiveQueueContractions += 1
        } else {
            consecutiveQueueContractions = 0
        }

        guard elapsedSeconds >= 5,
              completedDirectories >= 32,
              consecutiveQueueContractions >= 2,
              remaining > 0,
              let rate = smoothedDirectoriesPerSecond,
              rate > 0 else { return nil }

        let pointEstimate = Double(remaining) / rate
        guard pointEstimate.isFinite, pointEstimate > 0 else { return nil }
        let lower = UInt64(max(5, (pointEstimate * 0.70).rounded(.down)))
        let upper = UInt64(max(Double(lower + 5), (pointEstimate * 1.60).rounded(.up)))
        return .init(lowerBoundSeconds: lower, upperBoundSeconds: upper)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
@Observable
final class ScanFeatureModel {
    static let rowLimit = 200

    private(set) var phase: ScanPhase = .idle
    private(set) var selectedRoot: URL?
    private(set) var progress: ScanProgress?
    private(set) var displayedResult: DisplayedScanResult?
    private(set) var rows: [LargestItemRow] = []
    private(set) var presentedError: ScanFailurePresentation?
    private(set) var explorer: ExplorerState?
    private(set) var sunburstProjection: SunburstProjection?
    private(set) var sunburstLayout: SunburstLayoutResult?
    private(set) var projectionPhase: ProjectionPhase = .idle
    private(set) var viewport: SunburstViewport = .init(width: 640, height: 480)
    private(set) var metric: SizeMetric = .reportedAllocated
    private(set) var fileActionPhase: FileActionPhase = .idle
    private(set) var invalidatedSubtrees: [InvalidatedSubtree] = []
    private(set) var markedTrashItems: [NodeID: TrashConfirmation] = [:]
    private(set) var fileActionNotice: FileActionPresentation?
    private(set) var lastFileActionStatus: LastFileActionStatus?
    private(set) var availableVolumes: [ScanVolume] = []
    private(set) var isDiscoveringVolumes = false
    private(set) var volumeDiscoveryMessage: String?
    private var volumeDiscoveryGeneration: UInt64 = 0
    private var hasDiscoveredVolumes = false
    private(set) var scanTimeEstimate: ScanTimeEstimate?
    private(set) var scanIsFinishing = false

    private let scanner: any FileSystemScanner
    private let folderPicker: any FolderPicking
    private let volumeDiscovery: any VolumeDiscovering
    private let projector: any LargestItemsProjecting
    private let visualizationBuilder: any SunburstProjectionBuilding
    private let layoutEngine: any SunburstLayouting
    private let finder: any FinderService
    private let trash: any TrashService
    private var folderLease: FolderAccessLease?
    private var session: ScanSession?
    private var updatesTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var visualizationTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var fileActionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var phaseBeforeChoosing: ScanPhase = .idle
    private var scanTimeEstimator = ScanTimeEstimator()

    init(
        scanner: any FileSystemScanner,
        folderPicker: any FolderPicking,
        volumeDiscovery: any VolumeDiscovering = FoundationVolumeDiscovery(),
        projector: any LargestItemsProjecting,
        visualizationBuilder: any SunburstProjectionBuilding = VisualizationTreeBuilder(),
        layoutEngine: any SunburstLayouting = SunburstLayout(),
        finder: any FinderService = AppKitFinderService(),
        trash: any TrashService = AppKitTrashService()
    ) {
        self.scanner = scanner
        self.folderPicker = folderPicker
        self.volumeDiscovery = volumeDiscovery
        self.projector = projector
        self.visualizationBuilder = visualizationBuilder
        self.layoutEngine = layoutEngine
        self.finder = finder
        self.trash = trash
    }

    var canChooseFolder: Bool { !phase.isActive && phase != .choosingFolder }
    var canRescan: Bool { selectedRoot != nil && folderLease != nil && canChooseFolder }
    var showsCancel: Bool { phase == .scanning || phase == .cancelling }
    var canCancel: Bool { phase == .scanning }
    var canGoBack: Bool { !(explorer?.backStack.isEmpty ?? true) }
    var canGoForward: Bool { !(explorer?.forwardStack.isEmpty ?? true) }
    var canGoUp: Bool { explorer.map { $0.visibleRoot != displayedResult?.result.tree.root } ?? false }
    var visibleRoot: NodeID? { explorer?.visibleRoot }
    var markedTrashCount: Int { markedTrashItems.count }
    var hasInvalidatedFileActions: Bool { !invalidatedSubtrees.isEmpty }
    var isSelectedMarkedForTrash: Bool {
        selectedNodeID.map { markedTrashItems[$0] != nil } ?? false
    }
    func isMarkedForTrash(_ node: NodeID) -> Bool {
        markedTrashItems[node] != nil
    }
    var selectedNodeID: NodeID? {
        guard case .node(let node) = explorer?.selection else { return nil }
        return node
    }
    var selectedItem: ExplorerDetails? { makeDetails(for: explorer?.selection) }
    var chartHighlightedItem: SunburstItemID? {
        guard let selection = explorer?.selection else { return nil }
        let selected = selection.item
        if sunburstLayout?.segments.contains(where: { $0.item == selected }) == true { return selected }
        guard case .node(let node) = selection, let tree = displayedResult?.result.tree else { return nil }
        guard tree.node(for: node) != nil else { return nil }
        var current = node
        while true {
            if sunburstProjection?.nodes.contains(where: { $0.item == .other(parent: current) }) == true {
                return .other(parent: current)
            }
            if sunburstLayout?.segments.contains(where: { $0.item == .node(current) }) == true {
                return .node(current)
            }
            guard current != tree.root else { return .node(tree.root) }
            guard let parent = tree.node(for: current)?.parent else { return nil }
            current = parent
        }
    }
    var chartBudget: SunburstViewportBudget { SunburstViewportPolicy.budget(for: viewport) }
    var remainingKnownDirectoryCount: UInt64 {
        guard let progress else { return 0 }
        let sum = progress.pendingDirectoryCount.addingReportingOverflow(progress.inFlightDirectoryCount)
        return sum.overflow ? .max : sum.partialValue
    }
    var remainingTimeDescription: String {
        if scanIsFinishing { return "Finalizing the storage map…" }
        guard let estimate = scanTimeEstimate else { return "Estimating time remaining…" }
        if estimate.upperBoundSeconds < 60 { return "Less than a minute remaining" }
        let lowerMinutes = max(1, Int(estimate.lowerBoundSeconds / 60))
        let upperMinutes = max(lowerMinutes, Int((estimate.upperBoundSeconds + 59) / 60))
        if lowerMinutes == upperMinutes { return "About \(upperMinutes) min remaining" }
        return "About \(lowerMinutes)–\(upperMinutes) min remaining"
    }

    var commandActions: ScanCommandActions {
        .init(
            chooseFolder: { [weak self] in self?.chooseFolder() },
            rescan: { [weak self] in self?.rescan() },
            cancel: { [weak self] in self?.cancel() },
            goBack: { [weak self] in self?.goBack() },
            goForward: { [weak self] in self?.goForward() },
            goUp: { [weak self] in self?.goUp() },
            drillSelected: { [weak self] in self?.drillSelected() },
            revealSelectedInFinder: { [weak self] in self?.revealSelectedInFinder() },
            moveSelectedToTrash: { [weak self] in self?.prepareMoveSelectedToTrash() },
            canChooseFolder: canChooseFolder,
            canRescan: canRescan,
            canCancel: canCancel,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            canGoUp: canGoUp,
            canDrillSelected: canDrillSelected,
            canRevealSelectedInFinder: isActionAllowed(.revealInFinder),
            // A marked batch is an explicit, separate destructive operation.
            // Do not let a single-item command silently discard the user's other
            // marks while that batch is being prepared.
            canMoveSelectedToTrash: markedTrashItems.isEmpty && isActionAllowed(.moveToTrash)
        )
    }

    var canDrillSelected: Bool {
        guard case .node(let node) = explorer?.selection, let tree = displayedResult?.result.tree else { return false }
        return tree.node(for: node)?.kind == .directory && node != explorer?.visibleRoot
    }

    private func isActionAllowed(_ action: FileActionKind) -> Bool {
        if case .allowed = fileActionEligibility(action) { return true }
        return false
    }

    var trashConfirmation: TrashConfirmation? {
        guard case .awaitingTrashConfirmation(let confirmation) = fileActionPhase else { return nil }
        return confirmation
    }

    var markedTrashConfirmation: MarkedTrashConfirmation? {
        guard case .awaitingMarkedTrashConfirmation(let confirmation) = fileActionPhase else { return nil }
        return confirmation
    }

    var canToggleSelectedTrashMark: Bool {
        guard selectedNodeID != nil, !fileActionPhase.isInProgress else { return false }
        return isSelectedMarkedForTrash || isActionAllowed(.moveToTrash)
    }

    var canMoveMarkedItemsToTrash: Bool {
        !markedTrashItems.isEmpty
            && !fileActionPhase.isInProgress
            && displayedResult?.freshness == .current
            && !phase.isActive
    }

    func fileActionEligibility(_ action: FileActionKind) -> FileActionEligibility {
        guard let displayedResult, let explorer else { return .denied(.noRealSelection) }
        let selectedNode = selectedNodeID
        let node = selectedNode.flatMap { displayedResult.result.tree.node(for: $0) }
        return FileActionEligibilityPolicy.evaluate(.init(
            action: action,
            selectedNode: selectedNode,
            scanRoot: displayedResult.result.tree.root,
            visibleRoot: explorer.visibleRoot,
            freshness: actionFreshness(displayedResult.freshness),
            scanOrRefreshActive: phase.isActive,
            identityAvailable: selectedNode.flatMap { displayedResult.result.tree.identity(for: $0) } != nil,
            nodeKind: node?.kind,
            nodeFlags: node?.flags ?? [],
            // A Trash mutation serializes every action. Finder remains useful for
            // an unaffected item while a post-action refresh is in progress.
            actionInProgress: action == .moveToTrash
                ? fileActionPhase.isInProgress
                : selectedNode.map(isAffectedByActiveFileAction) ?? false,
            invalidatedByEarlierAction: selectedNode.map(isInvalidated) ?? false
        ))
    }

    func revealSelectedInFinder() {
        guard case .allowed = fileActionEligibility(.revealInFinder),
              let target = makeSelectedActionTarget() else { return }
        let actionGeneration = generation
        fileActionPhase = .preparing(kind: .revealInFinder, node: target.node, generation: actionGeneration)
        fileActionTask = Task { [weak self, finder] in
            do {
                let validated = try await NoFollowFileActionTargetValidator().validate(target)
                guard !Task.isCancelled else { return }
                guard let self, self.generation == actionGeneration else { return }
                finder.reveal(validated)
                self.fileActionPhase = .idle
                self.lastFileActionStatus = .init(kind: .revealInFinder, displayName: self.displayedResult?.result.tree.name(for: target.node) ?? "Item", completedAt: Date())
            } catch {
                self?.receiveFileActionFailure(error, generation: actionGeneration)
            }
        }
    }

    func prepareMoveSelectedToTrash() {
        guard markedTrashItems.isEmpty,
              case .allowed = fileActionEligibility(.moveToTrash),
              let target = makeSelectedActionTarget(),
              let tree = displayedResult?.result.tree else { return }
        let actionGeneration = generation
        fileActionPhase = .preparing(kind: .moveToTrash, node: target.node, generation: actionGeneration)
        let confirmation = TrashConfirmation(
            target: target,
            displayName: tree.name(for: target.node),
            relativePath: tree.pathComponents(to: target.node).dropFirst().joined(separator: "/"),
            fullPath: target.rootURL.appending(
                path: tree.pathComponents(to: target.node).dropFirst().joined(separator: "/"),
                directoryHint: target.expectedKind == .directory ? .isDirectory : .notDirectory
            ).path,
            generation: actionGeneration
        )
        fileActionTask = Task { [weak self] in
            do {
                _ = try await NoFollowFileActionTargetValidator().validate(target)
                guard !Task.isCancelled, let self, self.generation == actionGeneration else { return }
                self.fileActionPhase = .awaitingTrashConfirmation(confirmation)
            } catch {
                self?.receiveFileActionFailure(error, generation: actionGeneration)
            }
        }
    }

    func toggleSelectedTrashMark() {
        guard let node = selectedNodeID, !fileActionPhase.isInProgress else { return }
        if markedTrashItems.removeValue(forKey: node) != nil {
            fileActionPhase = .idle
            fileActionNotice = nil
            return
        }
        guard canToggleSelectedTrashMark,
              let target = makeSelectedActionTarget(),
              let tree = displayedResult?.result.tree else { return }

        if markedTrashItems.keys.contains(where: { isDescendant(node, of: $0, in: tree) }) {
            fileActionPhase = .failed(.init(
                title: "Already marked as part of a folder",
                message: "Remove the marked parent folder before marking one of its contents."
            ))
            return
        }
        if tree.node(for: node)?.kind == .directory {
            markedTrashItems = markedTrashItems.filter { !isDescendant($0.key, of: node, in: tree) }
        }
        markedTrashItems[node] = TrashConfirmation(
            target: target,
            displayName: tree.name(for: node),
            relativePath: tree.pathComponents(to: node).dropFirst().joined(separator: "/"),
            fullPath: target.rootURL.appending(
                path: tree.pathComponents(to: node).dropFirst().joined(separator: "/"),
                directoryHint: target.expectedKind == .directory ? .isDirectory : .notDirectory
            ).path,
            generation: generation
        )
        fileActionPhase = .idle
        fileActionNotice = nil
    }

    func prepareMarkedItemsForTrash() {
        guard canMoveMarkedItemsToTrash else { return }
        let items = markedTrashItems.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        guard let first = items.first else { return }
        let actionGeneration = generation
        fileActionPhase = .preparing(kind: .moveToTrash, node: first.target.node, generation: actionGeneration)
        fileActionTask = Task { [weak self] in
            do {
                for item in items {
                    _ = try await NoFollowFileActionTargetValidator().validate(item.target)
                    guard !Task.isCancelled else { return }
                }
                guard let self, self.generation == actionGeneration else { return }
                self.fileActionPhase = .awaitingMarkedTrashConfirmation(.init(items: items, generation: actionGeneration))
            } catch {
                self?.receiveFileActionFailure(error, generation: actionGeneration)
            }
        }
    }

    func cancelMarkedTrashConfirmation() {
        guard markedTrashConfirmation != nil else { return }
        fileActionPhase = .idle
    }

    func confirmMoveMarkedItemsToTrash() {
        guard case .awaitingMarkedTrashConfirmation(let confirmation) = fileActionPhase,
              confirmation.generation == generation else { return }
        let actionGeneration = generation
        fileActionPhase = .movingMarkedItems(
            current: confirmation.items[0].target.node,
            completedCount: 0,
            totalCount: confirmation.count,
            generation: actionGeneration
        )
        fileActionTask = Task { [weak self, trash] in
            var moved: [TrashConfirmation] = []
            for item in confirmation.items {
                guard !Task.isCancelled else { return }
                guard let self, self.generation == actionGeneration else { return }
                self.fileActionPhase = .movingMarkedItems(
                    current: item.target.node,
                    completedCount: moved.count,
                    totalCount: confirmation.count,
                    generation: actionGeneration
                )
                do {
                    _ = try await trash.moveToTrash(item.target)
                    moved.append(item)
                } catch {
                    guard !Task.isCancelled, self.generation == actionGeneration else { return }
                    self.finishMarkedTrashBatch(moved, failure: error, generation: actionGeneration)
                    return
                }
            }
            guard let self, self.generation == actionGeneration else { return }
            self.finishMarkedTrashBatch(moved, failure: nil, generation: actionGeneration)
        }
    }

    func cancelTrashConfirmation() {
        guard trashConfirmation != nil else { return }
        fileActionPhase = .idle
    }

    func confirmMoveToTrash() {
        guard case .awaitingTrashConfirmation(let confirmation) = fileActionPhase,
              confirmation.generation == generation else { return }
        fileActionPhase = .movingToTrash(node: confirmation.target.node, generation: generation)
        let actionGeneration = generation
        fileActionTask = Task { [weak self, trash] in
            do {
                _ = try await trash.moveToTrash(confirmation.target)
                guard !Task.isCancelled, let self, self.generation == actionGeneration else { return }
                self.didMoveToTrash(confirmation, generation: actionGeneration)
            } catch {
                self?.receiveFileActionFailure(error, generation: actionGeneration)
            }
        }
    }

    func discoverVolumesIfNeeded() async {
        guard !hasDiscoveredVolumes, !isDiscoveringVolumes else { return }
        await reloadVolumes()
    }

    func refreshVolumes() {
        guard !isDiscoveringVolumes else { return }
        let requestGeneration = volumeDiscoveryGeneration
        Task { [weak self] in
            guard let self, requestGeneration == self.volumeDiscoveryGeneration else { return }
            await self.reloadVolumes()
        }
    }

    private func reloadVolumes() async {
        guard !isDiscoveringVolumes else { return }
        volumeDiscoveryGeneration &+= 1
        let requestGeneration = volumeDiscoveryGeneration
        isDiscoveringVolumes = true
        defer {
            if requestGeneration == volumeDiscoveryGeneration { isDiscoveringVolumes = false }
        }
        do {
            let snapshot = try await volumeDiscovery.discoverLocalVolumes()
            guard !Task.isCancelled, requestGeneration == volumeDiscoveryGeneration else { return }
            availableVolumes = snapshot.volumes
            hasDiscoveredVolumes = true
            volumeDiscoveryMessage = snapshot.unreadableVolumeCount > 0
                ? "Some disks could not be inspected. The list may be incomplete. Refresh or choose a folder."
                : nil
        } catch {
            guard !Task.isCancelled, requestGeneration == volumeDiscoveryGeneration else { return }
            hasDiscoveredVolumes = true
            volumeDiscoveryMessage = "Disk list could not be refreshed. Previously listed disks may be unavailable. Retry or choose a folder."
        }
    }

    func chooseFolder() {
        chooseSource(volume: nil, prompt: "Choose")
    }

    func chooseVolume(_ volume: ScanVolume) {
        chooseSource(volume: volume, prompt: "Scan")
    }

    private func chooseSource(volume: ScanVolume?, prompt: String) {
        guard canChooseFolder else { return }
        phaseBeforeChoosing = phase
        phase = .choosingFolder
        let selectionGeneration = generation
        Task { [weak self] in
            guard let self, selectionGeneration == self.generation, self.phase == .choosingFolder else { return }
            if let volume {
                do {
                    let snapshot = try await self.volumeDiscovery.discoverLocalVolumes()
                    guard selectionGeneration == self.generation, self.phase == .choosingFolder else { return }
                    guard snapshot.volumes.contains(where: { $0.id == volume.id && $0.url == volume.url }) else {
                        self.phase = self.phaseBeforeChoosing
                        self.presentedError = .init(title: "Disk is no longer available", message: "Refresh the disk list or reconnect the disk, then choose it again.")
                        return
                    }
                } catch {
                    guard selectionGeneration == self.generation, self.phase == .choosingFolder else { return }
                    self.phase = self.phaseBeforeChoosing
                    self.presentedError = .init(title: "Disk availability could not be verified", message: "Refresh the disk list or choose a folder explicitly.")
                    return
                }
            }
            let selection = await self.folderPicker.chooseFolder(startingAt: volume?.url, prompt: prompt)
            guard selectionGeneration == self.generation, self.phase == .choosingFolder else {
                selection?.lease.release()
                return
            }
            guard let selection else {
                self.phase = self.phaseBeforeChoosing
                return
            }
            self.start(selection: selection, keepingPreviousResult: false)
        }
    }

    func rescan() {
        guard canRescan, let root = selectedRoot, let lease = folderLease else { return }
        start(selection: .init(url: root, lease: lease), keepingPreviousResult: true, replacesLease: false)
    }

    func cancel() {
        guard phase == .scanning else { return }
        phase = .cancelling
        session?.cancel()
    }

    func setMetric(_ metric: SizeMetric) {
        guard self.metric != metric else { return }
        self.metric = metric
        rebuildVisibleRoot()
    }

    func updateViewport(width: Double, height: Double) {
        let next = SunburstViewport(width: width, height: height)
        guard next.width.isFinite, next.height.isFinite, next.width > 0, next.height > 0 else { return }
        let previousBudget = SunburstViewportPolicy.budget(for: viewport)
        viewport = next
        guard let tree = displayedResult?.result.tree, let root = explorer?.visibleRoot else { return }
        if previousBudget == SunburstViewportPolicy.budget(for: next), let sunburstProjection {
            beginLayout(for: sunburstProjection, root: root, metric: metric, generation: generation)
        } else {
            beginVisualization(for: tree, root: root, metric: metric, generation: generation)
        }
    }

    func select(node: NodeID?) {
        guard let node else {
            explorer?.selection = nil
            return
        }
        guard displayedResult?.result.tree.node(for: node) != nil else { return }
        explorer?.selection = .node(node)
    }

    func select(item: SunburstItemID?) {
        guard let item else {
            explorer?.selection = nil
            return
        }
        switch item {
        case .node(let node):
            guard displayedResult?.result.tree.node(for: node) != nil else { return }
            explorer?.selection = .node(node)
        case .other(let parent):
            guard displayedResult?.result.tree.node(for: parent) != nil else { return }
            explorer?.selection = .other(parent: parent)
        }
    }

    func setHoveredItem(_ item: SunburstItemID?) {
        explorer?.hoveredItem = item
    }

    func selectChart(atX x: Double, y: Double) {
        guard let layout = sunburstLayout else { return }
        switch SunburstHitTester.hitTest(layout: layout, x: x, y: y) {
        case .center(let root):
            if canGoUp { goUp() } else { select(item: .node(root)) }
        case .segment(let index):
            let offset = Int(index.rawValue)
            guard layout.segments.indices.contains(offset) else { return }
            select(item: layout.segments[offset].item)
        case nil: select(item: nil)
        }
    }

    func activateChart(atX x: Double, y: Double) {
        guard let layout = sunburstLayout else { return }
        switch SunburstHitTester.hitTest(layout: layout, x: x, y: y) {
        case .center:
            if canGoUp { goUp() }
        case .segment(let index):
            let offset = Int(index.rawValue)
            guard layout.segments.indices.contains(offset) else { return }
            activateChart(item: layout.segments[offset].item)
        case nil:
            return
        }
    }

    func activateChart(item: SunburstItemID) {
        guard case .node(let node) = item else { return }
        drill(to: node)
    }

    func hoverChart(atX x: Double, y: Double) {
        guard let layout = sunburstLayout else { return }
        switch SunburstHitTester.hitTest(layout: layout, x: x, y: y) {
        case .center(let root): setHoveredItem(.node(root))
        case .segment(let index):
            let offset = Int(index.rawValue)
            setHoveredItem(layout.segments.indices.contains(offset) ? layout.segments[offset].item : nil)
        case nil: setHoveredItem(nil)
        }
    }

    func drillSelected() {
        guard case .node(let node) = explorer?.selection else { return }
        drill(to: node)
    }

    func drill(to node: NodeID) {
        guard let tree = displayedResult?.result.tree,
              let explorer,
              node != explorer.visibleRoot,
              tree.node(for: node)?.kind == .directory,
              isDescendant(node, of: explorer.visibleRoot, in: tree) else { return }
        self.explorer?.backStack.append(explorer.visibleRoot)
        self.explorer?.forwardStack.removeAll(keepingCapacity: true)
        self.explorer?.visibleRoot = node
        self.explorer?.selection = .node(node)
        self.explorer?.hoveredItem = nil
        rebuildVisibleRoot()
    }

    func goBack() {
        guard let current = explorer?.visibleRoot, let previous = explorer?.backStack.popLast() else { return }
        guard displayedResult?.result.tree.node(for: previous) != nil else {
            explorer?.backStack.removeAll(keepingCapacity: true)
            return
        }
        explorer?.forwardStack.append(current)
        explorer?.visibleRoot = previous
        explorer?.selection = .node(previous)
        explorer?.hoveredItem = nil
        rebuildVisibleRoot()
    }

    func goForward() {
        guard let current = explorer?.visibleRoot, let next = explorer?.forwardStack.popLast() else { return }
        guard displayedResult?.result.tree.node(for: next) != nil else {
            explorer?.forwardStack.removeAll(keepingCapacity: true)
            return
        }
        explorer?.backStack.append(current)
        explorer?.visibleRoot = next
        explorer?.selection = .node(next)
        explorer?.hoveredItem = nil
        rebuildVisibleRoot()
    }

    func goUp() {
        guard let tree = displayedResult?.result.tree, let current = explorer?.visibleRoot, current != tree.root else { return }
        guard let parent = tree.node(for: current)?.parent else { return }
        guard parent.isValid else { return }
        explorer?.backStack.append(current)
        explorer?.forwardStack.removeAll(keepingCapacity: true)
        explorer?.visibleRoot = parent
        explorer?.selection = .node(parent)
        explorer?.hoveredItem = nil
        rebuildVisibleRoot()
    }

    func navigateBreadcrumb(to node: NodeID) {
        guard let tree = displayedResult?.result.tree, let current = explorer?.visibleRoot,
              node != current, isDescendant(current, of: node, in: tree) else { return }
        explorer?.backStack.append(current)
        explorer?.forwardStack.removeAll(keepingCapacity: true)
        explorer?.visibleRoot = node
        explorer?.selection = .node(node)
        explorer?.hoveredItem = nil
        rebuildVisibleRoot()
    }

    func breadcrumbNodes() -> [NodeID] {
        guard let tree = displayedResult?.result.tree,
              let root = explorer?.visibleRoot,
              tree.node(for: root) != nil else { return [] }
        var nodes = [root]
        var current = root
        while current != tree.root {
            guard let parent = tree.node(for: current)?.parent else { return [] }
            current = parent
            nodes.append(current)
        }
        return nodes.reversed()
    }

    func displayName(for item: SunburstItemID) -> String {
        switch item {
        case .node(let node):
            guard let tree = displayedResult?.result.tree, tree.node(for: node) != nil else { return "Item" }
            return tree.name(for: node)
        case .other:
            return "Other items"
        }
    }

    func accessibilityDescription(for item: SunburstItemID) -> String {
        switch item {
        case .node:
            return displayName(for: item)
        case .other(let parent):
            let count = sunburstProjection?.nodes.first(where: { $0.item == .other(parent: parent) })?.aggregatedDirectChildCount ?? 0
            return "Other items, \(count) aggregated direct items"
        }
    }

    func isDrillable(_ item: SunburstItemID) -> Bool {
        guard case .node(let node) = item else { return false }
        return displayedResult?.result.tree.node(for: node)?.kind == .directory && node != explorer?.visibleRoot
    }

    func teardown() {
        volumeDiscoveryGeneration &+= 1
        isDiscoveringVolumes = false
        generation &+= 1
        session?.cancel()
        session = nil
        updatesTask?.cancel()
        resultTask?.cancel()
        projectionTask?.cancel()
        visualizationTask?.cancel()
        layoutTask?.cancel()
        fileActionTask?.cancel()
        updatesTask = nil
        resultTask = nil
        projectionTask = nil
        visualizationTask = nil
        layoutTask = nil
        fileActionTask = nil
        folderLease?.release()
        folderLease = nil
    }

    private func start(
        selection: FolderSelection,
        keepingPreviousResult: Bool,
        replacesLease: Bool = true,
        previousFreshness: DisplayedScanResult.Freshness = .staleWhileScanning,
        preservesFileActionNotice: Bool = false
    ) {
        fileActionTask?.cancel()
        fileActionTask = nil
        if replacesLease {
            invalidatedSubtrees = []
            markedTrashItems = [:]
        }
        if !keepingPreviousResult {
            markedTrashItems = [:]
        }
        if !preservesFileActionNotice { fileActionNotice = nil }
        if case .refreshingAfterTrash = fileActionPhase {
            // Keep the action status until this refresh reaches a terminal state.
        } else {
            fileActionPhase = .idle
        }
        generation &+= 1
        let scanGeneration = generation
        cancelTasksAndSession()
        if replacesLease {
            folderLease?.release()
            folderLease = selection.lease
        }
        selectedRoot = selection.url
        progress = nil
        scanTimeEstimator.reset()
        scanTimeEstimate = nil
        scanIsFinishing = false
        presentedError = nil
        if keepingPreviousResult, let displayedResult {
            self.displayedResult = .init(result: displayedResult.result, freshness: previousFreshness)
        } else {
            displayedResult = nil
            rows = []
            explorer = nil
            sunburstProjection = nil
            sunburstLayout = nil
            projectionPhase = .idle
        }
        phase = .preparing
        let previousIdentity = keepingPreviousResult
            ? displayedResult.flatMap { $0.result.tree.identity(for: $0.result.tree.root) }
            : nil
        let session = scanner.startScan(.init(rootURL: selection.url, expectedRootIdentity: previousIdentity))
        self.session = session
        phase = .scanning

        updatesTask = Task { [weak self, session] in
            for await update in session.updates {
                guard !Task.isCancelled else { return }
                self?.receive(update: update, generation: scanGeneration)
            }
        }
        resultTask = Task { [weak self, session] in
            do {
                let result = try await session.result.value
                self?.receive(result: result, generation: scanGeneration)
            } catch {
                self?.receive(error: error, generation: scanGeneration)
            }
        }
    }

    private func cancelTasksAndSession() {
        session?.cancel()
        session = nil
        updatesTask?.cancel()
        resultTask?.cancel()
        projectionTask?.cancel()
        visualizationTask?.cancel()
        layoutTask?.cancel()
        updatesTask = nil
        resultTask = nil
        projectionTask = nil
        visualizationTask = nil
        layoutTask = nil
    }

    private func receive(update: ScanUpdate, generation: UInt64) {
        guard generation == self.generation else { return }
        switch update {
        case .progress(let progress):
            self.progress = progress
            scanIsFinishing = false
            scanTimeEstimate = scanTimeEstimator.update(
                completedDirectories: progress.completedDirectoryCount,
                pendingDirectories: progress.pendingDirectoryCount,
                inFlightDirectories: progress.inFlightDirectoryCount,
                elapsed: progress.elapsed
            )
        case .finishing:
            scanIsFinishing = true
            scanTimeEstimate = nil
        }
    }

    private func receive(result: ScanResult, generation: UInt64) {
        guard generation == self.generation else { return }
        session = nil
        updatesTask?.cancel()
        updatesTask = nil
        resultTask = nil
        progress = result.progress
        scanIsFinishing = false
        scanTimeEstimate = nil
        if result.completion == .cancelled, !invalidatedSubtrees.isEmpty {
            // An action refresh must not replace the last coherent snapshot with
            // a cancelled partial tree. Its node IDs and totals remain stale.
            if let displayedResult {
                self.displayedResult = .init(result: displayedResult.result, freshness: .staleAfterFileAction)
            }
            fileActionPhase = .failed(.init(
                title: "Refresh cancelled",
                message: "The item was moved to Trash, but displayed sizes are stale. Rescan to continue."
            ))
            phase = .cancelled
            return
        }
        let completedActionRefresh = result.completion == .complete && !invalidatedSubtrees.isEmpty

        // Every NodeID-derived value belongs to the old FileTree. Clear all of
        // them before publishing the replacement snapshot so observation-driven
        // view reads can never combine old IDs with the new tree.
        explorer = nil
        rows = []
        sunburstProjection = nil
        sunburstLayout = nil
        projectionPhase = .idle
        markedTrashItems = [:]
        invalidatedSubtrees = []

        displayedResult = .init(result: result, freshness: result.sourceIsUnavailable ? .sourceUnavailable : (result.completion == .cancelled ? .partial : .current))
        if completedActionRefresh {
            fileActionPhase = .idle
        }
        phase = result.completion == .cancelled ? .cancelled : (result.hasIncompleteCoverage ? .completedWithIssues : .completed)
        explorer = .init(visibleRoot: result.tree.root, selection: .node(result.tree.root), hoveredItem: nil, backStack: [], forwardStack: [])
        beginProjection(for: result.tree, root: result.tree.root, generation: generation)
    }

    private func receive(error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        session = nil
        updatesTask?.cancel()
        updatesTask = nil
        resultTask = nil
        scanIsFinishing = false
        scanTimeEstimate = nil
        presentedError = .make(from: error)
        if let displayedResult {
            self.displayedResult = .init(result: displayedResult.result, freshness: invalidatedSubtrees.isEmpty ? .previousAfterFailedRescan : .staleAfterFileAction)
        } else {
            rows = []
        }
        phase = .failed
    }

    private func rebuildVisibleRoot() {
        guard let tree = displayedResult?.result.tree, let root = explorer?.visibleRoot else { return }
        beginProjection(for: tree, root: root, generation: generation)
    }

    private func beginProjection(for tree: FileTree, root: NodeID, generation: UInt64) {
        projectionTask?.cancel()
        rows = []
        let metric = metric
        projectionTask = Task { [weak self, projector] in
            do {
                let rows = try await projector.project(tree: tree, root: root, metric: metric, limit: Self.rowLimit)
                guard !Task.isCancelled else { return }
                self?.receive(rows: rows, root: root, metric: metric, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.receiveProjectionError(error, generation: generation)
            }
        }
        beginVisualization(for: tree, root: root, metric: metric, generation: generation)
    }

    private func beginVisualization(for tree: FileTree, root: NodeID, metric: SizeMetric, generation: UInt64) {
        visualizationTask?.cancel()
        layoutTask?.cancel()
        sunburstProjection = nil
        sunburstLayout = nil
        projectionPhase = .preparingProjection
        let request = SunburstViewportPolicy.request(root: root, metric: metric.sunburstMetric, viewport: viewport)
        let budget = SunburstViewportPolicy.budget(for: viewport)
        visualizationTask = Task { [weak self, visualizationBuilder] in
            do {
                let projection = try await visualizationBuilder.build(tree: tree, request: request)
                guard !Task.isCancelled else { return }
                self?.receive(projection: projection, root: root, metric: metric, budget: budget, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.receiveVisualizationError(error, generation: generation)
            }
        }
    }

    private func beginLayout(for projection: SunburstProjection, root: NodeID, metric: SizeMetric, generation: UInt64) {
        layoutTask?.cancel()
        sunburstLayout = nil
        projectionPhase = .layingOut
        let budget = SunburstViewportPolicy.budget(for: viewport)
        let viewport = viewport
        layoutTask = Task { [weak self, layoutEngine] in
            do {
                let layout = try await layoutEngine.layout(projection: projection, viewport: viewport)
                guard !Task.isCancelled else { return }
                self?.receive(layout: layout, root: root, metric: metric, budget: budget, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.receiveVisualizationError(error, generation: generation)
            }
        }
    }

    private func receive(rows: [LargestItemRow], root: NodeID, metric: SizeMetric, generation: UInt64) {
        guard generation == self.generation, metric == self.metric, root == explorer?.visibleRoot else { return }
        self.rows = rows
        projectionTask = nil
    }

    private func receive(projection: SunburstProjection, root: NodeID, metric: SizeMetric, budget: SunburstViewportBudget, generation: UInt64) {
        guard generation == self.generation,
              metric == self.metric,
              root == explorer?.visibleRoot,
              budget == SunburstViewportPolicy.budget(for: viewport) else { return }
        sunburstProjection = projection
        visualizationTask = nil
        beginLayout(for: projection, root: root, metric: metric, generation: generation)
    }

    private func receive(layout: SunburstLayoutResult, root: NodeID, metric: SizeMetric, budget: SunburstViewportBudget, generation: UInt64) {
        guard generation == self.generation,
              metric == self.metric,
              root == explorer?.visibleRoot,
              budget == SunburstViewportPolicy.budget(for: viewport) else { return }
        sunburstLayout = layout
        layoutTask = nil
        projectionPhase = .ready
    }

    private func receiveProjectionError(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        presentedError = .init(title: "Results could not be prepared", message: "Rescan the folder to try again.")
        projectionTask = nil
    }

    private func receiveVisualizationError(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        projectionPhase = .failed("Chart preparation failed. Resize the chart or retry the scan.")
        visualizationTask = nil
        layoutTask = nil
    }

    private func isDescendant(_ node: NodeID, of root: NodeID, in tree: FileTree) -> Bool {
        guard tree.node(for: node) != nil, tree.node(for: root) != nil else { return false }
        var current = node
        while current != tree.root {
            if current == root { return true }
            guard let parent = tree.node(for: current)?.parent else { return false }
            current = parent
        }
        return current == root
    }

    private func makeDetails(for selection: ExplorerSelection?) -> ExplorerDetails? {
        guard let selection, let tree = displayedResult?.result.tree else { return nil }
        switch selection {
        case .node(let node):
            guard let source = tree.node(for: node) else { return nil }
            return .init(
                selection: selection,
                name: tree.name(for: node),
                relativePath: tree.pathComponents(to: node).dropFirst().joined(separator: "/"),
                kind: source.kind,
                logicalSize: source.logicalSize,
                allocatedSize: source.allocatedSize,
                flags: source.flags,
                aggregatedDirectChildCount: nil,
                aggregatedValue: nil,
                nodeID: node
            )
        case .other(let parent):
            guard let projectionNode = sunburstProjection?.nodes.first(where: { $0.item == .other(parent: parent) }) else { return nil }
            return .init(
                selection: selection,
                name: "Other items",
                relativePath: tree.pathComponents(to: parent).dropFirst().joined(separator: "/"),
                kind: nil,
                logicalSize: nil,
                allocatedSize: nil,
                flags: [],
                aggregatedDirectChildCount: projectionNode.aggregatedDirectChildCount,
                aggregatedValue: projectionNode.value,
                nodeID: nil
            )
        }
    }

    private func makeSelectedActionTarget() -> SnapshotFileActionTarget? {
        guard let result = displayedResult?.result, let node = selectedNodeID else { return nil }
        do {
            return try SnapshotFileActionTargetBuilder.make(node: node, tree: result.tree, rootURL: result.rootURL)
        } catch {
            receiveFileActionFailure(error, generation: generation)
            return nil
        }
    }

    private func actionFreshness(_ freshness: DisplayedScanResult.Freshness) -> FileActionSnapshotFreshness {
        switch freshness {
        case .current: .current
        case .staleWhileScanning: .staleWhileScanning
        case .previousAfterFailedRescan, .sourceUnavailable: .previousAfterFailedRescan
        case .partial: .partial
        case .staleAfterFileAction: .staleAfterFileAction
        }
    }

    private func receiveFileActionFailure(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        let presentation = FileActionPresentation.make(from: error)
        fileActionPhase = .failed(presentation)
        if errorMakesSnapshotStale(error), let displayedResult {
            self.displayedResult = .init(result: displayedResult.result, freshness: .staleAfterFileAction)
        }
    }

    private func errorMakesSnapshotStale(_ error: Error) -> Bool {
        switch error {
        case FileActionError.rootMissing,
             FileActionError.rootChanged,
             FileActionError.ancestorMissing,
             FileActionError.ancestorChanged,
             FileActionError.symbolicLinkInAncestor,
             FileActionError.targetMissing,
             FileActionError.targetChanged:
            true
        default:
            false
        }
    }

    private func didMoveToTrash(_ confirmation: TrashConfirmation, generation: UInt64) {
        finishMarkedTrashBatch([confirmation], failure: nil, generation: generation)
    }

    private func finishMarkedTrashBatch(_ moved: [TrashConfirmation], failure: Error?, generation: UInt64) {
        guard generation == self.generation else { return }
        guard !moved.isEmpty else {
            if let failure { receiveFileActionFailure(failure, generation: generation) }
            return
        }
        guard let displayedResult else { return }
        let tree = displayedResult.result.tree
        invalidatedSubtrees.append(contentsOf: moved.map { .init(root: $0.target.node, generation: generation) })
        self.displayedResult = .init(result: displayedResult.result, freshness: .staleAfterFileAction)
        if let firstMoved = moved.first {
            let parent = tree.node(for: firstMoved.target.node)?.parent ?? .invalid
            if parent.isValid { self.explorer?.selection = .node(parent) }
        }
        markedTrashItems = [:]
        let displayName = moved.count == 1 ? (moved.first?.displayName ?? "Item") : "\(moved.count) marked items"
        lastFileActionStatus = .init(kind: .moveToTrash, displayName: displayName, completedAt: Date())
        if failure != nil {
            fileActionNotice = .init(
                title: "Trash batch stopped",
                message: "\(moved.count) item\(moved.count == 1 ? " was" : "s were") moved to Trash. The remaining marked items were not moved."
            )
        }
        fileActionPhase = .refreshingAfterTrash(.init(root: moved[0].target.node, generation: generation))
        phase = .scanning
        reconcileKnownTrashMoves(
            result: displayedResult.result,
            movedRoots: moved.map(\.target.node),
            generation: generation,
            preservesFileActionNotice: failure != nil
        )
    }

    /// A receipt-confirmed Trash move is the one case where the app can safely
    /// derive a replacement snapshot without rereading the filesystem. Any
    /// inability to prove the rebuild falls back to the established full scan.
    private func reconcileKnownTrashMoves(
        result: ScanResult,
        movedRoots: [NodeID],
        generation: UInt64,
        preservesFileActionNotice: Bool
    ) {
        fileActionTask?.cancel()
        fileActionTask = Task { [weak self, result, movedRoots] in
            do {
                let reconciliation = try await Task.detached(priority: .userInitiated) {
                    try KnownDeletionReconciler.reconcile(tree: result.tree, removing: movedRoots)
                }.value
                guard !Task.isCancelled else { return }
                self?.receiveKnownDeletionReconciliation(reconciliation, basedOn: result, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self?.fallbackToFullRefreshAfterReconciliationFailure(
                    result: result,
                    generation: generation,
                    preservesFileActionNotice: preservesFileActionNotice
                )
            }
        }
    }

    private func receiveKnownDeletionReconciliation(
        _ reconciliation: KnownDeletionReconciliation,
        basedOn result: ScanResult,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        let replacement = ScanResult(
            rootURL: result.rootURL,
            tree: reconciliation.tree,
            completion: .complete,
            accounting: result.accounting,
            progress: result.progress,
            issues: result.issues,
            startedAt: result.startedAt,
            finishedAt: Date()
        )
        receive(result: replacement, generation: generation)
    }

    private func fallbackToFullRefreshAfterReconciliationFailure(
        result: ScanResult,
        generation: UInt64,
        preservesFileActionNotice: Bool
    ) {
        guard generation == self.generation else { return }
        guard let lease = folderLease else {
            fileActionPhase = .failed(.init(
                title: "Refresh unavailable",
                message: "The item was moved to Trash, but Hygieia no longer has access to the selected folder. Choose the folder again to rescan."
            ))
            return
        }
        start(
            selection: .init(url: result.rootURL, lease: lease),
            keepingPreviousResult: true,
            replacesLease: false,
            previousFreshness: .staleAfterFileAction,
            preservesFileActionNotice: preservesFileActionNotice
        )
    }

    func isInvalidated(_ node: NodeID) -> Bool {
        guard let tree = displayedResult?.result.tree, tree.node(for: node) != nil else { return false }
        return invalidatedSubtrees.contains { node == $0.root || isDescendant(node, of: $0.root, in: tree) }
    }

    private func isAffectedByActiveFileAction(_ node: NodeID) -> Bool {
        guard let tree = displayedResult?.result.tree else { return true }
        let actionRoot: NodeID?
        switch fileActionPhase {
        case .preparing(_, let node, _), .movingToTrash(let node, _):
            actionRoot = node
        case .awaitingTrashConfirmation(let confirmation):
            actionRoot = confirmation.target.node
        case .awaitingMarkedTrashConfirmation:
            actionRoot = nil
        case .movingMarkedItems(let node, _, _, _):
            actionRoot = node
        case .refreshingAfterTrash(let invalidated):
            actionRoot = invalidated.root
        case .idle, .failed:
            actionRoot = nil
        }
        guard let actionRoot else { return false }
        return node == actionRoot || isDescendant(node, of: actionRoot, in: tree)
    }
}

private extension SizeMetric {
    var sunburstMetric: SunburstSizeMetric {
        switch self {
        case .reportedAllocated: .reportedAllocated
        case .logical: .logical
        }
    }
}
