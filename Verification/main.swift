import Darwin
import Foundation
import HygieiaDomain
import HygieiaScannerCore
import HygieiaFoundationScanner

@main
struct HygieiaVerification {
    static func main() async {
        do {
            try compactStorageLayout()
            try scanConfigurationIsBounded()
            try await scannerAccountsHardLinksOnceAndDoesNotFollowSymlink()
            try await hardLinkOutsideRootIsReported()
            try await symlinkRootIsRejected()
            try await directoryIdentityIsPinnedBeforeRead()
            try await disappearedEntryMarksCoverageIncomplete()
            try await cancellationProducesValidatedPartialTree()
            try await foundationSessionCancellationReturnsPartialTree()
            print("M1 verification: 9 checks passed")
        } catch {
            fputs("M1 verification failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func compactStorageLayout() throws {
        try require(MemoryLayout<NodeID>.stride == 4, "NodeID stride")
        try require(MemoryLayout<NameID>.stride == 4, "NameID stride")
        try require(MemoryLayout<NameEntry>.stride == 8, "NameEntry stride")
        #if arch(arm64)
        try require(MemoryLayout<FileNode>.stride == 40, "FileNode stride")
        #endif
    }

    private static func scanConfigurationIsBounded() throws {
        try require(ScanConfiguration(workerLimit: Int.max).workerLimit == ScanConfiguration.maximumWorkerLimit, "worker limit cap")
    }

    private static func scannerAccountsHardLinksOnceAndDoesNotFollowSymlink() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await FoundationScanner(configuration: .init(workerLimit: 2, progressMinimumInterval: .zero)).startScan(.init(rootURL: root)).result.value
        try require(result.completion == .complete, "scan completion")
        try require(result.tree.hardLinkGroupCount == 1, "hard-link group count")
        let a = try node(named: "a.txt", in: result.tree)
        let b = try node(named: "b.txt", in: result.tree)
        let alias = result.tree[a].flags.contains(.hardLinkAlias) ? a : b
        try require(result.tree[alias].logicalSize == 0, "hard-link alias accounting")
        try require(result.tree.intrinsicSizes(for: alias).logical == 5, "hard-link intrinsic size")
        try require(result.tree[result.tree.root].logicalSize == 8 + UInt64("/outside-target".utf8.count), "root logical accounting")
        let linkNode = try node(named: "outside-link", in: result.tree)
        try require(result.tree[linkNode].kind == .symbolicLink, "symlink record")
        try require(Array(result.tree.children(of: linkNode)).isEmpty, "symlink traversal")
        let emoji = try node(named: "émoji.txt", in: result.tree)
        try require(result.tree.pathComponents(to: emoji).last == "émoji.txt", "unicode name round trip")
    }

    private static func symlinkRootIsRejected() async throws {
        let root = try temporaryRoot()
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let linkNode = root.appending(path: "root-link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try require(symlink(target.path, linkNode.path) == 0, "create root symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await FoundationScanner().startScan(.init(rootURL: linkNode)).result.value
            throw VerificationFailure("symlink root was accepted")
        } catch let error as ScanError {
            try require(error == .rootIsSymbolicLink, "symlink-root error")
        }
    }

    private static func hardLinkOutsideRootIsReported() async throws {
        let parent = try temporaryRoot()
        let root = parent.appending(path: "root", directoryHint: .isDirectory)
        let outside = parent.appending(path: "outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("12345".utf8).write(to: outside)
        try require(link(outside.path, root.appending(path: "inside.txt").path) == 0, "create outside-root hard link")
        defer { try? FileManager.default.removeItem(at: parent) }
        let result = try await FoundationScanner().startScan(.init(rootURL: root)).result.value
        try require(result.issues.counts[.hardLinksOutsideRoot] == 1, "outside-root hard-link issue")
        try require(result.tree[result.tree.root].logicalSize == 5, "outside-root hard-link accounting")
    }

    private static func directoryIdentityIsPinnedBeforeRead() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await FoundationDirectoryBackend().readDirectory(.init(workID: 1, directoryURL: root, expectedIdentity: .init(device: 0, inode: 0)))
        guard case .disappeared = result.failure else { throw VerificationFailure("directory identity mismatch was read") }
    }

    private static func disappearedEntryMarksCoverageIncomplete() async throws {
        let pair = AsyncStream<ScanUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let coordinator = try ScanCoordinator(rootURL: URL(fileURLWithPath: "/tmp/hygieia-test", isDirectory: true), root: RootDirectoryRecord(displayName: "hygieia-test", identity: .init(device: 1, inode: 1)), configuration: .init(workerLimit: 1), updates: pair.continuation)
        guard let lease = await coordinator.claim() else { throw VerificationFailure("missing initial lease") }
        try await coordinator.submit(lease, result: .init(workID: lease.workID, entryIssues: [.init(name: "gone", failure: .disappeared(code: ENOENT))]))
        let result = try await coordinator.finish()
        try require(result.tree[result.tree.root].flags.contains(.incompleteSubtree), "disappeared entry incomplete marker")
        try require(result.issues.counts[.itemDisappeared] == 1, "disappeared entry issue")
    }

    private static func cancellationProducesValidatedPartialTree() async throws {
        let pair = AsyncStream<ScanUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let coordinator = try ScanCoordinator(rootURL: URL(fileURLWithPath: "/tmp/hygieia-test", isDirectory: true), root: RootDirectoryRecord(displayName: "hygieia-test", identity: .init(device: 1, inode: 1)), configuration: .init(workerLimit: 1), updates: pair.continuation)
        guard let lease = await coordinator.claim() else { throw VerificationFailure("missing initial lease") }
        await coordinator.cancel()
        try await coordinator.submit(lease, result: .init(workID: lease.workID))
        let result = try await coordinator.finish()
        try require(result.completion == .cancelled, "cancel completion")
        try require(result.tree[result.tree.root].flags.contains(.incompleteSubtree), "cancel incomplete marker")
        try require(result.tree.count == 1, "cancelled root-only tree")
    }

    private static func foundationSessionCancellationReturnsPartialTree() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appending(path: "child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        for index in 0..<256 {
            try Data("x".utf8).write(to: child.appending(path: "item-\(index)"))
        }

        for _ in 0..<16 {
            let session = FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
                .startScan(.init(rootURL: root))
            session.cancel()
            let result = try await session.result.value

            try require(result.completion == .cancelled, "foundation session cancel completion")
            try require(result.tree[result.tree.root].flags.contains(.incompleteSubtree), "foundation session cancel incomplete marker")
        }
    }
}

private struct VerificationFailure: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw VerificationFailure(message) } }

private func makeFixture() throws -> URL {
    let root = try temporaryRoot()
    try Data("12345".utf8).write(to: root.appending(path: "a.txt"))
    try require(link(root.appending(path: "a.txt").path, root.appending(path: "b.txt").path) == 0, "create hard link")
    let nested = root.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    try Data("123".utf8).write(to: nested.appending(path: "émoji.txt"))
    try require(symlink("/outside-target", root.appending(path: "outside-link").path) == 0, "create symlink")
    return root
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func node(named name: String, in tree: FileTree) throws -> NodeID {
    for raw in 0..<tree.count {
        let id = NodeID(rawValue: UInt32(raw))
        if tree.name(for: id) == name { return id }
    }
    throw VerificationFailure("missing node \(name)")
}
