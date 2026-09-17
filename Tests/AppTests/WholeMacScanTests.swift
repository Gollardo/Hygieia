import AppKit
import SwiftUI
import XCTest
@testable import Hygieia
import HygieiaDomain
import HygieiaScannerCore

@MainActor
final class WholeMacScanTests: XCTestCase {
    func testSystemDataPolicyExcludesServiceAndHiddenMounts() {
        XCTAssertTrue(FoundationVolumeDiscovery.includesMount(path: "/", browsable: false))
        XCTAssertTrue(FoundationVolumeDiscovery.includesMount(path: "/System/Volumes/Data", browsable: false))
        XCTAssertFalse(FoundationVolumeDiscovery.includesMount(path: "/System/Volumes/Preboot", browsable: true))
        XCTAssertFalse(FoundationVolumeDiscovery.includesMount(path: "/private/hidden", browsable: false))
        XCTAssertTrue(FoundationVolumeDiscovery.includesMount(path: "/Volumes/External", browsable: true))
    }

    func testLiveDiscoveryExposesSystemAndDataAsSeparateRoots() async throws {
        guard FileManager.default.fileExists(atPath: "/System/Volumes/Data") else { throw XCTSkip("No System/Data pair") }
        let discovered = try await FoundationVolumeDiscovery().discoverLocalVolumes()
        let system = try XCTUnwrap(discovered.volumes.first { $0.url.path == "/" })
        let data = try XCTUnwrap(discovered.volumes.first { $0.url.path == "/System/Volumes/Data" })
        XCTAssertNotEqual(system.id, data.id)
        XCTAssertNotNil(system.rootIdentity)
        XCTAssertNotNil(data.rootIdentity)
        XCTAssertFalse(discovered.volumes.contains { $0.url.path == "/System/Volumes/Preboot" })
    }

    func testPlanningDeduplicatesPathsAndExternalVolumesRequireOptIn() async {
        let first = disk("one")
        var duplicate = first
        duplicate.rootIdentity = .init(device: 8, inode: 9)
        let external = disk("external", internalDisk: false)
        let discovery = MacDiscovery([first, duplicate, external])
        let model = model(discovery)
        await model.refresh()
        XCTAssertEqual(model.reports.count, 2)
        XCTAssertEqual(model.selectedIDs, [first.id])
        XCTAssertTrue(model.canStart)
    }

    func testRootLimitAndUnreadableDiscoveryAreVisible() async {
        let discovery = MacDiscovery((0..<70).map { disk("\($0)") }, unreadable: 1)
        let model = model(discovery)
        await model.refresh()
        XCTAssertEqual(model.reports.count, 64)
        XCTAssertNotNil(model.discoveryWarning)
        await discovery.fail()
        await model.refresh()
        XCTAssertEqual(model.reports.count, 64)
        XCTAssertNotNil(model.discoveryWarning)
        XCTAssertFalse(model.isRefreshing)
    }

    func testSerialRootsRetainProvenanceAndReportedSizesWithoutTrees() async {
        let volumes = [disk("one"), disk("two")]
        let gate = MacGate()
        let scanner = MacScanner(gate: gate)
        let model = model(MacDiscovery(volumes), scanner: scanner)
        await model.refresh()
        model.start()
        model.start()
        await wait { scanner.requests.count == 1 }
        XCTAssertEqual(model.reports[1].state, .queued)
        // Actor/main-thread remain responsive while the scanner is blocked.
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.canStart)
        await gate.release()
        await wait { !model.isRunning }
        XCTAssertEqual(scanner.requests.map(\.rootURL), volumes.map(\.url))
        XCTAssertEqual(scanner.requests.first?.expectedRootIdentity, volumes[0].rootIdentity)
        XCTAssertTrue(model.reports.allSatisfy { $0.state == .scanned })
        XCTAssertTrue(model.reports.allSatisfy { $0.allocatedBytes == 4096 && $0.finishedAt != nil && $0.identity != nil })
        XCTAssertTrue(model.status.contains("limited"))
    }

    func testCancelledPickerAndWrongFolderNeverBecomeVolumeScan() async {
        let volumes = [disk("one"), disk("two")]
        let picker = MacPicker(mode: .cancel)
        let scanner = MacScanner()
        let model = model(MacDiscovery(volumes), picker: picker, scanner: scanner)
        await model.refresh()
        model.start()
        await wait { !model.isRunning }
        XCTAssertTrue(model.reports.allSatisfy { $0.state == .skipped })
        XCTAssertTrue(scanner.requests.isEmpty)
        picker.mode = .wrongFolder
        model.start()
        await wait { !model.isRunning }
        XCTAssertTrue(scanner.requests.isEmpty)
        XCTAssertTrue(model.reports.allSatisfy { $0.detail.contains("different folder") })
        XCTAssertEqual(picker.releases, 2)
    }

    func testEjectBeforePickerAndReplacementAfterPickerFailClosed() async {
        let volume = disk("one")
        let discovery = MacDiscovery([volume])
        let picker = MacPicker()
        let scanner = MacScanner()
        let model = model(discovery, picker: picker, scanner: scanner)
        await model.refresh()
        await discovery.replace([])
        model.start()
        await wait { !model.isRunning }
        XCTAssertEqual(model.reports[0].state, .unavailable)
        XCTAssertEqual(picker.calls, 0)
        await discovery.replace([volume])
        picker.afterSelection = {
            var replacement = volume
            replacement.rootIdentity = .init(device: 2, inode: 30)
            await discovery.replace([replacement])
        }
        model.start()
        await wait { !model.isRunning }
        XCTAssertEqual(model.reports[0].state, .unavailable)
        XCTAssertTrue(scanner.requests.isEmpty)
        XCTAssertEqual(picker.releases, 1)
    }

    func testCancelDuringBlockedIOStopsQueueAndDoesNotAccumulateWorkers() async {
        let gate = MacGate()
        let scanner = MacScanner(gate: gate)
        let picker = MacPicker()
        let model = model(MacDiscovery([disk("one"), disk("two")]), picker: picker, scanner: scanner)
        await model.refresh()
        model.start()
        await wait { scanner.requests.count == 1 }
        model.cancel()
        model.start()
        XCTAssertTrue(model.isCancelling)
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(scanner.cancelCount, 1)
        XCTAssertTrue(model.status.contains("system call"))
        await gate.release()
        await wait { !model.isRunning }
        XCTAssertEqual(scanner.requests.count, 1)
        XCTAssertTrue(model.reports.allSatisfy { $0.state == .cancelled })
        XCTAssertEqual(picker.releases, 1)
    }

    func testWholeMacPreventsConcurrentSingleRootSession() async {
        let gate = MacGate()
        let scanner = MacScanner(gate: gate)
        let picker = MacPicker()
        let feature = ScanFeatureModel(scanner: scanner, folderPicker: picker,
            volumeDiscovery: MacDiscovery([disk("one")]), projector: LargestItemsProjector())
        await feature.wholeMac.refresh()
        feature.wholeMac.start()
        await wait { scanner.requests.count == 1 }
        XCTAssertFalse(feature.canChooseFolder)
        feature.chooseFolder()
        feature.rescan()
        XCTAssertEqual(scanner.requests.count, 1)
        feature.wholeMac.cancel()
        await gate.release()
        await wait { !feature.wholeMac.isRunning }
        XCTAssertTrue(feature.canChooseFolder)
        feature.teardown()
    }

    func testCancelWhilePickerIsOpenReleasesLateGrantWithoutStartingScanner() async {
        let gate = MacGate()
        let picker = MacPicker()
        picker.afterSelection = { await gate.wait() }
        let scanner = MacScanner()
        let model = model(MacDiscovery([disk("one"), disk("two")]), picker: picker, scanner: scanner)
        await model.refresh()
        model.start()
        await wait { picker.calls == 1 }
        model.cancel()
        await gate.release()
        await wait { !model.isRunning }
        XCTAssertEqual(picker.releases, 1)
        XCTAssertTrue(scanner.requests.isEmpty)
        XCTAssertTrue(model.reports.allSatisfy { $0.state == .cancelled })
    }

    func testTeardownDiscardsLateResultAndReleasesSelection() async {
        let gate = MacGate()
        let scanner = MacScanner(gate: gate)
        let picker = MacPicker()
        let model = model(MacDiscovery([disk("one")]), picker: picker, scanner: scanner)
        await model.refresh()
        model.start()
        await wait { scanner.requests.count == 1 }
        model.teardown()
        await gate.release()
        await wait { picker.releases == 1 }
        XCTAssertNil(model.reports[0].allocatedBytes)
        XCTAssertFalse(model.isRunning)
    }

    func testFailureDoesNotAbortOtherRootsAndPermissionEvidenceStaysIncomplete() async {
        let scanner = MacScanner(failingPath: disk("one").url.path, denied: true)
        let model = model(MacDiscovery([disk("one"), disk("two")]), scanner: scanner)
        await model.refresh()
        model.start()
        await wait { !model.isRunning }
        XCTAssertEqual(model.reports[0].state, .failed)
        XCTAssertNil(model.reports[0].logicalBytes)
        XCTAssertEqual(model.reports[1].state, .incomplete)
        XCTAssertEqual(model.reports[1].issueCounts[.permissionDenied], 25)
        XCTAssertEqual(model.reports[1].samples.count, 20)
        XCTAssertTrue(WholeMacScanModel.accessNotice.contains("not verified"))
    }

    func testUnavailableResultRetainsEvidenceAndUnselectedRootIsExplicit() async {
        let scanner = MacScanner(unavailable: true)
        let model = model(MacDiscovery([disk("one"), disk("external", internalDisk: false)]), scanner: scanner)
        await model.refresh()
        model.start()
        await wait { !model.isRunning }
        XCTAssertEqual(model.reports[0].state, .unavailable)
        XCTAssertNotNil(model.reports[0].logicalBytes)
        XCTAssertEqual(model.reports[1].state, .notSelected)
        XCTAssertEqual(scanner.requests.count, 1)
    }

    func testRenderWholeMacPlanningAndIncompleteReport() async throws {
        let discovery = MacDiscovery([disk("one"), disk("external", internalDisk: false)])
        let model = model(discovery, scanner: MacScanner(denied: true))
        await model.refresh()
        try await render(model, name: "m5-whole-mac-plan")
        model.start()
        await wait { !model.isRunning }
        try await render(model, name: "m5-whole-mac-incomplete")
        await discovery.fail()
        await model.refresh()
        try await render(model, name: "m5-whole-mac-discovery-error")
    }

    private func model(_ discovery: MacDiscovery, picker: MacPicker = MacPicker(), scanner: MacScanner = MacScanner()) -> WholeMacScanModel {
        WholeMacScanModel(scanner: scanner, picker: picker, discovery: discovery)
    }
    private func disk(_ id: String, internalDisk: Bool = true) -> ScanVolume {
        .init(id: id, url: URL(fileURLWithPath: "/synthetic/\(id)"), name: "\(id) — Архив документов и разработки — Very long local disk name", totalCapacity: nil, availableCapacity: nil, isInternal: internalDisk, isRemovable: !internalDisk, rootIdentity: .init(device: 1, inode: 10))
    }
    private func wait(_ predicate: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition not reached", file: file, line: line)
    }
    private func render(_ model: WholeMacScanModel, name: String) async throws {
        let host = NSHostingView(rootView: WholeMacScanView(model: model, explore: { _ in }).transaction { $0.disablesAnimations = true })
        let size = NSSize(width: 760, height: 650)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = .init(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
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
}

private actor MacDiscovery: VolumeDiscovering {
    var volumes: [ScanVolume]
    var unreadable: Int
    var failure = false
    init(_ volumes: [ScanVolume], unreadable: Int = 0) { self.volumes = volumes; self.unreadable = unreadable }
    func discoverLocalVolumes() throws -> VolumeDiscoverySnapshot {
        if failure { throw VolumeDiscoveryError.unavailable }
        return .init(volumes: volumes, unreadableVolumeCount: unreadable)
    }
    func fail() { failure = true }
    func replace(_ volumes: [ScanVolume]) { self.volumes = volumes }
}

@MainActor
private final class MacPicker: FolderPicking {
    enum Mode { case correct, cancel, wrongFolder }
    var mode: Mode
    var calls = 0
    var releases = 0
    var afterSelection: (() async -> Void)?
    init(mode: Mode = .correct) { self.mode = mode }
    func chooseFolder(startingAt initialDirectory: URL?, prompt: String) async -> FolderSelection? {
        calls += 1
        await afterSelection?()
        guard mode != .cancel, let root = initialDirectory else { return nil }
        let url = mode == .wrongFolder ? root.appending(path: "subfolder") : root
        return .init(url: url, lease: .init(url: url, releaseAccess: { [weak self] in self?.releases += 1 }))
    }
}

private actor MacGate {
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class MacScanner: FileSystemScanner, @unchecked Sendable {
    let gate: MacGate?
    let failingPath: String?
    let denied: Bool
    let unavailable: Bool
    private let lock = NSLock()
    private var recorded: [ScanRequest] = []
    private var cancellations = 0
    var requests: [ScanRequest] { lock.withLock { recorded } }
    var cancelCount: Int { lock.withLock { cancellations } }
    init(gate: MacGate? = nil, failingPath: String? = nil, denied: Bool = false, unavailable: Bool = false) {
        self.gate = gate; self.failingPath = failingPath; self.denied = denied; self.unavailable = unavailable
    }
    func startScan(_ request: ScanRequest) -> ScanSession {
        lock.withLock { recorded.append(request) }
        let stream = AsyncStream<ScanUpdate>.makeStream()
        let result = Task {
            await gate?.wait()
            defer { stream.continuation.finish() }
            if request.rootURL.path == failingPath { throw ScanError.rootPermissionDenied(13) }
            let coordinator = try ScanCoordinator(rootURL: request.rootURL, root: .init(displayName: "Root", identity: .init(device: 1, inode: 10)), configuration: .init(workerLimit: 1), updates: stream.continuation)
            if let work = await coordinator.claim() {
                try await coordinator.submit(work, result: .init(workID: work.workID, entries: [.init(name: "fixture.txt", kind: .regularFile, logicalSize: 5, allocatedSize: 4096, identity: .init(device: 1, inode: 11))], entryIssues: denied ? (0..<25).map { .init(name: "private-\($0)", failure: .permissionDenied(code: 13)) } : []))
            }
            return try await coordinator.finish(sourceUnavailable: unavailable)
        }
        return .init(updates: stream.stream, result: result, cancellation: { [self] in lock.withLock { cancellations += 1 } })
    }
}
