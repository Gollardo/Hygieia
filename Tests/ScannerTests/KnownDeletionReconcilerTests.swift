import Foundation
import XCTest
import HygieiaDomain
import HygieiaFoundationScanner

final class KnownDeletionReconcilerTests: XCTestCase {
    private struct DigestEntry: Equatable {
        let path: String
        let kind: NodeKind
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let flags: NodeFlags
    }

    func testRebuildRemovesDirectorySubtreeAndMapsOnlySurvivors() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "folder", directoryHint: .isDirectory), withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: root.appending(path: "folder/inside.txt"))
        try Data("keep".utf8).write(to: root.appending(path: "keep.txt"))
        let tree = try await scan(root)
        let folder = try XCTUnwrap(tree.children(of: tree.root).first { tree.name(for: $0) == "folder" })
        let inside = try XCTUnwrap(Array(tree.children(of: folder)).first)
        let keep = try XCTUnwrap(tree.children(of: tree.root).first { tree.name(for: $0) == "keep.txt" })

        let rebuilt = try KnownDeletionReconciler.reconcile(tree: tree, removing: [folder])

        XCTAssertEqual(rebuilt.tree.count, 2)
        XCTAssertNil(rebuilt.survivingNodeIDMap[folder])
        XCTAssertNil(rebuilt.survivingNodeIDMap[inside])
        XCTAssertEqual(rebuilt.survivingNodeIDMap[keep], NodeID(rawValue: 1))
        XCTAssertEqual(rebuilt.tree.name(for: NodeID(rawValue: 1)), "keep.txt")
        XCTAssertEqual(rebuilt.tree[rebuilt.tree.root].logicalSize, 4)
    }

    func testRejectsRootAndOverlappingRoots() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "parent/child", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let tree = try await scan(root)
        let parent = try XCTUnwrap(Array(tree.children(of: tree.root)).first)
        let child = try XCTUnwrap(Array(tree.children(of: parent)).first)

        XCTAssertThrowsError(try KnownDeletionReconciler.reconcile(tree: tree, removing: [tree.root])) { error in
            XCTAssertEqual(error as? KnownDeletionReconciliationError, .rootRemoval)
        }
        XCTAssertThrowsError(try KnownDeletionReconciler.reconcile(tree: tree, removing: [parent, child])) { error in
            XCTAssertEqual(error as? KnownDeletionReconciliationError, .overlappingMovedRoots)
        }
    }

    func testRemovingCanonicalHardLinkPromotesSurvivorWithoutLosingAccounting() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalURL = root.appending(path: "a.txt")
        let aliasURL = root.appending(path: "b.txt")
        try Data("payload".utf8).write(to: canonicalURL)
        try FileManager.default.linkItem(at: canonicalURL, to: aliasURL)
        let tree = try await scan(root)
        let canonical = try XCTUnwrap(tree.children(of: tree.root).first { tree.name(for: $0) == "a.txt" })
        let alias = try XCTUnwrap(tree.children(of: tree.root).first { tree.name(for: $0) == "b.txt" })
        XCTAssertTrue(tree[alias].flags.contains(.hardLinkAlias))

        let rebuilt = try KnownDeletionReconciler.reconcile(tree: tree, removing: [canonical])
        let survivor = try XCTUnwrap(rebuilt.survivingNodeIDMap[alias])

        XCTAssertFalse(rebuilt.tree[survivor].flags.contains(.hardLinkAlias))
        XCTAssertEqual(rebuilt.tree.intrinsicSizes(for: survivor).logical, 7)
        XCTAssertEqual(rebuilt.tree[rebuilt.tree.root].logicalSize, 7)
        XCTAssertEqual(rebuilt.tree.hardLinkGroupCount, 1)
    }

    func testDigestMatchesFullRescanAfterSameKnownRemoval() async throws {
        let root = try makeFixture()
        let staging = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: staging)
        }
        let removedURL = root.appending(path: "удаляемая папка", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: removedURL, withIntermediateDirectories: false)
        try Data("gone".utf8).write(to: removedURL.appending(path: "файл.txt"))
        try Data("keep".utf8).write(to: root.appending(path: "keep.txt"))
        let before = try await scan(root)
        let removed = try XCTUnwrap(Array(before.children(of: before.root)).first { before.name(for: $0) == "удаляемая папка" })

        let reconciled = try KnownDeletionReconciler.reconcile(tree: before, removing: [removed]).tree
        try FileManager.default.moveItem(at: removedURL, to: staging.appending(path: "moved", directoryHint: .isDirectory))
        let rescanned = try await scan(root)

        XCTAssertEqual(digest(reconciled), digest(rescanned))
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-reconciliation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func scan(_ root: URL) async throws -> FileTree {
        try await FoundationScanner(configuration: .init(workerLimit: 1, progressMinimumInterval: .zero))
            .startScan(.init(rootURL: root))
            .result
            .value
            .tree
    }

    private func digest(_ tree: FileTree) -> [DigestEntry] {
        (0..<tree.count).map { raw in
            let id = NodeID(rawValue: UInt32(raw))
            let node = tree[id]
            return .init(path: tree.pathComponents(to: id).dropFirst().joined(separator: "/"), kind: node.kind, logicalSize: node.logicalSize, allocatedSize: node.allocatedSize, flags: node.flags)
        }.sorted { $0.path < $1.path }
    }
}
