import Darwin
import Foundation
import HygieiaDomain

/// Validates the original root and each snapshot component with `lstat`. This
/// intentionally does not resolve symlinks: a selected symlink is the item.
public struct NoFollowFileActionTargetValidator: FileActionTargetValidating {
    public init() {}

    public func validate(_ target: SnapshotFileActionTarget) async throws -> ValidatedFileActionTarget {
        try await Task.detached(priority: .userInitiated) {
            try validateBlocking(target)
        }.value
    }
}

private func validateBlocking(_ target: SnapshotFileActionTarget) throws -> ValidatedFileActionTarget {
    guard target.rootURL.isFileURL, target.node.isValid else { throw FileActionError.invalidTarget }
    let root = try readStatus(at: target.rootURL, missing: .rootMissing)
    guard kind(for: root) == .directory, identity(for: root) == target.rootIdentity else { throw FileActionError.rootChanged }

    var currentURL = target.rootURL
    if target.componentsFromRootChild.isEmpty {
        guard target.node.rawValue == 0, target.expectedKind == .directory else { throw FileActionError.invalidTarget }
        return .init(snapshot: target, itemURL: currentURL, validatedIdentity: identity(for: root), validatedKind: .directory, validatedAt: ContinuousClock().now)
    }

    guard let leaf = target.componentsFromRootChild.last,
          leaf.node == target.node,
          leaf.expectedKind == target.expectedKind else {
        throw FileActionError.invalidTarget
    }

    var previousNode = NodeID(rawValue: 0)
    for (index, component) in target.componentsFromRootChild.enumerated() {
        guard component.node.isValid, component.node > previousNode else { throw FileActionError.invalidTarget }
        previousNode = component.node
        guard isSingleFilesystemComponent(component.name) else { throw FileActionError.invalidPathComponent(node: component.node) }
        currentURL.append(path: component.name, directoryHint: component.expectedKind == .directory ? .isDirectory : .notDirectory)
        let isLeaf = index == target.componentsFromRootChild.count - 1
        let status = try readStatus(at: currentURL, missing: isLeaf ? .targetMissing : .ancestorMissing(node: component.node))

        if !isLeaf, kind(for: status) == .symbolicLink { throw FileActionError.symbolicLinkInAncestor(node: component.node) }
        guard kind(for: status) == component.expectedKind, identity(for: status) == component.expectedIdentity else {
            throw isLeaf ? FileActionError.targetChanged : FileActionError.ancestorChanged(node: component.node)
        }
    }

    return .init(snapshot: target, itemURL: currentURL, validatedIdentity: leaf.expectedIdentity, validatedKind: leaf.expectedKind, validatedAt: ContinuousClock().now)
}

private func isSingleFilesystemComponent(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
}

private func readStatus(at url: URL, missing: FileActionError) throws -> stat {
    var result = stat()
    let code: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return EINVAL }
        return lstat(path, &result) == 0 ? 0 : errno
    }
    guard code == 0 else {
        switch code {
        case ENOENT, ENOTDIR, ESTALE: throw missing
        case EACCES, EPERM: throw FileActionError.permissionDenied(code: code)
        case EROFS: throw FileActionError.readOnlyFileSystem(code: code)
        case ENODEV: throw FileActionError.volumeUnavailable(code: code)
        default: throw FileActionError.system(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
    return result
}

private func identity(for status: stat) -> FileIdentity {
    .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
}

private func kind(for status: stat) -> NodeKind {
    switch status.st_mode & S_IFMT {
    case S_IFREG: .regularFile
    case S_IFDIR: .directory
    case S_IFLNK: .symbolicLink
    default: .other
    }
}
