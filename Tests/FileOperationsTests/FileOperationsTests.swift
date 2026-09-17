import Darwin
import Foundation
import XCTest
import HygieiaDomain
import HygieiaFileOperations

final class FileOperationsTests: XCTestCase {
    func testIdentityStoreDistinguishesKnownInodeZeroAndDeviceOverride() {
        let store = NodeIdentityStore(identities: ContiguousArray([
            .init(device: 7, inode: 0),
            nil,
            .init(device: 9, inode: 42),
        ]))

        XCTAssertEqual(store.identity(for: .init(rawValue: 0)), .init(device: 7, inode: 0))
        XCTAssertNil(store.identity(for: .init(rawValue: 1)))
        XCTAssertEqual(store.identity(for: .init(rawValue: 2)), .init(device: 9, inode: 42))
        XCTAssertEqual(MemoryLayout<FileNode>.stride, 40)
    }

    func testTrashPolicyProtectsVisibleRootAndIncompleteSubtree() {
        let base = FileActionEligibilityContext(
            action: .moveToTrash,
            selectedNode: .init(rawValue: 1),
            scanRoot: .init(rawValue: 0),
            visibleRoot: .init(rawValue: 0),
            freshness: .current,
            scanOrRefreshActive: false,
            identityAvailable: true,
            nodeKind: .regularFile,
            nodeFlags: [],
            actionInProgress: false,
            invalidatedByEarlierAction: false
        )
        XCTAssertEqual(FileActionEligibilityPolicy.evaluate(base), .allowed)

        let protected = FileActionEligibilityContext(
            action: .moveToTrash, selectedNode: .init(rawValue: 1), scanRoot: .init(rawValue: 0), visibleRoot: .init(rawValue: 1), freshness: .current, scanOrRefreshActive: false, identityAvailable: true, nodeKind: .regularFile, nodeFlags: [], actionInProgress: false, invalidatedByEarlierAction: false
        )
        XCTAssertEqual(FileActionEligibilityPolicy.evaluate(protected), .denied(.visibleRootProtected))

        let incomplete = FileActionEligibilityContext(
            action: .moveToTrash, selectedNode: .init(rawValue: 1), scanRoot: .init(rawValue: 0), visibleRoot: .init(rawValue: 0), freshness: .current, scanOrRefreshActive: false, identityAvailable: true, nodeKind: .directory, nodeFlags: [.incompleteSubtree], actionInProgress: false, invalidatedByEarlierAction: false
        )
        XCTAssertEqual(FileActionEligibilityPolicy.evaluate(incomplete), .denied(.incompleteSubtree))
    }

    func testFinderMayRevealUnaffectedCurrentNodeDuringActionRefresh() {
        let context = FileActionEligibilityContext(
            action: .revealInFinder,
            selectedNode: .init(rawValue: 2),
            scanRoot: .init(rawValue: 0),
            visibleRoot: .init(rawValue: 0),
            freshness: .staleAfterFileAction,
            scanOrRefreshActive: true,
            identityAvailable: true,
            nodeKind: .regularFile,
            nodeFlags: [],
            actionInProgress: false,
            invalidatedByEarlierAction: false
        )

        XCTAssertEqual(FileActionEligibilityPolicy.evaluate(context), .allowed)
        let blocked = FileActionEligibilityContext(
            action: .revealInFinder,
            selectedNode: .init(rawValue: 2),
            scanRoot: .init(rawValue: 0),
            visibleRoot: .init(rawValue: 0),
            freshness: .staleAfterFileAction,
            scanOrRefreshActive: true,
            identityAvailable: true,
            nodeKind: .regularFile,
            nodeFlags: [],
            actionInProgress: true,
            invalidatedByEarlierAction: false
        )
        XCTAssertEqual(FileActionEligibilityPolicy.evaluate(blocked), .denied(.actionAlreadyInProgress))
    }

    func testValidatorRejectsAncestorReplacedWithSymbolicLink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hygieia-file-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        let item = folder.appending(path: "item.txt", directoryHint: .notDirectory)
        let outside = FileManager.default.temporaryDirectory.appending(path: "hygieia-file-actions-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: item)
        try Data("outside".utf8).write(to: outside.appending(path: "item.txt", directoryHint: .notDirectory))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let target = try makeTarget(root: root, folder: folder, item: item)
        _ = try await NoFollowFileActionTargetValidator().validate(target)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)

        do {
            _ = try await NoFollowFileActionTargetValidator().validate(target)
            XCTFail("Validation must not follow a replacement symlink")
        } catch let error as FileActionError {
            XCTAssertEqual(error, .symbolicLinkInAncestor(node: .init(rawValue: 1)))
        }
    }

    private func makeTarget(root: URL, folder: URL, item: URL) throws -> SnapshotFileActionTarget {
        var names = NameStore()
        let rootName = try names.append(root.lastPathComponent)
        let folderName = try names.append("folder")
        let itemName = try names.append("item.txt")
        let nodes: ContiguousArray<FileNode> = [
            .init(logicalSize: 6, allocatedSize: 0, parent: .invalid, firstChild: .init(rawValue: 1), name: rootName, kind: .directory),
            .init(logicalSize: 6, allocatedSize: 0, parent: .init(rawValue: 0), firstChild: .init(rawValue: 2), name: folderName, kind: .directory),
            .init(logicalSize: 6, allocatedSize: 0, parent: .init(rawValue: 1), name: itemName, kind: .regularFile),
        ]
        let identities: ContiguousArray<FileIdentity?> = [try identity(at: root), try identity(at: folder), try identity(at: item)]
        let tree = FileTree(root: .init(rawValue: 0), nodes: nodes, names: names, identities: .init(identities: identities))
        return try SnapshotFileActionTargetBuilder.make(node: .init(rawValue: 2), tree: tree, rootURL: root)
    }

    private func identity(at url: URL) throws -> FileIdentity {
        var metadata = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &metadata))
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EINVAL) }
        return .init(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: UInt64(metadata.st_ino))
    }
}
