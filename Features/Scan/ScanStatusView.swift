import SwiftUI

struct ScanStatusView: View {
    let model: ScanFeatureModel

    static func shouldDisplay(for model: ScanFeatureModel) -> Bool {
        if model.phase == .preparing || model.phase == .scanning || model.phase == .cancelling {
            // The first scan owns a full-screen live progress scene. Keep this footer
            // only when an existing result remains visible during a rescan.
            return model.displayedResult != nil
        }
        if model.presentedError != nil || model.fileActionNotice != nil {
            return true
        }
        if case .idle = model.fileActionPhase {
            // Continue below.
        } else {
            return true
        }
        guard let result = model.displayedResult else { return false }
        if result.freshness != .current { return true }
        return result.result.issues.totalCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            resultStatus

            if case .preparing(let kind, _, _) = model.fileActionPhase {
                Label(kind == .moveToTrash ? "Checking item before Trash" : "Checking item", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else if case .movingMarkedItems(_, let completedCount, let totalCount, _) = model.fileActionPhase {
                Label("Moving marked item \(completedCount + 1) of \(totalCount) to Trash", systemImage: "trash")
                    .foregroundStyle(.secondary)
            } else if model.phase == .scanning || model.phase == .cancelling {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(model.phase == .cancelling ? "Cancelling scan" : "Scanning folder")
                if let root = model.selectedRoot {
                    Text("Scanning: \(root.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(progressDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.presentedError {
                Label(error.title, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed(let error) = model.fileActionPhase {
                Label(error.title, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let notice = model.fileActionNotice {
                Label(notice.title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var resultStatus: some View {
        if let result = model.displayedResult {
            switch result.freshness {
            case .partial:
                Label("Partial result — scan was cancelled", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .staleWhileScanning:
                Label("Showing previous result while rescanning", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            case .previousAfterFailedRescan:
                Label("Showing previous result after failed rescan", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .staleAfterFileAction:
                Label(
                    !model.hasInvalidatedFileActions
                        ? "Item changed — displayed sizes are stale until rescan completes"
                        : "Moved to Trash — refreshing scan",
                    systemImage: "arrow.clockwise"
                )
                    .foregroundStyle(.orange)
                Button("Rescan", action: model.rescan)
                    .disabled(!model.canRescan)
            case .current where result.result.issues.totalCount > 0:
                Label("Result is incomplete: \(result.result.issues.totalCount) coverage issue(s)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .current:
                EmptyView()
            }
        }
    }

    private var progressDescription: String {
        guard let progress = model.progress else { return "Preparing scan…" }
        return "\(progress.committedNodeCount) items committed, \(progress.completedDirectoryCount) folders completed, reported \(byteCount(progress.provisionalAllocatedBytes)), \(elapsedDescription(progress.elapsed)), \(model.remainingTimeDescription.lowercased())"
    }

    private func elapsedDescription(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes)m \(seconds % 60)s elapsed" : "\(seconds)s elapsed"
    }
}
