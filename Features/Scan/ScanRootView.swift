import AppKit
import SwiftUI
import HygieiaDomain
import HygieiaFileOperations
import HygieiaVisualization

private enum BrandedScene {
    case empty
    case scanning
    case error

    var eyebrow: String {
        switch self {
        case .empty: "Lustral Field"
        case .scanning: "Mapping in progress"
        case .error: "Field interrupted"
        }
    }
}

struct ScanRootView: View {
    @Bindable var model: ScanFeatureModel

    var body: some View {
        ZStack {
            HygieiaPalette.canvas
                .ignoresSafeArea()

            Group {
                if model.displayedResult != nil {
                    explorer
                } else if model.phase == .scanning || model.phase == .cancelling || model.phase == .preparing {
                    brandedState(
                        scene: .scanning,
                        title: "Reading the selected space",
                        description: "Structure is emerging from the filesystem. Nothing on disk is changed while Hygieia maps it."
                    )
                } else if let error = model.presentedError {
                    brandedState(
                        scene: .error,
                        title: error.title,
                        description: error.message,
                        actionTitle: "Choose Folder…",
                        action: model.chooseFolder
                    )
                } else {
                    brandedState(
                        scene: .empty,
                        title: "See the space inside your Mac.",
                        description: "Choose a disk for the full picture, or narrow the scan to a specific folder. Hygieia remains read-only until you decide otherwise."
                    )
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .safeAreaInset(edge: .bottom) {
            if ScanStatusView.shouldDisplay(for: model) {
                ScanStatusView(model: model)
                    .padding(.horizontal, HygieiaSpacing.large)
                    .padding(.vertical, 9)
                    .background(HygieiaPalette.canvasRaised.opacity(0.97))
                    .overlay(alignment: .top) {
                        Rectangle().fill(HygieiaPalette.separator).frame(height: 1)
                    }
            }
        }
        .toolbar { toolbarContent }
        .focusedSceneValue(\.scanCommandActions, model.commandActions)
        .task {
            await model.discoverVolumesIfNeeded()
        }
        .confirmationDialog(
            "Move \(model.trashConfirmation?.displayName ?? "item") to Trash?",
            isPresented: Binding(
                get: { model.trashConfirmation != nil },
                set: { if !$0 { model.cancelTrashConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmMoveToTrash() }
            Button("Cancel", role: .cancel) { model.cancelTrashConfirmation() }
        } message: {
            if let confirmation = model.trashConfirmation {
                Text("\(confirmation.relativePath)\n\(confirmation.summary)\n\nFull path: \(confirmation.fullPath)\n\nThis item will be moved to the system Trash. Its displayed size is not a promise of freed space. Permanent deletion is not performed. \(confirmation.warning)")
            }
        }
        .confirmationDialog(
            "Move \(model.markedTrashConfirmation?.count ?? 0) Marked Items to Trash?",
            isPresented: Binding(
                get: { model.markedTrashConfirmation != nil },
                set: { if !$0 { model.cancelMarkedTrashConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Marked Items to Trash", role: .destructive) { model.confirmMoveMarkedItemsToTrash() }
            Button("Cancel", role: .cancel) { model.cancelMarkedTrashConfirmation() }
        } message: {
            if let confirmation = model.markedTrashConfirmation {
                Text("\(confirmation.summary)\n\n\(confirmation.pathSummary)\n\nEvery item is checked again immediately before it is moved. The batch stops if an item has changed or cannot be moved. Successfully moved items go to the system Trash; permanent deletion is not performed.")
            }
        }
    }

    private var explorer: some View {
        HStack(spacing: 0) {
            LargestItemsTable(model: model)
                .frame(minWidth: 244, idealWidth: 282, maxWidth: 310)

            Rectangle()
                .fill(HygieiaPalette.separator)
                .frame(width: 1)

            VStack(spacing: 0) {
                ExplorerContextBar(model: model)

                LustralFieldChartView(model: model)
                    .frame(minWidth: 560, minHeight: 330)

                Rectangle()
                    .fill(HygieiaPalette.separator)
                    .frame(height: 1)

                ExplorerInspectorBand(model: model)
                    .frame(minHeight: 220, idealHeight: 248, maxHeight: 278)
                    .padding(HygieiaSpacing.medium)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { model.goBack() }
                .disabled(!model.canGoBack)
            Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                .disabled(!model.canGoForward)
            Button("Up", systemImage: "arrow.up") { model.goUp() }
                .disabled(!model.canGoUp)

            Menu("Choose Source…", systemImage: "externaldrive") {
                ForEach(model.availableVolumes) { volume in
                    Button("Scan \(volume.name)…") { model.chooseVolume(volume) }
                }
                if !model.availableVolumes.isEmpty { Divider() }
                Button("Choose Folder…") { model.chooseFolder() }
                Button("Refresh Disk List") { model.refreshVolumes() }
            }
            .disabled(!model.canChooseFolder)
            Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                .disabled(!model.canRescan)

            if model.showsCancel {
                Button("Cancel", systemImage: "xmark") { model.cancel() }
                    .disabled(!model.canCancel)
            }
        }

        ToolbarItem(placement: .principal) {
            HygieiaBrandMark(size: 25)
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("Size metric", selection: Binding(
                get: { model.metric },
                set: { model.setMetric($0) }
            )) {
                Text("Logical").tag(SizeMetric.logical)
                Text("Allocated (reported)").tag(SizeMetric.reportedAllocated)
            }
            .pickerStyle(.segmented)
            .frame(width: 235)
        }
    }

    private func brandedState(
        scene: BrandedScene,
        title: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        ZStack {
            HygieiaAtmosphere(
                intensity: scene == .error ? 0.42 : 1,
                animated: scene == .scanning
            )

            if scene == .scanning {
                LustralScanSweep()
            }

            VStack(alignment: .leading, spacing: HygieiaSpacing.large) {
                HStack(spacing: HygieiaSpacing.small) {
                    Circle()
                        .fill(scene == .error ? HygieiaPalette.amber : HygieiaPalette.aqua)
                        .frame(width: 6, height: 6)
                        .shadow(
                            color: scene == .error ? HygieiaPalette.amber.opacity(0.7) : HygieiaPalette.aqua.opacity(0.7),
                            radius: 5
                        )
                    Text(scene.eyebrow.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.8)
                }
                .foregroundStyle(HygieiaPalette.textSecondary)

                Text(title)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundStyle(HygieiaPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.title3)
                    .foregroundStyle(HygieiaPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if scene == .scanning {
                    scanProgress
                }

                if scene == .empty {
                    sourceChooser
                } else if let actionTitle, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: "folder.badge.plus")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(HygieiaPalette.coral)
                }

                if scene == .empty {
                    HStack(spacing: HygieiaSpacing.xLarge) {
                        trustLabel("Read-only scan", systemImage: "eye")
                        trustLabel("You stay in control", systemImage: "hand.raised")
                    }
                }
            }
            .frame(maxWidth: 570, alignment: .leading)
            .padding(.leading, 64)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .background(HygieiaPalette.canvas)
        .accessibilityElement(children: .contain)
    }

    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
            HStack {
                Text("LOCAL DISKS")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(HygieiaPalette.textSecondary)
                Spacer()
                if model.isDiscoveringVolumes {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HygieiaPalette.aqua)
                        .accessibilityLabel("Finding local disks")
                }
            }

            if model.availableVolumes.isEmpty, !model.isDiscoveringVolumes {
                Text("No local disks are currently available. You can still choose a folder.")
                    .font(.callout)
                    .foregroundStyle(HygieiaPalette.textSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.availableVolumes) { volume in
                            volumeButton(volume)
                            if volume.id != model.availableVolumes.last?.id {
                                Rectangle().fill(HygieiaPalette.separator).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 196)
                .scrollIndicators(.hidden)
            }

            Button(action: model.chooseFolder) {
                Label("Choose a Folder…", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(HygieiaSpacing.medium)
        .background(HygieiaPalette.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous)
                .stroke(HygieiaPalette.separator, lineWidth: 1)
        }
    }

    private func volumeButton(_ volume: ScanVolume) -> some View {
        Button { model.chooseVolume(volume) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: HygieiaSpacing.small) {
                    Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                        .foregroundStyle(HygieiaPalette.glacier)
                        .frame(width: 20)
                    Text(volume.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(HygieiaPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Scan")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(HygieiaPalette.coral)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HygieiaPalette.coral)
                }

                HStack(spacing: HygieiaSpacing.small) {
                    ProgressView(value: volume.totalCapacity == 0 ? 0 : Double(volume.usedCapacity) / Double(volume.totalCapacity))
                        .progressViewStyle(.linear)
                        .tint(HygieiaPalette.glacier)
                    Text(volumeCapacityDescription(volume))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HygieiaPalette.textSecondary)
                        .lineLimit(1)
                }
                .padding(.leading, 29)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan \(volume.name), \(volumeCapacityDescription(volume))")
        .help("Scan the whole disk, or choose a folder inside it")
    }

    private func volumeCapacityDescription(_ volume: ScanVolume) -> String {
        guard volume.totalCapacity > 0 else { return "Capacity unavailable" }
        return "\(byteCount(volume.availableCapacity)) free of \(byteCount(volume.totalCapacity))"
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
            if let root = model.selectedRoot {
                Label(root.lastPathComponent, systemImage: "folder.fill")
                    .font(.headline)
                    .foregroundStyle(HygieiaPalette.textPrimary)
            }

            HStack(spacing: HygieiaSpacing.xLarge) {
                progressMetric(
                    model.progress?.committedNodeCount.formatted() ?? "—",
                    label: "Items"
                )
                progressMetric(
                    model.progress?.completedDirectoryCount.formatted() ?? "—",
                    label: "Folders"
                )
                progressMetric(
                    model.progress.map { byteCount($0.provisionalAllocatedBytes) } ?? "—",
                    label: "Reported"
                )
                progressMetric(
                    model.progress.map { elapsedDescription($0.elapsed) } ?? "—",
                    label: "Elapsed"
                )
            }

            ProgressView()
                .progressViewStyle(.linear)
                .tint(HygieiaPalette.aqua)
                .frame(maxWidth: 500)
                .accessibilityLabel("Scanning selected folder")

            HStack(spacing: HygieiaSpacing.medium) {
                Label(model.remainingTimeDescription, systemImage: "clock")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(HygieiaPalette.textPrimary)
                Spacer()
                if model.remainingKnownDirectoryCount > 0 {
                    Text("\(model.remainingKnownDirectoryCount.formatted()) folders queued")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(HygieiaPalette.textSecondary)
                }
            }
            .frame(maxWidth: 500)

            if model.canCancel {
                Button("Cancel Scan", action: model.cancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(HygieiaSpacing.large)
        .background(HygieiaPalette.panel.opacity(0.74), in: RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HygieiaRadius.panel, style: .continuous)
                .stroke(HygieiaPalette.separator, lineWidth: 1)
        }
    }

    private func progressMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(HygieiaPalette.textPrimary)
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.8)
                .foregroundStyle(HygieiaPalette.textSecondary)
        }
    }

    private func trustLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(HygieiaPalette.textSecondary)
    }

    private func elapsedDescription(_ duration: Duration) -> String {
        let seconds = max(0, duration.components.seconds)
        let minutes = seconds / 60
        return minutes > 0 ? "\(minutes)m \(seconds % 60)s" : "\(seconds)s"
    }
}

private struct LustralScanSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let progress = reduceMotion ? 0.22 : time.truncatingRemainder(dividingBy: 5.5) / 5.5
                Canvas { context, size in
                    let width = min(size.width * 0.68, 980)
                    let rect = CGRect(
                        x: (size.width - width) / 2,
                        y: size.height * 0.18,
                        width: width,
                        height: width * 0.42
                    )
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .color(HygieiaPalette.glacier.opacity(0.11)),
                        style: StrokeStyle(lineWidth: 1, dash: [1, 8])
                    )

                    let angle = progress * Double.pi * 2 - Double.pi / 2
                    let point = CGPoint(
                        x: rect.midX + cos(angle) * rect.width / 2,
                        y: rect.midY + sin(angle) * rect.height / 2
                    )
                    var glow = context
                    glow.addFilter(.shadow(color: HygieiaPalette.aqua.opacity(0.85), radius: 13))
                    glow.fill(
                        Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                        with: .color(HygieiaPalette.textPrimary.opacity(0.96))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ExplorerContextBar: View {
    let model: ScanFeatureModel

    var body: some View {
        HStack(spacing: HygieiaSpacing.large) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(model.breadcrumbNodes(), id: \.rawValue) { node in
                        if node == model.visibleRoot {
                            Text(model.displayName(for: .node(node)))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(HygieiaPalette.textPrimary)
                                .lineLimit(1)
                        } else {
                            Button(model.displayName(for: .node(node))) {
                                model.navigateBreadcrumb(to: node)
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(HygieiaPalette.textSecondary)
                        }
                        if node != model.visibleRoot {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(HygieiaPalette.textSecondary.opacity(0.72))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("Field breadcrumbs")

            Spacer(minLength: HygieiaSpacing.medium)

            if let result = model.displayedResult {
                HygieiaStatusPill(
                    systemImage: result.freshness == .current ? "checkmark.circle" : "arrow.clockwise.circle",
                    title: statusTitle(result),
                    tint: result.freshness == .current ? HygieiaPalette.aqua : HygieiaPalette.amber
                )
            }
        }
        .padding(.horizontal, HygieiaSpacing.large)
        .padding(.vertical, 10)
        .background(HygieiaPalette.canvasRaised.opacity(0.58))
        .overlay(alignment: .bottom) {
            Rectangle().fill(HygieiaPalette.separator).frame(height: 1)
        }
    }

    private func statusTitle(_ result: DisplayedScanResult) -> String {
        let size = byteCount(model.sunburstProjection?.nodes.first?.value ?? 0)
        return result.freshness == .current ? "Scan complete · \(size) analyzed" : "Refreshing · displayed sizes are stale"
    }
}

private struct ChartTap {
    let timestamp: TimeInterval
    let location: CGPoint
}

struct ChartTapSequence {
    private var previousTap: ChartTap?

    mutating func register(
        location: CGPoint,
        timestamp: TimeInterval,
        doubleClickInterval: TimeInterval,
        radius: CGFloat
    ) -> Bool {
        if let previousTap,
           timestamp - previousTap.timestamp <= doubleClickInterval,
           hypot(location.x - previousTap.location.x, location.y - previousTap.location.y) <= radius {
            self.previousTap = nil
            return true
        }
        previousTap = ChartTap(timestamp: timestamp, location: location)
        return false
    }
}

private struct LustralFieldChartView: View {
    @Bindable var model: ScanFeatureModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tapSequence = ChartTapSequence()

    private let perspective: CGFloat = 0.64
    private let doubleClickRadius: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let logicalSize = CGSize(width: proxy.size.width, height: proxy.size.height / perspective)

            ZStack {
                if let layout = model.sunburstLayout {
                    fieldAtmosphere(layout: layout)
                    fieldCanvas(layout: layout, visualSize: proxy.size, logicalSize: logicalSize)
                    labels(layout: layout, visualSize: proxy.size)
                    centerReadout(layout: layout)
                } else {
                    chartPlaceholder
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let logical = logicalPoint(from: location, visualSize: proxy.size, logicalSize: logicalSize)
                    model.hoverChart(atX: logical.x, y: logical.y)
                case .ended:
                    model.setHoveredItem(nil)
                }
            }
            .gesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        handleTap(value.location, visualSize: proxy.size, logicalSize: logicalSize)
                    }
            )
            .onAppear { model.updateViewport(width: logicalSize.width, height: logicalSize.height) }
            .onChange(of: proxy.size) { _, next in
                model.updateViewport(width: next.width, height: next.height / perspective)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: model.sunburstLayout?.segments)
            .accessibilityRepresentation { accessibilityChart }
        }
        .padding(.horizontal, HygieiaSpacing.large)
        .padding(.vertical, HygieiaSpacing.small)
        .background(HygieiaPalette.canvas)
    }

    private func handleTap(_ location: CGPoint, visualSize: CGSize, logicalSize: CGSize) {
        let logical = logicalPoint(from: location, visualSize: visualSize, logicalSize: logicalSize)
        model.selectChart(atX: logical.x, y: logical.y)

        let now = Date.timeIntervalSinceReferenceDate
        if tapSequence.register(
            location: location,
            timestamp: now,
            doubleClickInterval: NSEvent.doubleClickInterval,
            radius: doubleClickRadius
        ) {
            model.activateChart(atX: logical.x, y: logical.y)
        }
    }

    private func fieldAtmosphere(layout: SunburstLayoutResult) -> some View {
        Image("LustralNebula")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(
                width: (layout.outerRadius + 18) * 2,
                height: (layout.outerRadius + 18) * 2 * perspective
            )
            .clipShape(Ellipse())
            .opacity(0.46)
            .blendMode(.screen)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func fieldCanvas(
        layout: SunburstLayoutResult,
        visualSize: CGSize,
        logicalSize: CGSize
    ) -> some View {
        Canvas { context, _ in
            var field = context
            field.translateBy(x: 0, y: visualSize.height / 2)
            field.scaleBy(x: 1, y: perspective)
            field.translateBy(x: 0, y: -logicalSize.height / 2)

            let center = CGPoint(x: logicalSize.width / 2, y: logicalSize.height / 2)
            let outerRect = CGRect(
                x: center.x - layout.outerRadius - 10,
                y: center.y - layout.outerRadius - 10,
                width: (layout.outerRadius + 10) * 2,
                height: (layout.outerRadius + 10) * 2
            )
            field.stroke(
                Path(ellipseIn: outerRect),
                with: .color(
                    model.chartHighlightedItem == .node(layout.sourceRoot)
                        ? HygieiaPalette.coral.opacity(0.28)
                        : HygieiaPalette.glacier.opacity(0.16)
                ),
                style: StrokeStyle(lineWidth: 1, dash: [2, 7])
            )

            for segment in layout.segments {
                let path = annularPath(for: segment, in: logicalSize)
                let color = fillColor(for: segment, layout: layout)
                let selected = model.chartHighlightedItem == segment.item
                var segmentContext = field
                if selected {
                    segmentContext.addFilter(.shadow(color: HygieiaPalette.coral.opacity(0.50), radius: 9))
                }
                segmentContext.fill(path, with: .color(color))
                segmentContext.stroke(
                    path,
                    with: .color(selected ? HygieiaPalette.coral.opacity(0.94) : HygieiaPalette.glacier.opacity(0.32)),
                    lineWidth: selected ? 2.2 : 0.8
                )

                let contourCount = segment.depth == 1 ? 5 : segment.depth == 2 ? 2 : 0
                if contourCount > 0, segment.endAngle - segment.startAngle > 0.09 {
                    for contourIndex in 1...contourCount {
                        let fraction = Double(contourIndex) / Double(contourCount + 1)
                        let contour = irregularContourPath(for: segment, fraction: fraction, in: logicalSize)
                        segmentContext.stroke(
                            contour,
                            with: .color(
                                selected
                                    ? HygieiaPalette.coral.opacity(0.48)
                                    : HygieiaPalette.textPrimary.opacity(0.20)
                            ),
                            style: StrokeStyle(lineWidth: selected ? 1.0 : 0.72, dash: [1.0, 3.4])
                        )
                    }
                }

                if model.explorer?.hoveredItem == segment.item, !selected {
                    segmentContext.stroke(path, with: .color(HygieiaPalette.textPrimary.opacity(0.78)), lineWidth: 1.6)
                }
            }

            drawConstellationParticles(context: &field, layout: layout, in: logicalSize)
        }
    }

    private func drawConstellationParticles(
        context: inout GraphicsContext,
        layout: SunburstLayoutResult,
        in size: CGSize
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radialSpan = max(1, layout.outerRadius - layout.centerRadius)
        var particles = context
        particles.addFilter(.shadow(color: HygieiaPalette.glacier.opacity(0.34), radius: 3))

        for segment in layout.segments where segment.depth == 1 {
            let span = segment.endAngle - segment.startAngle
            let count = min(38, max(12, Int(span * 27)))
            let seed = Int(segment.projectionIndex.rawValue) * 97 + 31
            let selected = model.chartHighlightedItem == segment.item
            let tint = selected ? HygieiaPalette.coral : HygieiaPalette.glacier
            var previousAnchor: CGPoint?

            for index in 0..<count {
                let angularNoise = unitNoise(seed + index * 11)
                let radialNoise = unitNoise(seed + index * 17 + 5)
                let angle = segment.startAngle + span * (0.04 + angularNoise * 0.92)
                let radius = layout.centerRadius + radialSpan * (0.08 + radialNoise * 0.86)
                let point = CGPoint(
                    x: center.x + CGFloat(sin(angle) * radius),
                    y: center.y - CGFloat(cos(angle) * radius)
                )
                let isAnchor = index.isMultiple(of: 8)
                let diameter = isAnchor ? 3.2 : 1.15 + unitNoise(seed + index * 23) * 1.35

                particles.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - diameter / 2,
                        y: point.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: .color(tint.opacity(isAnchor ? 0.74 : 0.34))
                )

                if isAnchor {
                    if let previousAnchor {
                        var connection = Path()
                        connection.move(to: previousAnchor)
                        connection.addLine(to: point)
                        particles.stroke(connection, with: .color(tint.opacity(0.12)), lineWidth: 0.55)
                    }
                    previousAnchor = point
                }
            }
        }
    }

    private func unitNoise(_ seed: Int) -> Double {
        let value = sin(Double(seed) * 12.9898 + 78.233) * 43_758.5453
        return value - floor(value)
    }

    @ViewBuilder
    private func labels(layout: SunburstLayoutResult, visualSize: CGSize) -> some View {
        ForEach(Array(layout.segments.filter { $0.depth == 1 && $0.endAngle - $0.startAngle > 0.22 }.enumerated()), id: \.offset) { _, segment in
            let position = fieldLabelPosition(for: segment, layout: layout, visualSize: visualSize)
            VStack(spacing: 2) {
                Text(model.displayName(for: segment.item))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(byteCount(segment.value))
                    .font(.headline)
                    .monospacedDigit()
            }
            .foregroundStyle(model.chartHighlightedItem == segment.item ? HygieiaPalette.coral : HygieiaPalette.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(HygieiaPalette.canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .position(position)
            .allowsHitTesting(false)
        }
    }

    private func centerReadout(layout: SunburstLayoutResult) -> some View {
        let selected = model.chartHighlightedItem == .node(layout.sourceRoot)
        return VStack(spacing: 2) {
            Text(byteCount(model.sunburstProjection?.nodes.first?.value ?? 0))
                .font(.title2.weight(.medium))
                .monospacedDigit()
            Text(model.metric.title)
                .font(.caption)
                .foregroundStyle(HygieiaPalette.textSecondary)
            Text(model.displayName(for: .node(layout.sourceRoot)))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if model.canGoUp {
                Label("Click to go up", systemImage: "arrow.up")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(HygieiaPalette.textSecondary)
            }
        }
        .foregroundStyle(selected ? HygieiaPalette.coral : HygieiaPalette.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            selected ? HygieiaPalette.coral.opacity(0.13) : HygieiaPalette.canvas.opacity(0.94),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                selected ? HygieiaPalette.coral.opacity(0.64) : HygieiaPalette.separator,
                lineWidth: selected ? 1.5 : 1
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var chartPlaceholder: some View {
        switch model.projectionPhase {
        case .preparingProjection, .layingOut:
            ProgressView("Preparing storage field…")
                .tint(HygieiaPalette.aqua)
        case .failed(let message):
            ContentUnavailableView("Field unavailable", systemImage: "circle.hexagongrid", description: Text(message))
        case .idle, .ready:
            ContentUnavailableView("Field needs more space", systemImage: "circle.hexagongrid", description: Text("Increase the visualization area to continue."))
        }
    }

    private var accessibilityChart: some View {
        VStack {
            if let layout = model.sunburstLayout {
                Button("Field root: \(model.displayName(for: .node(layout.sourceRoot)))") {
                    model.select(item: .node(layout.sourceRoot))
                }
                ForEach(Array(layout.segments.enumerated()), id: \.offset) { _, segment in
                    Button(accessibilityTitle(for: segment, layout: layout)) {
                        model.select(item: segment.item)
                    }
                    .accessibilityAction(named: "Open in Field") {
                        if case .node(let node) = segment.item, model.isDrillable(segment.item) {
                            model.drill(to: node)
                        }
                    }
                }
            }
        }
    }

    private func fillColor(for segment: SunburstSegment, layout: SunburstLayoutResult) -> Color {
        if case .other = segment.item { return HygieiaPalette.glacierDim.opacity(0.42) }
        if case .node(let node) = segment.item {
            if model.isInvalidated(node) { return HygieiaPalette.glacierDim.opacity(0.20) }
            if model.isMarkedForTrash(node) { return HygieiaPalette.amber.opacity(0.60) }
        }
        if model.chartHighlightedItem == segment.item { return HygieiaPalette.coral.opacity(0.54) }

        let topLevel = topLevelSegment(for: segment, layout: layout)
        let familyOffset = Double(topLevel.projectionIndex.rawValue % 5) * 0.035
        let depthFade = max(0.14, 0.28 - Double(segment.depth - 1) * 0.030)
        return HygieiaPalette.glacier.opacity(depthFade + familyOffset)
    }

    private func topLevelSegment(for segment: SunburstSegment, layout: SunburstLayoutResult) -> SunburstSegment {
        var current = segment
        while current.depth > 1, let parent = current.parentSegment {
            current = layout.segments[Int(parent.rawValue)]
        }
        return current
    }

    private func annularPath(for segment: SunburstSegment, in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = Angle.radians(segment.startAngle - .pi / 2)
        let end = Angle.radians(segment.endAngle - .pi / 2)
        var path = Path()
        path.addArc(center: center, radius: segment.outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: segment.innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func irregularContourPath(for segment: SunburstSegment, fraction: Double, in size: CGSize) -> Path {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let thickness = segment.outerRadius - segment.innerRadius
        let baseRadius = segment.innerRadius + thickness * fraction
        let span = segment.endAngle - segment.startAngle
        let sampleCount = min(42, max(8, Int(span / 0.065)))
        let phase = Double(segment.projectionIndex.rawValue % 17) * 0.37
        var path = Path()
        for sample in 0...sampleCount {
            let progress = Double(sample) / Double(sampleCount)
            let angle = segment.startAngle + span * progress
            let wave = sin(angle * 3.2 + phase) * thickness * 0.075
                + sin(angle * 8.7 - phase * 0.6) * thickness * 0.030
            let radius = baseRadius + wave
            let point = CGPoint(
                x: center.x + CGFloat(sin(angle) * radius),
                y: center.y - CGFloat(cos(angle) * radius)
            )
            if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func fieldLabelPosition(
        for segment: SunburstSegment,
        layout: SunburstLayoutResult,
        visualSize: CGSize
    ) -> CGPoint {
        let angle = (segment.startAngle + segment.endAngle) / 2
        let radius = layout.centerRadius + (layout.outerRadius - layout.centerRadius) * 0.56
        return CGPoint(
            x: visualSize.width / 2 + CGFloat(sin(angle) * radius),
            y: visualSize.height / 2 - CGFloat(cos(angle) * radius) * perspective
        )
    }

    private func logicalPoint(from point: CGPoint, visualSize: CGSize, logicalSize: CGSize) -> CGPoint {
        CGPoint(
            x: point.x,
            y: logicalSize.height / 2 + (point.y - visualSize.height / 2) / perspective
        )
    }

    private func accessibilityTitle(for segment: SunburstSegment, layout: SunburstLayoutResult) -> String {
        let name = model.accessibilityDescription(for: segment.item)
        let total = model.sunburstProjection?.nodes.first?.value ?? 0
        let percentage = total == 0 ? 0 : Double(segment.value) / Double(total) * 100
        if case .other = segment.item {
            return "\(name), \(byteCount(segment.value)), \(percentage.formatted(.number.precision(.fractionLength(1)))) percent"
        }
        return "\(name), level \(segment.depth), \(byteCount(segment.value)), \(percentage.formatted(.number.precision(.fractionLength(1)))) percent"
    }
}

private struct ExplorerInspectorBand: View {
    @Bindable var model: ScanFeatureModel

    var body: some View {
        HygieiaPanel {
            HStack(spacing: 0) {
                ScrollView {
                    FileDetailsView(model: model)
                        .hygieiaSectionPadding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                inspectorDivider

                LargestInVisibleRootView(model: model)
                    .hygieiaSectionPadding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                inspectorDivider

                CleanupReviewView(model: model)
                    .hygieiaSectionPadding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inspectorDivider: some View {
        Rectangle()
            .fill(HygieiaPalette.separator)
            .frame(width: 1)
            .padding(.vertical, HygieiaSpacing.medium)
    }
}

private struct LargestInVisibleRootView: View {
    let model: ScanFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
            HygieiaSectionTitle(
                title: "Largest Here",
                detail: model.visibleRoot.map { model.displayName(for: .node($0)) }
            )

            if model.rows.isEmpty {
                Text("No non-zero items for this metric.")
                    .font(.callout)
                    .foregroundStyle(HygieiaPalette.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.rows.prefix(5)) { row in
                        Button {
                            model.select(node: row.id)
                        } label: {
                            HStack(spacing: HygieiaSpacing.small) {
                                Image(systemName: row.kind == .directory ? "folder" : "doc")
                                    .foregroundStyle(model.selectedNodeID == row.id ? HygieiaPalette.coral : HygieiaPalette.glacier)
                                    .frame(width: 18)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: HygieiaSpacing.small)
                                Text(byteCount(row.size(for: model.metric)))
                                    .monospacedDigit()
                                    .foregroundStyle(HygieiaPalette.textSecondary)
                            }
                            .font(.callout)
                            .foregroundStyle(HygieiaPalette.textPrimary)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if row.id != model.rows.prefix(5).last?.id {
                            Rectangle().fill(HygieiaPalette.separator).frame(height: 1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct CleanupReviewView: View {
    @Bindable var model: ScanFeatureModel

    private var markedItems: [TrashConfirmation] {
        model.markedTrashItems.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HygieiaSpacing.medium) {
            HygieiaSectionTitle(
                title: "Review before cleanup",
                detail: model.markedTrashCount == 0 ? "Nothing marked" : "\(model.markedTrashCount) marked"
            )

            if markedItems.isEmpty {
                Text("Mark an eligible item to build a review list. Nothing changes on disk until you confirm Move to Trash.")
                    .font(.callout)
                    .foregroundStyle(HygieiaPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(markedItems.prefix(2).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: HygieiaSpacing.small) {
                            Image(systemName: "checkmark.square.fill")
                                .foregroundStyle(HygieiaPalette.amber)
                            Text(item.displayName)
                                .lineLimit(1)
                            Spacer(minLength: HygieiaSpacing.small)
                            Text(byteCount(size(of: item)))
                                .monospacedDigit()
                                .foregroundStyle(HygieiaPalette.textSecondary)
                        }
                        .font(.callout)
                    }
                    if markedItems.count > 2 {
                        Text("and \(markedItems.count - 2) more…")
                            .font(.caption)
                            .foregroundStyle(HygieiaPalette.textSecondary)
                    }
                }

                Text("Items remain on disk until the system Trash operation succeeds. Displayed size is not a promise of freed space.")
                    .font(.caption)
                    .foregroundStyle(HygieiaPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: HygieiaSpacing.small) {
                Button("Show in Finder", systemImage: "finder") {
                    model.revealSelectedInFinder()
                }
                .disabled(!isAllowed(.revealInFinder))

                Button(model.isSelectedMarkedForTrash ? "Unmark" : "Mark for Trash", systemImage: "trash") {
                    model.toggleSelectedTrashMark()
                }
                .disabled(!model.canToggleSelectedTrashMark)
            }
            .buttonStyle(.bordered)

            Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                if model.markedTrashCount > 0 {
                    model.prepareMarkedItemsForTrash()
                } else {
                    model.prepareMoveSelectedToTrash()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(HygieiaPalette.destructive)
            .frame(maxWidth: .infinity)
            .disabled(model.markedTrashCount > 0 ? !model.canMoveMarkedItemsToTrash : !isAllowed(.moveToTrash))
            .help("Every item is validated again before the system Trash request.")
        }
    }

    private func size(of confirmation: TrashConfirmation) -> UInt64 {
        switch model.metric {
        case .logical: confirmation.target.logicalSize
        case .reportedAllocated: confirmation.target.reportedAllocatedSize
        }
    }

    private func isAllowed(_ action: FileActionKind) -> Bool {
        if case .allowed = model.fileActionEligibility(action) { return true }
        return false
    }
}
