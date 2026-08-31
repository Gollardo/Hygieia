import Foundation
import XCTest
@testable import Hygieia
import HygieiaDomain
import HygieiaFoundationScanner
import HygieiaFileOperations
import HygieiaScannerCore

final class ScanTimeEstimatorTests: XCTestCase {
    func testEstimateAppearsOnlyAfterKnownQueueContracts() {
        var estimator = ScanTimeEstimator()

        XCTAssertNil(estimator.update(completedDirectories: 0, pendingDirectories: 200, inFlightDirectories: 0, elapsed: .seconds(0)))
        XCTAssertNil(estimator.update(completedDirectories: 40, pendingDirectories: 180, inFlightDirectories: 0, elapsed: .seconds(5)))
        let estimate = estimator.update(completedDirectories: 80, pendingDirectories: 140, inFlightDirectories: 0, elapsed: .seconds(10))

        XCTAssertNotNil(estimate)
        XCTAssertLessThan(estimate!.lowerBoundSeconds, estimate!.upperBoundSeconds)
    }

    func testGrowingQueueSuppressesEarlierEstimate() {
        var estimator = ScanTimeEstimator()
        _ = estimator.update(completedDirectories: 0, pendingDirectories: 200, inFlightDirectories: 0, elapsed: .seconds(0))
        _ = estimator.update(completedDirectories: 40, pendingDirectories: 180, inFlightDirectories: 0, elapsed: .seconds(5))
        _ = estimator.update(completedDirectories: 80, pendingDirectories: 140, inFlightDirectories: 0, elapsed: .seconds(10))

        let estimate = estimator.update(completedDirectories: 100, pendingDirectories: 300, inFlightDirectories: 4, elapsed: .seconds(12))

        XCTAssertNil(estimate)
    }
}

final class ChartTapSequenceTests: XCTestCase {
    func testSecondNearbyTapRegistersImmediatelyWithinSystemInterval() {
        var sequence = ChartTapSequence()

        XCTAssertFalse(
            sequence.register(location: .init(x: 100, y: 100), timestamp: 10, doubleClickInterval: 0.5, radius: 12)
        )
        XCTAssertTrue(
            sequence.register(location: .init(x: 106, y: 104), timestamp: 10.2, doubleClickInterval: 0.5, radius: 12)
        )
    }

    func testLateOrDistantTapStartsANewSequence() {
        var lateSequence = ChartTapSequence()
        XCTAssertFalse(lateSequence.register(location: .zero, timestamp: 10, doubleClickInterval: 0.5, radius: 12))
        XCTAssertFalse(lateSequence.register(location: .zero, timestamp: 10.6, doubleClickInterval: 0.5, radius: 12))

        var distantSequence = ChartTapSequence()
        XCTAssertFalse(distantSequence.register(location: .zero, timestamp: 10, doubleClickInterval: 0.5, radius: 12))
        XCTAssertFalse(distantSequence.register(location: .init(x: 20, y: 0), timestamp: 10.2, doubleClickInterval: 0.5, radius: 12))
    }
}

final class LargestItemsProjectorTests: XCTestCase {
    func testAllocatedProjectionKeepsOnlyLargestItemsWithDeterministicTies() async throws {
        let rows = try await LargestItemsProjector().project(tree: makeTree(), metric: .reportedAllocated, limit: 2)

        XCTAssertEqual(rows.map(\.name), ["beta", "gamma"])
        XCTAssertEqual(rows.map(\.allocatedSize), [90, 90])
    }

    func testLogicalProjectionUsesLogicalMetricAndZeroLimitProducesNoRows() async throws {
        let tree = makeTree()
        let logical = try await LargestItemsProjector().project(tree: tree, metric: .logical, limit: 1)
        let empty = try await LargestItemsProjector().project(tree: tree, metric: .logical, limit: 0)

        XCTAssertEqual(logical.map(\.name), ["alpha"])
        XCTAssertTrue(empty.isEmpty)
    }

    func testProjectionShowsOnlyDirectChildrenOfVisibleRoot() async throws {
        var names = NameStore()
        let rootName = try names.append("root")
        let folderName = try names.append("folder")
        let nestedName = try names.append("nested-large")
        let siblingName = try names.append("sibling")
        let tree = FileTree(
            root: .init(rawValue: 0),
            nodes: [
                .init(logicalSize: 1_100, allocatedSize: 1_100, parent: .invalid, firstChild: .init(rawValue: 1), name: rootName, kind: .directory),
                .init(logicalSize: 1_000, allocatedSize: 1_000, parent: .init(rawValue: 0), firstChild: .init(rawValue: 2), nextSibling: .init(rawValue: 3), name: folderName, kind: .directory),
                .init(logicalSize: 1_000, allocatedSize: 1_000, parent: .init(rawValue: 1), name: nestedName, kind: .regularFile),
                .init(logicalSize: 100, allocatedSize: 100, parent: .init(rawValue: 0), name: siblingName, kind: .regularFile),
            ],
            names: names
        )

        let rootRows = try await LargestItemsProjector().project(tree: tree, root: tree.root, metric: .logical, limit: 10)
        let folderRows = try await LargestItemsProjector().project(tree: tree, root: .init(rawValue: 1), metric: .logical, limit: 10)

        XCTAssertEqual(rootRows.map(\.name), ["folder", "sibling"])
        XCTAssertEqual(folderRows.map(\.name), ["nested-large"])
    }

    private func makeTree() -> FileTree {
        var names = NameStore()
        let root = try! names.append("root")
        let alpha = try! names.append("alpha")
        let beta = try! names.append("beta")
        let gamma = try! names.append("gamma")
        let nodes: ContiguousArray<FileNode> = [
            .init(logicalSize: 300, allocatedSize: 240, parent: .invalid, firstChild: .init(rawValue: 1), name: root, kind: .directory),
            .init(logicalSize: 300, allocatedSize: 30, parent: .init(rawValue: 0), nextSibling: .init(rawValue: 2), name: alpha, kind: .regularFile),
            .init(logicalSize: 100, allocatedSize: 90, parent: .init(rawValue: 0), nextSibling: .init(rawValue: 3), name: beta, kind: .regularFile),
            .init(logicalSize: 200, allocatedSize: 90, parent: .init(rawValue: 0), name: gamma, kind: .regularFile),
        ]
        return FileTree(root: .init(rawValue: 0), nodes: nodes, names: names)
    }
}

@MainActor
final class ScanFeatureModelTests: XCTestCase {
    func testDiscoveredVolumeCanStartScanThroughUserSelectionPanel() async throws {
        let fixture = try await completedResult()
        let volume = ScanVolume(
            id: "test-volume",
            url: fixture.rootURL,
            name: "A Very Long External Development Disk Name",
            totalCapacity: 1_000,
            availableCapacity: 400,
            isInternal: false,
            isRemovable: true
        )
        let picker = StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))])
        let model = ScanFeatureModel(
            scanner: StubScanner(sessions: [.completed(fixture)]),
            folderPicker: picker,
            volumeDiscovery: StubVolumeDiscovery(volumes: [volume]),
            projector: EmptyProjector()
        )

        await model.discoverVolumesIfNeeded()
        model.chooseVolume(try XCTUnwrap(model.availableVolumes.first))
        await waitUntil { model.phase == .completed }

        XCTAssertEqual(model.availableVolumes.map(\.name), [volume.name])
        XCTAssertEqual(picker.initialDirectories, [volume.url])
        XCTAssertEqual(picker.prompts, ["Scan"])
    }

    func testCurrentFolderPickerActionDoesNotFallBackToDisplayedParent() {
        let parent = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let downloads = parent.appending(path: "Downloads", directoryHint: .isDirectory)

        XCTAssertEqual(
            AppKitFolderPicker.resolvedSelectionURL(
                selectedURL: downloads,
                currentDirectoryURL: parent,
                choseCurrentFolder: true,
                acceptedSelection: false
            ),
            downloads
        )
        XCTAssertEqual(
            AppKitFolderPicker.resolvedSelectionURL(
                selectedURL: nil,
                currentDirectoryURL: downloads,
                choseCurrentFolder: true,
                acceptedSelection: false
            ),
            downloads
        )
    }

    func testCancelledPickerPreservesIdleStateWithoutStartingScan() async {
        let scanner = StubScanner(sessions: [])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [nil]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .idle }

        XCTAssertEqual(scanner.startCount, 0)
        XCTAssertNil(model.selectedRoot)
        XCTAssertNil(model.displayedResult)
    }

    func testSuccessfulSelectionStartsOneScanAndTeardownReleasesLeaseOnce() async throws {
        let fixture = try await completedResult()
        var releaseCount = 0
        let lease = FolderAccessLease(url: fixture.rootURL) { releaseCount += 1 }
        let scanner = StubScanner(sessions: [.completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: lease)]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }

        XCTAssertEqual(scanner.startCount, 1)
        XCTAssertEqual(model.displayedResult?.freshness, .current)
        model.teardown()
        model.teardown()
        XCTAssertEqual(releaseCount, 1)
    }

    func testFailedRescanKeepsPreviousResultExplicitlyStale() async throws {
        let fixture = try await completedResult()
        let firstLease = FolderAccessLease(url: fixture.rootURL)
        let scanner = StubScanner(sessions: [.completed(fixture), .failed(ScanError.rootMissing)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: firstLease)]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == ScanPhase.completed }
        model.rescan()
        await waitUntil { model.phase == ScanPhase.failed }

        XCTAssertEqual(scanner.startCount, 2)
        XCTAssertEqual(model.displayedResult?.freshness, .previousAfterFailedRescan)
        XCTAssertEqual(model.presentedError?.title, "Folder is no longer available")
    }

    func testNewSelectionReleasesOldLeaseOnlyAfterReplacementIsAccepted() async throws {
        let fixture = try await completedResult()
        var firstReleaseCount = 0
        let firstLease = FolderAccessLease(url: fixture.rootURL) { firstReleaseCount += 1 }
        let secondRoot = fixture.rootURL.deletingLastPathComponent()
        let secondLease = FolderAccessLease(url: secondRoot)
        let scanner = StubScanner(sessions: [.completed(fixture), .completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [
                .init(url: fixture.rootURL, lease: firstLease),
                .init(url: secondRoot, lease: secondLease),
            ]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        XCTAssertEqual(firstReleaseCount, 0)

        model.chooseFolder()
        await waitUntil { model.phase == .completed && scanner.startCount == 2 }
        XCTAssertEqual(firstReleaseCount, 1)
    }

    func testCancelIsSentOnceAndStateWaitsForTerminalResult() async throws {
        let fixture = try await completedResult()
        let gate = ResultGate()
        let model = ScanFeatureModel(
            scanner: StubScanner(sessions: [gate.makeSession()]),
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == ScanPhase.scanning }
        model.cancel()
        model.cancel()

        XCTAssertEqual(model.phase, .cancelling)
        XCTAssertFalse(model.canCancel)
        XCTAssertEqual(gate.cancellationCount, 1)

        gate.finish(with: fixture)
        await waitUntil { model.phase == ScanPhase.completed }
    }

    func testChartNavigationUsesCurrentSnapshotWithoutStartingAnotherScan() async throws {
        let fixture = try await completedNestedResult()
        let scanner = StubScanner(sessions: [.completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let directory = NodeID(rawValue: 1)
        model.select(node: directory)
        model.drillSelected()

        XCTAssertEqual(model.visibleRoot, directory)
        XCTAssertEqual(model.selectedNodeID, directory)
        XCTAssertEqual(scanner.startCount, 1)

        model.goBack()
        XCTAssertEqual(model.visibleRoot, fixture.tree.root)
        model.goForward()
        XCTAssertEqual(model.visibleRoot, directory)
        model.goUp()
        XCTAssertEqual(model.visibleRoot, fixture.tree.root)
        XCTAssertEqual(scanner.startCount, 1)
    }

    func testChartActivationDrillsDirectlyIntoClickedDirectory() async throws {
        let fixture = try await completedNestedResult()
        let scanner = StubScanner(sessions: [.completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let directory = NodeID(rawValue: 1)
        model.activateChart(item: .node(directory))

        XCTAssertEqual(model.visibleRoot, directory)
        XCTAssertEqual(scanner.startCount, 1)
    }

    func testSnapshotLocalIDsOutsideCurrentTreeAreRejected() async throws {
        let fixture = try await completedResult()
        let model = ScanFeatureModel(
            scanner: StubScanner(sessions: [.completed(fixture)]),
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let invalidForSnapshot = NodeID(rawValue: UInt32(fixture.tree.count + 100))

        model.select(node: invalidForSnapshot)
        model.select(item: .other(parent: invalidForSnapshot))

        XCTAssertEqual(model.selectedNodeID, fixture.tree.root)
        XCTAssertEqual(model.displayName(for: .node(invalidForSnapshot)), "Item")
        XCTAssertFalse(model.isInvalidated(invalidForSnapshot))
    }

    func testReplacementSnapshotDropsNavigationAndTrashMarks() async throws {
        let first = try await completedNestedResult()
        let replacement = try await completedResult()
        let scanner = StubScanner(sessions: [.completed(first), .completed(replacement)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: first.rootURL, lease: .init(url: first.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let folder = NodeID(rawValue: 1)
        let child = NodeID(rawValue: 2)
        model.drill(to: folder)
        model.select(node: child)
        model.toggleSelectedTrashMark()
        XCTAssertEqual(model.markedTrashCount, 1)

        model.rescan()
        await waitUntil { model.phase == .completed && scanner.startCount == 2 }

        XCTAssertEqual(model.displayedResult?.result.tree.count, replacement.tree.count)
        XCTAssertEqual(model.visibleRoot, replacement.tree.root)
        XCTAssertEqual(model.selectedNodeID, replacement.tree.root)
        XCTAssertEqual(model.markedTrashCount, 0)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }

    func testMarkedItemsMoveSequentiallyThenReconcileWithoutScannerRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-batch-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appending(path: "first.txt"))
        try Data("second".utf8).write(to: root.appending(path: "second.txt"))
        let fixture = try await FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
            .startScan(.init(rootURL: root))
            .result
            .value
        let trash = RecordingTrash()
        let scanner = StubScanner(sessions: [.completed(fixture), .completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: root, lease: .init(url: root))]),
            projector: EmptyProjector(),
            finder: NoopFinder(),
            trash: trash
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let items = Array(fixture.tree.children(of: fixture.tree.root))
        XCTAssertEqual(items.count, 2)
        model.select(node: items[0])
        model.toggleSelectedTrashMark()
        XCTAssertFalse(model.commandActions.canMoveSelectedToTrash)
        model.prepareMoveSelectedToTrash()
        XCTAssertNil(model.trashConfirmation)
        model.select(node: items[1])
        model.toggleSelectedTrashMark()
        XCTAssertEqual(model.markedTrashCount, 2)

        model.prepareMarkedItemsForTrash()
        await waitUntil { model.markedTrashConfirmation != nil }
        model.confirmMoveMarkedItemsToTrash()
        await waitUntil { model.phase == .completed && scanner.startCount == 1 && model.lastFileActionStatus != nil }

        let trashCallCount = await trash.callCount()
        XCTAssertEqual(trashCallCount, 2)
        XCTAssertEqual(scanner.startCount, 1)
        XCTAssertEqual(model.markedTrashCount, 0)
        XCTAssertFalse(model.hasInvalidatedFileActions)
    }

    func testMarkedBatchStopsAfterFailureAndReconcilesSuccessfulMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-batch-failure-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("first".utf8).write(to: root.appending(path: "first.txt"))
        try Data("second".utf8).write(to: root.appending(path: "second.txt"))
        let fixture = try await FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
            .startScan(.init(rootURL: root))
            .result
            .value
        let trash = FailingAfterFirstTrash()
        let scanner = StubScanner(sessions: [.completed(fixture), .completed(fixture)])
        let model = ScanFeatureModel(
            scanner: scanner,
            folderPicker: StubPicker(selections: [.init(url: root, lease: .init(url: root))]),
            projector: EmptyProjector(),
            finder: NoopFinder(),
            trash: trash
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        for node in fixture.tree.children(of: fixture.tree.root) {
            model.select(node: node)
            model.toggleSelectedTrashMark()
        }
        model.prepareMarkedItemsForTrash()
        await waitUntil { model.markedTrashConfirmation != nil }
        model.confirmMoveMarkedItemsToTrash()
        await waitUntil { model.phase == .completed && scanner.startCount == 1 && model.lastFileActionStatus != nil }

        let attemptCount = await trash.callCount()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(scanner.startCount, 1)
        XCTAssertEqual(model.fileActionNotice?.title, "Trash batch stopped")
        XCTAssertEqual(model.markedTrashCount, 0)
    }

    func testMarkedFolderPreventsMarkingItsDescendant() async throws {
        let fixture = try await completedNestedResult()
        let model = ScanFeatureModel(
            scanner: StubScanner(sessions: [.completed(fixture)]),
            folderPicker: StubPicker(selections: [.init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))]),
            projector: EmptyProjector()
        )

        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        let folder = try XCTUnwrap(fixture.tree.children(of: fixture.tree.root).first { fixture.tree[$0].kind == .directory })
        let child = try XCTUnwrap(fixture.tree.children(of: folder).first { _ in true })
        model.select(node: folder)
        model.toggleSelectedTrashMark()
        model.select(node: child)
        model.toggleSelectedTrashMark()

        XCTAssertEqual(model.markedTrashCount, 1)
        model.select(node: folder)
        model.toggleSelectedTrashMark()
        XCTAssertEqual(model.markedTrashCount, 0)
    }

    private func completedResult() async throws -> ScanResult {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("test".utf8).write(to: root.appending(path: "item.txt"))
        return try await FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
            .startScan(.init(rootURL: root))
            .result
            .value
    }

    private func completedNestedResult() async throws -> ScanResult {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-m3-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "child", directoryHint: .isDirectory), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("test".utf8).write(to: root.appending(path: "child/item.txt"))
        return try await FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
            .startScan(.init(rootURL: root))
            .result
            .value
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

@MainActor
private final class StubPicker: FolderPicking {
    private var selections: [FolderSelection?]
    private(set) var initialDirectories: [URL?] = []
    private(set) var prompts: [String] = []

    init(selections: [FolderSelection?]) {
        self.selections = selections
    }

    func chooseFolder(startingAt initialDirectory: URL?, prompt: String) async -> FolderSelection? {
        initialDirectories.append(initialDirectory)
        prompts.append(prompt)
        return selections.isEmpty ? nil : selections.removeFirst()
    }
}

private struct StubVolumeDiscovery: VolumeDiscovering {
    let volumes: [ScanVolume]

    func discoverLocalVolumes() async -> [ScanVolume] { volumes }
}

private final class StubScanner: FileSystemScanner, @unchecked Sendable {
    private var sessions: [ScanSession]
    private(set) var startCount = 0

    init(sessions: [ScanSession]) {
        self.sessions = sessions
    }

    func startScan(_ request: ScanRequest) -> ScanSession {
        startCount += 1
        precondition(!sessions.isEmpty, "Unexpected scan start")
        return sessions.removeFirst()
    }
}

private struct EmptyProjector: LargestItemsProjecting {
    func project(tree: FileTree, root: NodeID, metric: SizeMetric, limit: Int) async throws -> [LargestItemRow] {
        []
    }
}

@MainActor
private final class NoopFinder: FinderService {
    func reveal(_ target: ValidatedFileActionTarget) {}
}

private actor RecordingTrash: TrashService {
    private var targets: [SnapshotFileActionTarget] = []

    func moveToTrash(_ target: SnapshotFileActionTarget) async throws -> TrashReceipt {
        targets.append(target)
        return .init(
            originalURL: target.rootURL,
            resultingURL: target.rootURL.appending(path: "trash-receipt"),
            movedIdentity: target.componentsFromRootChild.last?.expectedIdentity ?? target.rootIdentity,
            completedAt: ContinuousClock().now
        )
    }

    func callCount() -> Int { targets.count }
}

private actor FailingAfterFirstTrash: TrashService {
    private var callCountValue = 0

    func moveToTrash(_ target: SnapshotFileActionTarget) async throws -> TrashReceipt {
        callCountValue += 1
        guard callCountValue == 1 else { throw FileActionError.targetChanged }
        return .init(
            originalURL: target.rootURL,
            resultingURL: target.rootURL.appending(path: "trash-receipt"),
            movedIdentity: target.componentsFromRootChild.last?.expectedIdentity ?? target.rootIdentity,
            completedAt: ContinuousClock().now
        )
    }

    func callCount() -> Int { callCountValue }
}

private final class ResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScanResult, Error>?
    private var result: Result<ScanResult, Error>?
    private(set) var cancellationCount = 0

    func makeSession() -> ScanSession {
        let pair = AsyncStream<ScanUpdate>.makeStream()
        pair.continuation.finish()
        return ScanSession(
            updates: pair.stream,
            result: Task { try await self.awaitResult() },
            cancellation: { self.recordCancellation() }
        )
    }

    func finish(with result: ScanResult) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.result = .success(result)
            lock.unlock()
        }
    }

    private func awaitResult() async throws -> ScanResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                self.result = nil
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func recordCancellation() {
        lock.lock()
        cancellationCount += 1
        lock.unlock()
    }
}

private extension ScanSession {
    static func completed(_ result: ScanResult) -> ScanSession {
        let pair = AsyncStream<ScanUpdate>.makeStream()
        pair.continuation.finish()
        return ScanSession(updates: pair.stream, result: Task { result }, cancellation: {})
    }

    static func failed(_ error: Error) -> ScanSession {
        let pair = AsyncStream<ScanUpdate>.makeStream()
        pair.continuation.finish()
        return ScanSession(updates: pair.stream, result: Task { throw error }, cancellation: {})
    }
}
