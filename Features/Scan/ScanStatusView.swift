import SwiftUI
import HygieiaScannerCore

struct ScanStatusView: View {
    let model: ScanFeatureModel
    @State private var showsCoverage = false

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
        return model.displayedResult != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            resultStatus

            if let result = model.displayedResult {
                Button("Scope & Coverage", systemImage: "info.circle") { showsCoverage = true }
                    .accessibilityIdentifier("scanCoverage")
                    .popover(isPresented: $showsCoverage) {
                        ScanCoverageView(displayed: result)
                    }
            }

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
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var resultStatus: some View {
        if let result = model.displayedResult {
            switch result.freshness {
            case .sourceUnavailable:
                Label("Source unavailable or changed — collected sizes may be stale", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(HygieiaPalette.amber)
                Text("Reconnect the disk and choose the source again. Trash is unavailable for this snapshot.")
                    .font(.caption)
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
            case .current where result.result.hasIncompleteCoverage:
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

struct ScanCoverageView: View {
    let displayed: DisplayedScanResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
                Text("Scope & Coverage").font(.title2)
                Label(displayed.statusTitle, systemImage: displayed.hasWarning ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(displayed.hasWarning ? HygieiaPalette.amber : HygieiaPalette.aqua)
                if displayed.freshness == .sourceUnavailable {
                    Text("Collected sizes may be stale. Reconnect the disk and choose the source again before taking action.")
                        .foregroundStyle(HygieiaPalette.textSecondary)
                }
                Text("Selected root").font(.headline)
                Text(displayed.result.rootURL.path).textSelection(.enabled)
                if let identity = displayed.result.tree.identity(for: displayed.result.tree.root) {
                    Text("Source device: \(identity.device)").font(.caption)
                }
                Text("Started: \(displayed.result.startedAt.formatted())\nFinished: \(displayed.result.finishedAt.formatted())")
                    .font(.caption)
                Text("Only the selected root was scanned. Symbolic links were not followed; other mounted volumes were not traversed.")
                Text("A finished scan is not proof of access to all data on this Mac. Missing areas have unknown sizes. Reported allocated bytes are not reclaimable space.")
                    .foregroundStyle(HygieiaPalette.textSecondary)

                if displayed.result.issues.totalCount == 0 {
                    Text(displayed.result.hasIncompleteCoverage ? "The scan did not establish complete coverage." : "No coverage issues were recorded within this scope.")
                } else {
                    Text("Recorded issues").font(.headline)
                    ForEach(ScanIssueKind.allCases, id: \.self) { kind in
                        if let count = displayed.result.issues.counts[kind], count > 0 {
                            Text("\(kind.coverageTitle): \(count)")
                        }
                    }
                    if (displayed.result.issues.counts[.permissionDenied] ?? 0) > 0 {
                        Text("Access was denied. Permissions, macOS privacy controls or sandbox access may be involved; Full Disk Access status is unknown.")
                            .foregroundStyle(HygieiaPalette.textSecondary)
                    }
                    if !displayed.result.issues.samples.isEmpty {
                        Text("Examples (relative to selected root)").font(.headline)
                        ForEach(Array(displayed.result.issues.samples.prefix(20).enumerated()), id: \.offset) { _, sample in
                            Text("\(sample.kind.coverageTitle): \(sample.relativePath.isEmpty ? ". (selected root)" : sample.relativePath)")
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                        Text("Showing up to 20 retained examples; this is not a complete list of skipped paths.")
                            .font(.caption)
                            .foregroundStyle(HygieiaPalette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HygieiaSpacing.large)
        }
        .frame(width: 520, height: 480)
        .background(HygieiaPalette.panel)
    }
}

extension ScanIssueKind {
    var coverageTitle: String {
        switch self {
        case .permissionDenied: "Access denied"
        case .itemDisappeared: "Items disappeared or changed"
        case .metadataReadFailed: "Metadata unavailable"
        case .volumeBoundary: "Other mounted volumes skipped"
        case .repeatedDirectoryIdentity: "Repeated directories skipped"
        case .hardLinksOutsideRoot: "Hard links outside selected scope"
        case .sourceUnavailable: "Source unavailable or changed"
        }
    }
}
