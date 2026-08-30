import SwiftUI
import HygieiaDomain

struct FileDetailsView: View {
    let model: ScanFeatureModel

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
                    HygieiaSectionTitle(title: "Selected Item", detail: item.kind.map(kindTitle))

                    HStack(alignment: .center, spacing: HygieiaSpacing.medium) {
                        Image(systemName: iconName(for: item.kind))
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(HygieiaPalette.coral)
                            .frame(width: 48, height: 48)
                            .background(HygieiaPalette.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(HygieiaPalette.textPrimary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Text(item.relativePath.isEmpty ? "Scan root" : item.relativePath)
                                .font(.caption)
                                .foregroundStyle(HygieiaPalette.textSecondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }

                    HStack(spacing: 0) {
                        if let logical = item.logicalSize {
                            sizeValue("Logical", value: logical)
                        }
                        if item.logicalSize != nil, item.allocatedSize != nil {
                            Rectangle()
                                .fill(HygieiaPalette.separator)
                                .frame(width: 1, height: 36)
                                .padding(.horizontal, HygieiaSpacing.large)
                        }
                        if let allocated = item.allocatedSize {
                            sizeValue("Allocated (reported)", value: allocated)
                        }
                        if let value = item.aggregatedValue, item.logicalSize == nil, item.allocatedSize == nil {
                            sizeValue("Current metric", value: value)
                        }
                    }

                    warningSummary(for: item)

                    if item.kind == .directory, item.nodeID != model.visibleRoot {
                        Button("Open in Field", systemImage: "arrow.up.right.circle") {
                            if let node = item.nodeID { model.drill(to: node) }
                        }
                        .buttonStyle(.bordered)
                        .tint(HygieiaPalette.glacier)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Selected item details")
            } else {
                VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
                    HygieiaSectionTitle(title: "Selected Item")
                    Label("Select an item in the field or list to inspect it.", systemImage: "cursorarrow.click")
                        .font(.callout)
                        .foregroundStyle(HygieiaPalette.textSecondary)
                }
            }
        }
    }

    private func sizeValue(_ title: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(HygieiaPalette.textSecondary)
            Text(byteCount(value))
                .font(.body.weight(.medium))
                .foregroundStyle(HygieiaPalette.textPrimary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func warningSummary(for item: ExplorerDetails) -> some View {
        let warnings = warningTitles(for: item)
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(HygieiaPalette.amber)
                }
            }
        }
        if let node = item.nodeID, model.isInvalidated(node) {
            Label("Stale until the full rescan completes.", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(HygieiaPalette.amber)
        }
    }

    private func warningTitles(for item: ExplorerDetails) -> [String] {
        var warnings: [String] = []
        if item.flags.contains(.incompleteSubtree) { warnings.append("This subtree is incomplete") }
        if item.flags.contains(.inaccessible) { warnings.append("Some contents could not be read") }
        if item.flags.contains(.package) { warnings.append("Package folder") }
        if item.flags.contains(.volumeBoundary) { warnings.append("Another volume was not scanned") }
        if item.flags.contains(.hardLinkAlias) { warnings.append("Accounted at another hard link") }
        return warnings
    }

    private func iconName(for kind: NodeKind?) -> String {
        switch kind {
        case .directory: "folder.fill"
        case .regularFile: "doc.fill"
        case .symbolicLink: "link"
        case .other: "questionmark.folder.fill"
        case nil: "circle.grid.cross"
        }
    }

    private func kindTitle(_ kind: NodeKind) -> String {
        switch kind {
        case .directory: "Folder"
        case .regularFile: "File"
        case .symbolicLink: "Symbolic Link"
        case .other: "Other"
        }
    }
}
