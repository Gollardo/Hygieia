import SwiftUI
import HygieiaDomain
import HygieiaFileOperations

struct LargestItemsTable: View {
    @Bindable var model: ScanFeatureModel

    var body: some View {
        VStack(spacing: 0) {
            HygieiaSectionTitle(
                title: "Contents",
                detail: model.visibleRoot.map { model.displayName(for: .node($0)) } ?? model.metric.title
            )
                .padding(.horizontal, HygieiaSpacing.large)
                .padding(.vertical, 14)

            Rectangle()
                .fill(HygieiaPalette.separator)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.rows) { row in
                        itemRow(row)
                    }
                }
                .padding(.horizontal, HygieiaSpacing.small)
                .padding(.vertical, HygieiaSpacing.small)
            }
            .scrollIndicators(.hidden)

            if let result = model.displayedResult {
                Rectangle()
                    .fill(HygieiaPalette.separator)
                    .frame(height: 1)
                HStack(spacing: HygieiaSpacing.small) {
                    Image(systemName: result.hasWarning ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(result.hasWarning ? HygieiaPalette.amber : HygieiaPalette.aqua)
                    Text(result.statusTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text(byteCount(rootValue))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(HygieiaPalette.textSecondary)
                .padding(.horizontal, HygieiaSpacing.large)
                .padding(.vertical, 11)
            }
        }
        .background(HygieiaPalette.canvasRaised.opacity(0.78))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Largest items")
    }

    private func itemRow(_ row: LargestItemRow) -> some View {
        let selected = model.selectedNodeID == row.id
        let marked = model.isMarkedForTrash(row.id)
        let tint = marked ? HygieiaPalette.amber : selected ? HygieiaPalette.coral : HygieiaPalette.glacier

        return Button {
            model.select(node: row.id)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: iconName(for: row))
                        .font(.body.weight(.medium))
                        .frame(width: 20)
                        .foregroundStyle(tint)

                    Text(row.name)
                        .font(.body.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? tint : HygieiaPalette.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(byteCount(row.size(for: model.metric)))
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(HygieiaPalette.textPrimary)

                    if row.kind == .directory {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(HygieiaPalette.textSecondary)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: 8) {
                    ProgressView(value: fraction(for: row))
                        .progressViewStyle(.linear)
                        .tint(tint)
                    Text(percentage(for: row))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(HygieiaPalette.textSecondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.leading, 29)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: HygieiaRadius.control, style: .continuous)
                    .fill(selected ? tint.opacity(0.12) : Color.clear)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: HygieiaRadius.control, style: .continuous)
                                .stroke(tint.opacity(0.45), lineWidth: 1)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard row.kind == .directory else { return }
                model.select(node: row.id)
                model.drill(to: row.id)
            }
        )
        .contextMenu {
            if row.kind == .directory {
                Button("Open in Field") {
                    model.select(node: row.id)
                    model.drill(to: row.id)
                }
                Divider()
            }
            Button(model.isMarkedForTrash(row.id) ? "Remove from Trash List" : "Mark for Trash") {
                model.select(node: row.id)
                model.toggleSelectedTrashMark()
            }
            .disabled(model.selectedNodeID != row.id || !model.canToggleSelectedTrashMark)
            Button("Show in Finder") {
                model.select(node: row.id)
                model.revealSelectedInFinder()
            }
            .disabled(model.selectedNodeID != row.id || !isAllowed(.revealInFinder))
            Button("Move to Trash", role: .destructive) {
                model.select(node: row.id)
                model.prepareMoveSelectedToTrash()
            }
            .disabled(model.selectedNodeID != row.id || !isAllowed(.moveToTrash) || model.markedTrashCount > 0)
        }
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Open in Field") {
            if row.kind == .directory {
                model.select(node: row.id)
                model.drill(to: row.id)
            }
        }
        .help(row.kind == .directory ? "Double-click to open this folder in the field" : row.relativePath)
    }

    private var rootValue: UInt64 {
        model.sunburstProjection?.nodes.first?.value ?? model.rows.first?.size(for: model.metric) ?? 0
    }

    private func fraction(for row: LargestItemRow) -> Double {
        guard rootValue > 0 else { return 0 }
        return min(1, Double(row.size(for: model.metric)) / Double(rootValue))
    }

    private func percentage(for row: LargestItemRow) -> String {
        fraction(for: row).formatted(.percent.precision(.fractionLength(1)))
    }

    private func iconName(for row: LargestItemRow) -> String {
        switch row.kind {
        case .directory: "folder.fill"
        case .regularFile: "doc.fill"
        case .symbolicLink: "link"
        case .other: "questionmark.folder.fill"
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

    private func accessibilityLabel(for row: LargestItemRow) -> String {
        var parts = [row.name, kindTitle(row.kind), byteCount(row.size(for: model.metric)), percentage(for: row)]
        if row.flags.contains(.incompleteSubtree) { parts.append("incomplete subtree") }
        if row.flags.contains(.hardLinkAlias) { parts.append("accounted at another link") }
        if model.isInvalidated(row.id) { parts.append("stale after file action") }
        if model.isMarkedForTrash(row.id) { parts.append("marked for Trash") }
        return parts.joined(separator: ", ")
    }

    private func isAllowed(_ action: FileActionKind) -> Bool {
        if case .allowed = model.fileActionEligibility(action) { return true }
        return false
    }
}

func byteCount(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
