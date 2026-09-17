import AppKit
import SwiftUI

struct WholeMacScanView: View {
    @Bindable var model: WholeMacScanModel
    let explore: (ScanVolume) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settingsFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
            HStack {
                Text("Scan This Mac").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(WholeMacScanModel.coverageNotice)
                .foregroundStyle(HygieiaPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
                    HygieiaPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Access & coverage", systemImage: "lock.shield").font(.headline)
                            Text(WholeMacScanModel.accessNotice).textSelection(.enabled)
                            Button("Open Full Disk Access Settings") {
                                // Best-effort deep link. The manual route is always visible above.
                                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                                settingsFailed = !NSWorkspace.shared.open(url)
                            }
                            if settingsFailed {
                                Text("Settings could not be opened. Use the manual route above.")
                                    .foregroundStyle(HygieiaPalette.amber)
                            }
                        }.padding(HygieiaSpacing.medium)
                    }
                    Text("Select additional volumes explicitly. Mounted volumes and symlinks are never followed inside a root. System and Data are separate scopes; hidden service volumes and network storage are excluded.")
                        .font(.callout).foregroundStyle(HygieiaPalette.textSecondary)
                    if let warning = model.discoveryWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(HygieiaPalette.amber)
                    }
                    if model.reports.isEmpty && !model.isRefreshing {
                        Text("No local roots are listed. Refresh the list or return to Choose Folder.")
                    }
                    ForEach(model.reports) { report in
                        rootRow(report)
                        Divider()
                    }
                }
            }
            Text(model.status).font(.headline).accessibilityIdentifier("wholeMacStatus")
            if let progress = model.progress {
                Text("\(progress.committedNodeCount) items · \(progress.issueCount) issues · \(byteCount(progress.provisionalAllocatedBytes)) reported allocated so far")
                    .font(.callout).monospacedDigit()
            }
            HStack {
                Button(model.isRefreshing ? "Refreshing…" : "Refresh Disks & Reset Report") {
                    Task { await model.refresh() }
                }.disabled(model.isRunning || model.isRefreshing)
                Spacer()
                if model.isRunning {
                    Button("Stop Scan") { model.cancel() }.disabled(model.isCancelling)
                } else {
                    Button(model.hasRun ? "Rescan Selected Roots…" : "Scan Selected Roots…") { model.start() }
                        .buttonStyle(.borderedProminent).tint(HygieiaPalette.coral)
                        .disabled(!model.canStart)
                }
            }
        }
        .padding(HygieiaSpacing.large)
        .frame(width: 760, height: 650)
        .foregroundStyle(HygieiaPalette.textPrimary)
        .background(HygieiaPalette.canvas)
        .preferredColorScheme(.dark)
        .task { if model.reports.isEmpty { await model.refresh() } }
    }

    private func rootRow(_ report: MacRootReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: Binding(
                get: { model.selectedIDs.contains(report.id) },
                set: { if $0 { model.selectedIDs.insert(report.id) } else { model.selectedIDs.remove(report.id) } }
            )) {
                Text(report.volume.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            }.disabled(model.isRunning || model.isRefreshing)
            Text(report.volume.url.path).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.hasRun ? report.state.rawValue : model.selectedIDs.contains(report.id) ? "Selected · authorization required" : "Excluded unless selected")
                .font(.callout.weight(.semibold))
            if !report.detail.isEmpty { Text(report.detail).font(.callout) }
            if let logical = report.logicalBytes, let allocated = report.allocatedBytes {
                Text("Logical \(byteCount(logical)) · Allocated (reported) \(byteCount(allocated))")
                    .monospacedDigit().font(.callout)
            }
            if let identity = report.identity {
                Text("Device \(identity.device) · root inode \(identity.inode)").font(.caption)
            }
            if let start = report.startedAt, let end = report.finishedAt {
                Text("\(start.formatted(date: .abbreviated, time: .standard)) → \(end.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption)
            }
            if !report.issueCounts.isEmpty {
                Text(report.issueCounts.keys.sorted { $0.rawValue < $1.rawValue }
                    .map { "\($0.rawValue): \(report.issueCounts[$0] ?? 0)" }.joined(separator: " · "))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if !report.samples.isEmpty {
                DisclosureGroup("Issue samples (up to 20)") {
                    ForEach(Array(report.samples.enumerated()), id: \.offset) { _, sample in
                        Text(sample).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if report.finishedAt != nil {
                Button("Rescan in Explorer…") {
                    dismiss()
                    explore(report.volume)
                }.disabled(model.isRunning)
            }
        }
    }
}
