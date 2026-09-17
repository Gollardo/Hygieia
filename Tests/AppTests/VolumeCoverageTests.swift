import AppKit
import SwiftUI
import XCTest
@testable import Hygieia
import HygieiaDomain
import HygieiaFileOperations
import HygieiaScannerCore

@MainActor
final class VolumeCoverageFeatureTests: XCTestCase {
    func testUnknownCapacityNeverBecomesZeroOrAProgressBar() {
        XCTAssertNil(volume(total: nil, available: nil).usedFraction)
        XCTAssertEqual(volume(total: 100, available: nil).capacityDescription, "Capacity unavailable")
        XCTAssertNil(volume(total: 100, available: 101).usedFraction)
        XCTAssertEqual(volume(total: 100, available: 101).capacityDescription, "Capacity unavailable")
        XCTAssertEqual(volume(total: 100, available: 0).usedFraction, 1)
        XCTAssertEqual(volume(total: 100, available: 100).usedFraction, 0)
        XCTAssertNil(volume(total: 0, available: 0).usedFraction)
    }

    func testRefreshFailurePreservesListAndRetryClearsWarning() async {
        let disk = volume()
        let discovery = SequenceDiscovery([.success(.init(volumes: [disk])), .failure(VolumeDiscoveryError.unavailable), .success(.init(volumes: []))])
        let model = model(discovery: discovery)
        await model.discoverVolumesIfNeeded()
        XCTAssertEqual(model.availableVolumes, [disk])
        model.refreshVolumes()
        await waitUntil { model.volumeDiscoveryMessage != nil && !model.isDiscoveringVolumes }
        XCTAssertEqual(model.availableVolumes, [disk])
        model.refreshVolumes()
        await waitUntil { model.availableVolumes.isEmpty && model.volumeDiscoveryMessage == nil }
        model.teardown()
    }

    func testUnreadableVolumesAreNotReportedAsAnEmptySuccessfulList() async {
        let model = model(discovery: SequenceDiscovery([.success(.init(volumes: [], unreadableVolumeCount: 2))]))
        await model.discoverVolumesIfNeeded()
        XCTAssertNotNil(model.volumeDiscoveryMessage)
        XCTAssertFalse(model.isDiscoveringVolumes)
        model.teardown()
    }

    func testDisappearedVolumeDoesNotOpenPickerOrStartScan() async {
        let picker = CoveragePicker()
        let scanner = CoverageScanner()
        let model = model(discovery: SequenceDiscovery([.success(.init(volumes: []))]), picker: picker, scanner: scanner)
        model.chooseVolume(volume())
        await waitUntil { model.presentedError != nil }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(picker.calls, 0)
        XCTAssertTrue(scanner.requests.isEmpty)
        XCTAssertTrue(model.canChooseFolder)
        model.teardown()
    }

    func testVolumePickerCanSelectSubfolderAndRejectsConcurrentSelection() async throws {
        let disk = volume()
        let fixture = try await result()
        let picker = CoveragePicker(selection: .init(url: fixture.rootURL, lease: .init(url: fixture.rootURL)))
        let scanner = CoverageScanner(results: [fixture])
        let model = model(discovery: SequenceDiscovery([.success(.init(volumes: [disk]))]), picker: picker, scanner: scanner)
        model.chooseVolume(disk)
        model.chooseFolder()
        await waitUntil { model.displayedResult != nil }
        XCTAssertEqual(picker.calls, 1)
        XCTAssertEqual(picker.initialURL, disk.url)
        XCTAssertEqual(scanner.requests.first?.rootURL, fixture.rootURL)
        XCTAssertNil(scanner.requests.first?.expectedRootIdentity)
        model.teardown()
    }

    func testCancelledDiscoveryClearsBusyStateAndCanRetry() async {
        let discovery = GatedDiscovery()
        let model = model(discovery: discovery)
        let task = Task { await model.discoverVolumesIfNeeded() }
        await waitUntil { model.isDiscoveringVolumes }
        task.cancel()
        await discovery.finish(.init(volumes: [volume()]))
        await task.value
        XCTAssertFalse(model.isDiscoveringVolumes)
        XCTAssertTrue(model.availableVolumes.isEmpty)
        model.refreshVolumes()
        await waitUntil { model.isDiscoveringVolumes }
        await discovery.finish(.init(volumes: [volume()]))
        await waitUntil { !model.availableVolumes.isEmpty }
        model.teardown()
    }

    func testTeardownDiscardsLateDiscovery() async {
        let discovery = GatedDiscovery()
        let model = model(discovery: discovery)
        let task = Task { await model.discoverVolumesIfNeeded() }
        await waitUntil { model.isDiscoveringVolumes }
        model.teardown()
        await discovery.finish(.init(volumes: [volume()]))
        await task.value
        XCTAssertFalse(model.isDiscoveringVolumes)
        XCTAssertTrue(model.availableVolumes.isEmpty)
    }

    func testTeardownPreventsQueuedPickerAndRefreshFromStarting() async {
        let picker = CoveragePicker()
        let model = model(discovery: SequenceDiscovery([.success(.init(volumes: [volume()]))]), picker: picker)
        model.chooseFolder()
        model.refreshVolumes()
        model.teardown()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(picker.calls, 0)
        XCTAssertTrue(model.availableVolumes.isEmpty)
        XCTAssertFalse(model.isDiscoveringVolumes)
    }

    func testRescanCarriesSnapshotRootIdentity() async throws {
        let fixture = try await result()
        let scanner = CoverageScanner(results: [fixture, fixture])
        let picker = CoveragePicker(selection: .init(url: fixture.rootURL, lease: .init(url: fixture.rootURL)))
        let model = model(picker: picker, scanner: scanner)
        model.chooseFolder()
        await waitUntil { model.phase == .completed }
        model.rescan()
        await waitUntil { scanner.requests.count == 2 && model.phase == .completed }
        XCTAssertEqual(scanner.requests[1].expectedRootIdentity, fixture.tree.identity(for: fixture.tree.root))
        model.teardown()
    }

    func testUnavailableResultIsInspectableButCannotBeTrashed() async throws {
        let fixture = try await result(unavailable: true)
        let model = model(picker: CoveragePicker(selection: .init(url: fixture.rootURL, lease: .init(url: fixture.rootURL))), scanner: CoverageScanner(results: [fixture]))
        model.chooseFolder()
        await waitUntil { model.displayedResult != nil }
        model.select(node: .init(rawValue: 1))
        XCTAssertEqual(model.phase, .completedWithIssues)
        XCTAssertEqual(model.displayedResult?.freshness, .sourceUnavailable)
        XCTAssertEqual(model.fileActionEligibility(.moveToTrash), .denied(.snapshotNotCurrent))
        XCTAssertTrue(ScanStatusView.shouldDisplay(for: model))
        model.teardown()
    }

    func testCoverageWarningIsIndependentOfCompletionAndFreshness() async throws {
        let incomplete = try await result(denied: true)
        let displayed = DisplayedScanResult(result: incomplete, freshness: .current)
        XCTAssertTrue(displayed.hasWarning)
        XCTAssertEqual(displayed.statusTitle, "Coverage incomplete")
        let complete = try await result()
        XCTAssertFalse(DisplayedScanResult(result: complete, freshness: .current).hasWarning)
        XCTAssertEqual(DisplayedScanResult(result: complete, freshness: .partial).statusTitle, "Scan cancelled · partial result")
    }

    func testPermissionPresentationDoesNotClaimFDAIsMissing() {
        let denied = ScanFailurePresentation.make(from: ScanError.rootPermissionDenied(13))
        XCTAssertEqual(denied.title, "Access to the selected folder was denied")
        XCTAssertTrue(denied.message.contains("does not establish Full Disk Access status"))
        XCTAssertNotEqual(ScanFailurePresentation.make(from: ScanError.rootLocalityUnknown).title, "Network volumes are not scanned")
    }

    func testRenderM5StatesForVisualReview() async throws {
        let empty = model(discovery: SequenceDiscovery([.success(.init(volumes: [volume(total: nil, available: nil), volume(total: 1_000_000_000_000, available: 120_000_000_000, id: "second")]))]))
        await empty.discoverVolumesIfNeeded()
        try await render(ScanRootView(model: empty), size: .init(width: 1440, height: 1024), name: "m5-empty")
        try await render(ScanRootView(model: empty), size: .init(width: 980, height: 680), name: "m5-empty-compact")
        let unavailable = try await result(unavailable: true, denied: true)
        try await render(ScanCoverageView(displayed: .init(result: unavailable, freshness: .sourceUnavailable)), size: .init(width: 520, height: 480), name: "m5-coverage")
        let content = model(picker: CoveragePicker(selection: .init(url: unavailable.rootURL, lease: .init(url: unavailable.rootURL))), scanner: CoverageScanner(results: [unavailable]))
        content.chooseFolder()
        await waitUntil { content.sunburstLayout != nil }
        try await render(ScanRootView(model: content), size: .init(width: 1440, height: 1024), name: "m5-unavailable-content")
        let error = model(discovery: SequenceDiscovery([.failure(VolumeDiscoveryError.unavailable)]))
        await error.discoverVolumesIfNeeded()
        try await render(ScanRootView(model: error), size: .init(width: 1440, height: 1024), name: "m5-discovery-error")
        empty.teardown()
        error.teardown()
        content.teardown()
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String) async throws {
        let hosted = NSHostingView(rootView: view.environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosted
        hosted.frame = .init(origin: .zero, size: size)
        hosted.layoutSubtreeIfNeeded()
        // Geometry publication schedules bounded projection work; let that settle
        // before capturing the actual content state rather than its first frame.
        try await Task.sleep(for: .milliseconds(150))
        hosted.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appending(path: name + ".png")
        try data.write(to: url)
        print("M5_QA_IMAGE: \(url.path)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.contentView = nil
    }

    private func model(discovery: any VolumeDiscovering = SequenceDiscovery([]), picker: CoveragePicker = CoveragePicker(), scanner: CoverageScanner = CoverageScanner()) -> ScanFeatureModel {
        ScanFeatureModel(scanner: scanner, folderPicker: picker, volumeDiscovery: discovery, projector: LargestItemsProjector())
    }

    private func volume(total: UInt64? = 1_000, available: UInt64? = 500, id: String = "first") -> ScanVolume {
        .init(id: id, url: URL(fileURLWithPath: "/synthetic-volume/\(id)"), name: "External Development Disk — Очень длинное имя рабочего архива", totalCapacity: total, availableCapacity: available, isInternal: false, isRemovable: true)
    }

    private func result(unavailable: Bool = false, denied: Bool = false) async throws -> ScanResult {
        let pair = AsyncStream<ScanUpdate>.makeStream()
        let coordinator = try ScanCoordinator(rootURL: URL(fileURLWithPath: "/Synthetic QA/Selected folder with a long name/Архив документов"), root: .init(displayName: "Архив документов", identity: .init(device: 1, inode: 10)), configuration: .init(workerLimit: 1), updates: pair.continuation)
        let claimed = await coordinator.claim()
        let lease = try XCTUnwrap(claimed)
        try await coordinator.submit(lease, result: .init(workID: lease.workID, entries: [.init(name: "item.txt", kind: .regularFile, logicalSize: 5, allocatedSize: 4096, identity: .init(device: 1, inode: 11))], entryIssues: denied ? [.init(name: "Private Library/Very long inaccessible subfolder/Документы", failure: .permissionDenied(code: 13))] : []))
        return try await coordinator.finish(sourceUnavailable: unavailable)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }
}

private actor SequenceDiscovery: VolumeDiscovering {
    var results: [Result<VolumeDiscoverySnapshot, Error>]
    init(_ results: [Result<VolumeDiscoverySnapshot, Error>]) { self.results = results }
    func discoverLocalVolumes() async throws -> VolumeDiscoverySnapshot {
        results.isEmpty ? .init(volumes: []) : try results.removeFirst().get()
    }
}

private actor GatedDiscovery: VolumeDiscovering {
    private var continuation: CheckedContinuation<VolumeDiscoverySnapshot, Never>?
    private var pending: VolumeDiscoverySnapshot?
    func discoverLocalVolumes() async throws -> VolumeDiscoverySnapshot {
        if let pending { self.pending = nil; return pending }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ snapshot: VolumeDiscoverySnapshot) {
        if let continuation { self.continuation = nil; continuation.resume(returning: snapshot) }
        else { pending = snapshot }
    }
}

@MainActor
private final class CoveragePicker: FolderPicking {
    var selection: FolderSelection?
    var calls = 0
    var initialURL: URL?
    init(selection: FolderSelection? = nil) { self.selection = selection }
    func chooseFolder(startingAt initialDirectory: URL?, prompt: String) async -> FolderSelection? {
        calls += 1
        initialURL = initialDirectory
        return selection
    }
}

private final class CoverageScanner: FileSystemScanner, @unchecked Sendable {
    var results: [ScanResult]
    var requests: [ScanRequest] = []
    init(results: [ScanResult] = []) { self.results = results }
    func startScan(_ request: ScanRequest) -> ScanSession {
        requests.append(request)
        let pair = AsyncStream<ScanUpdate>.makeStream()
        pair.continuation.finish()
        guard !results.isEmpty else { return .init(updates: pair.stream, result: Task { throw ScanError.rootMissing }, cancellation: {}) }
        let result = results.removeFirst()
        return .init(updates: pair.stream, result: Task { result }, cancellation: {})
    }
}
