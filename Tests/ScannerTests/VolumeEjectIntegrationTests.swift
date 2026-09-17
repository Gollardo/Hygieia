import Foundation
import XCTest
import HygieiaDomain
import HygieiaScannerCore
import HygieiaFoundationScanner

final class VolumeEjectIntegrationTests: XCTestCase, @unchecked Sendable {
    /// Opt-in: mounts only an image created inside this test's unique temporary root.
    func testOwnedAPFSDetachInvalidatesRootBeforePublicationAndRescan() async throws {
        guard ProcessInfo.processInfo.environment["HYGIEIA_APFS_INTEGRATION"] == "1" else {
            throw XCTSkip("Set HYGIEIA_APFS_INTEGRATION=1 to run the owned APFS eject fixture")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "hygieia-eject-\(UUID().uuidString)")
        let mount = root.appending(path: "mount")
        let image = root.appending(path: "fixture.dmg")
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        var mounted = false
        do {
            try await hdiutil(["create", "-size", "64m", "-fs", "APFS", "-volname", "HygieiaEjectFixture", image.path])
            mounted = true // Fail closed if attach partially succeeds.
            try await hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
            try Data("owned eject evidence".utf8).write(to: mount.appending(path: "fixture.txt"))
            let backend = FoundationDirectoryBackend()
            let inspected = try await backend.inspectRoot(mount)
            let stream = AsyncStream<ScanUpdate>.makeStream()
            let coordinator = try ScanCoordinator(rootURL: mount, root: inspected, configuration: .init(workerLimit: 1), updates: stream.continuation)
            let claimed = await coordinator.claim()
            let lease = try XCTUnwrap(claimed)
            let read = await backend.readDirectory(.init(workID: lease.workID, directoryURL: lease.url, expectedIdentity: lease.identity))
            try await coordinator.submit(lease, result: read)
            // Deterministic detach between real enumeration and final publication.
            try await hdiutil(["detach", "-force", mount.path])
            mounted = false
            let matches = await backend.rootStillMatches(mount, identity: inspected.identity)
            XCTAssertFalse(matches)
            let result = try await coordinator.finish(sourceUnavailable: !matches)
            XCTAssertTrue(result.sourceIsUnavailable)
            XCTAssertTrue(result.hasIncompleteCoverage)
            XCTAssertGreaterThan(result.tree[result.tree.root].logicalSize, 0)
            do {
                _ = try await FoundationScanner().startScan(.init(rootURL: mount, expectedRootIdentity: inspected.identity)).result.value
                XCTFail("Ejected volume must not become a scan of the host mount directory")
            } catch ScanError.rootChanged { }
              catch ScanError.rootMissing { }
            try manager.removeItem(at: root) // Only this unmounted, owned fixture.
        } catch {
            if mounted {
                do { try await hdiutil(["detach", "-force", mount.path]); mounted = false }
                catch { print("Owned fixture left in place; detach failed: \(root.path)") }
            }
            if !mounted { try? manager.removeItem(at: root) }
            throw error
        }
    }

    private func hdiutil(_ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "OwnedAPFSFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed"])
            }
        }.value
    }
}
