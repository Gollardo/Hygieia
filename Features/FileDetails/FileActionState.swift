import Foundation
import HygieiaDomain
import HygieiaFileOperations

struct TrashConfirmation: Sendable {
    let target: SnapshotFileActionTarget
    let displayName: String
    let relativePath: String
    let fullPath: String
    let generation: UInt64

    var summary: String {
        "\(kindTitle) • Logical: \(byteCount(target.logicalSize)) • Allocated (reported): \(byteCount(target.reportedAllocatedSize))"
    }

    var warning: String {
        var warnings: [String] = []
        if target.expectedKind == .symbolicLink {
            warnings.append("Only the symbolic link will be moved; its target is not affected.")
        }
        if target.snapshotFlags.contains(.package) {
            warnings.append("This package folder will be moved as one item.")
        }
        if target.snapshotFlags.contains(.hardLink) || target.snapshotFlags.contains(.hardLinkAlias) {
            warnings.append("Only this directory entry will be moved; displayed size is not a reclaimable-space estimate.")
        }
        return warnings.joined(separator: " ")
    }

    private var kindTitle: String {
        switch target.expectedKind {
        case .regularFile: "File"
        case .directory: target.snapshotFlags.contains(.package) ? "Package folder" : "Folder"
        case .symbolicLink: "Symbolic link"
        case .other: "Other filesystem item"
        }
    }
}

struct MarkedTrashConfirmation: Sendable {
    let items: [TrashConfirmation]
    let generation: UInt64

    var count: Int { items.count }

    var logicalSize: UInt64 {
        combinedSize(\.target.logicalSize)
    }

    var reportedAllocatedSize: UInt64 {
        combinedSize(\.target.reportedAllocatedSize)
    }

    var summary: String {
        "\(count) item\(count == 1 ? "" : "s") • Logical: \(byteCount(logicalSize)) • Allocated (reported): \(byteCount(reportedAllocatedSize))"
    }

    var pathSummary: String {
        let limit = 8
        let paths = items.prefix(limit).map(\.relativePath)
        let remaining = count - paths.count
        return (paths + (remaining > 0 ? ["and \(remaining) more marked item\(remaining == 1 ? "" : "s")"] : [])).joined(separator: "\n")
    }

    private func combinedSize(_ value: KeyPath<TrashConfirmation, UInt64>) -> UInt64 {
        items.reduce(0) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item[keyPath: value])
            return overflow ? .max : sum
        }
    }
}

enum FileActionPhase: Sendable {
    case idle
    case preparing(kind: FileActionKind, node: NodeID, generation: UInt64)
    case awaitingTrashConfirmation(TrashConfirmation)
    case awaitingMarkedTrashConfirmation(MarkedTrashConfirmation)
    case movingToTrash(node: NodeID, generation: UInt64)
    case movingMarkedItems(current: NodeID, completedCount: Int, totalCount: Int, generation: UInt64)
    case refreshingAfterTrash(InvalidatedSubtree)
    case failed(FileActionPresentation)
}

extension FileActionPhase {
    var isInProgress: Bool {
        switch self {
        case .idle, .failed: false
        case .preparing, .awaitingTrashConfirmation, .awaitingMarkedTrashConfirmation, .movingToTrash, .movingMarkedItems, .refreshingAfterTrash: true
        }
    }
}

struct InvalidatedSubtree: Sendable {
    let root: NodeID
    let generation: UInt64
}

struct FileActionPresentation: Equatable, Sendable {
    let title: String
    let message: String

    static func make(from error: Error) -> Self {
        switch error {
        case FileActionError.rootMissing,
             FileActionError.rootChanged,
             FileActionError.ancestorMissing,
             FileActionError.ancestorChanged,
             FileActionError.symbolicLinkInAncestor,
             FileActionError.targetMissing,
             FileActionError.targetChanged:
            .init(title: "Item changed or moved", message: "The item no longer matches this scan. Rescan before moving it to Trash.")
        case FileActionError.permissionDenied:
            .init(title: "Permission denied", message: "Hygieia can only act within the folder you selected. Choose a folder with read-write access.")
        case FileActionError.readOnlyFileSystem, FileActionError.trashUnavailable:
            .init(title: "Trash unavailable", message: "The item was not moved. Use Finder or choose a writable local folder.")
        case FileActionError.volumeUnavailable:
            .init(title: "Volume unavailable", message: "Reconnect the volume and rescan before trying again.")
        default:
            .init(title: "File action failed", message: "The item may be unchanged. Rescan before trying again.")
        }
    }
}

struct LastFileActionStatus: Sendable {
    let kind: FileActionKind
    let displayName: String
    let completedAt: Date
}
