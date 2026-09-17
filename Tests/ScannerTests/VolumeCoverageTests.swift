import Darwin
import Foundation
import XCTest
import HygieiaDomain
import HygieiaScannerCore
import HygieiaFoundationScanner

final class VolumeCoverageTests: XCTestCase {
    func testForeignVolumeAndSymlinkAreRecordedButNeverScheduled() async throws {
        let coordinator = try makeCoordinator()
        let claimed = await coordinator.claim()
        let lease = try XCTUnwrap(claimed)
        try await coordinator.submit(lease, result: .init(workID: lease.workID, entries: [
            .init(name: "external", kind: .directory, logicalSize: 0, allocatedSize: 0, identity: .init(device: 2, inode: 10)),
            .init(name: "link", kind: .symbolicLink, logicalSize: 8, allocatedSize: 0, identity: .init(device: 1, inode: 11)),
        ]))
        let next = await coordinator.claim()
        XCTAssertNil(next)
        let result = try await coordinator.finish()
        XCTAssertEqual(result.completion, .complete)
        XCTAssertTrue(result.hasIncompleteCoverage)
        XCTAssertEqual(result.issues.counts[.volumeBoundary], 1)
        XCTAssertTrue(result.tree[.init(rawValue: 1)].flags.contains(.volumeBoundary))
        XCTAssertEqual(result.tree.count, 3)
    }

    func testPermissionAndMetadataFailuresKeepBoundedSamplesAndIncompleteCoverage() async throws {
        let coordinator = try makeCoordinator(sampleLimit: 1)
        let claimed = await coordinator.claim()
        let lease = try XCTUnwrap(claimed)
        try await coordinator.submit(lease, result: .init(workID: lease.workID, entryIssues: [
            .init(name: "private", failure: .permissionDenied(code: EACCES)),
            .init(name: "gone", failure: .disappeared(code: ENOENT)),
            .init(name: "unknown", failure: .metadataReadFailed(code: EIO)),
        ]))
        let result = try await coordinator.finish()
        XCTAssertEqual(result.completion, .complete)
        XCTAssertTrue(result.hasIncompleteCoverage)
        XCTAssertEqual(result.issues.totalCount, 3)
        XCTAssertEqual(result.issues.samples.count, 1)
        XCTAssertEqual(result.issues.samples.first?.relativePath, "private")
        XCTAssertEqual(result.issues.counts[.permissionDenied], 1)
    }

    func testCancellationWithoutIssuesIsStillIncomplete() async throws {
        let coordinator = try makeCoordinator()
        await coordinator.cancel()
        let result = try await coordinator.finish()
        XCTAssertEqual(result.issues.totalCount, 0)
        XCTAssertTrue(result.hasIncompleteCoverage)
        XCTAssertEqual(result.completion, .cancelled)
    }

    func testMissingRootRetainsCollectedEvidenceAsUnavailable() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "selected")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data("evidence".utf8).write(to: child.appending(path: "observed.txt"))
        let backend = FoundationDirectoryBackend()
        let identity = try await backend.inspectRoot(child)
        let pair = AsyncStream<ScanUpdate>.makeStream()
        let coordinator = try ScanCoordinator(rootURL: child, root: identity, configuration: .init(workerLimit: 1), updates: pair.continuation)
        let claimed = await coordinator.claim()
        let lease = try XCTUnwrap(claimed)
        let read = await backend.readDirectory(.init(workID: lease.workID, directoryURL: lease.url, expectedIdentity: lease.identity))
        try await coordinator.submit(lease, result: read)
        try FileManager.default.moveItem(at: child, to: root.appending(path: "moved"))
        let matches = await backend.rootStillMatches(child, identity: identity.identity)
        XCTAssertFalse(matches)
        let result = try await coordinator.finish(sourceUnavailable: !matches)
        XCTAssertEqual(result.tree.count, 2)
        XCTAssertEqual(result.tree[result.tree.root].logicalSize, 8)
        XCTAssertTrue(result.sourceIsUnavailable)
        XCTAssertTrue(result.hasIncompleteCoverage)
        XCTAssertEqual(result.issues.counts[.sourceUnavailable], 1)
    }

    func testRescanRejectsReplacementAtSamePathButExplicitSelectionAcceptsIt() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appending(path: "selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let scanner = FoundationScanner()
        let before = try await scanner.startScan(.init(rootURL: selected)).result.value
        let identity = try XCTUnwrap(before.tree.identity(for: before.tree.root))
        try FileManager.default.moveItem(at: selected, to: root.appending(path: "old"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        do {
            _ = try await scanner.startScan(.init(rootURL: selected, expectedRootIdentity: identity)).result.value
            XCTFail("A replacement root must not be accepted as a rescan")
        } catch {
            XCTAssertEqual(error as? ScanError, .rootChanged)
        }
        let explicit = try await scanner.startScan(.init(rootURL: selected)).result.value
        XCTAssertFalse(explicit.hasIncompleteCoverage)
        XCTAssertNotEqual(explicit.tree.identity(for: explicit.tree.root), identity)
    }

    func testFinalValidationDoesNotFollowReplacementSymlink() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appending(path: "selected")
        let moved = root.appending(path: "moved")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let backend = FoundationDirectoryBackend()
        let original = try await backend.inspectRoot(selected)
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: moved)
        let matches = await backend.rootStillMatches(selected, identity: original.identity)
        XCTAssertFalse(matches)
    }

    private func makeCoordinator(sampleLimit: Int = 256) throws -> ScanCoordinator {
        let pair = AsyncStream<ScanUpdate>.makeStream()
        return try ScanCoordinator(rootURL: URL(fileURLWithPath: "/synthetic"), root: .init(displayName: "root", identity: .init(device: 1, inode: 1)), configuration: .init(workerLimit: 1, retainedIssueSamples: sampleLimit), updates: pair.continuation)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-volume-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
