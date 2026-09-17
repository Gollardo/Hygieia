import Foundation
import Observation
import HygieiaDomain
import HygieiaScannerCore

struct MacRootReport: Identifiable, Sendable {
    enum State: String, Sendable {
        case notSelected = "Not selected"
        case queued = "Queued"
        case authorizing = "Choose this disk in the system panel"
        case scanning = "Scanning"
        case scanned = "No issues observed in this root"
        case incomplete = "Coverage incomplete"
        case skipped = "Not authorized"
        case unavailable = "Source unavailable"
        case failed = "Scan failed"
        case cancelled = "Cancelled"
    }
    let volume: ScanVolume
    var id: String { volume.id }
    var state: State = .notSelected
    var detail = ""
    var logicalBytes: UInt64?
    var allocatedBytes: UInt64?
    var startedAt: Date?
    var finishedAt: Date?
    var identity: FileIdentity?
    var issueCounts: [ScanIssueKind: UInt64] = [:]
    var samples: [String] = []
}

/// One active scanner; completed roots retain bounded evidence, never FileTrees.
@MainActor
@Observable
final class WholeMacScanModel {
    static let rootLimit = 64
    static let coverageNotice = "Limited to selected, accessible local roots. Not all Mac data. Results are separate: APFS System/Data, aliases and shared storage must not be added together."
    static let accessNotice = "Full Disk Access: not verified. Permission errors can also come from App Sandbox, file permissions or system protection. In System Settings → Privacy & Security → Full Disk Access, add Hygieia if you want to allow more access. Restart the app after changing access, then scan again. You must still select each disk in the system panel. You can continue with limited access."

    private(set) var reports: [MacRootReport] = []
    var selectedIDs: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var hasRun = false
    private(set) var discoveryWarning: String?
    private(set) var progress: ScanProgress?
    private let scanner: any FileSystemScanner
    private let picker: any FolderPicking
    private let discovery: any VolumeDiscovering
    private var session: ScanSession?
    private var runTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(scanner: any FileSystemScanner, picker: any FolderPicking, discovery: any VolumeDiscovering) {
        self.scanner = scanner
        self.picker = picker
        self.discovery = discovery
    }

    var canStart: Bool { !isRunning && !isRefreshing && reports.contains { selectedIDs.contains($0.id) } }
    var status: String {
        if isCancelling { return "Stopping after the active system call. If a selection panel is open, cancel it." }
        if isRunning { return "Scanning selected roots, one at a time" }
        return hasRun ? "Scan ended · limited coverage" : "Choose the scope before scanning"
    }

    func refresh() async {
        guard !isRunning, !isRefreshing else { return }
        isRefreshing = true
        let token = generation
        defer { if generation == token { isRefreshing = false } }
        do {
            let snapshot = try await discovery.discoverLocalVolumes()
            guard generation == token, !Task.isCancelled else { return }
            var seen: Set<String> = []
            let roots = snapshot.volumes.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
            reports = roots.prefix(Self.rootLimit).map { MacRootReport(volume: $0) }
            selectedIDs = Set(reports.filter { $0.volume.isInternal && !$0.volume.isRemovable }.map(\.id))
            hasRun = false
            discoveryWarning = snapshot.unreadableVolumeCount > 0 || roots.count > Self.rootLimit
                ? "The disk list is incomplete. Some mounts could not be inspected or exceed the 64-root limit." : nil
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            discoveryWarning = "Disk discovery failed. Previously listed roots may be unavailable. Retry before scanning."
        }
    }

    func start() {
        guard canStart else { return }
        generation &+= 1
        let token = generation
        let chosen = selectedIDs
        reports = reports.map { old in
            var report = MacRootReport(volume: old.volume)
            report.state = chosen.contains(old.id) ? .queued : .notSelected
            return report
        }
        isRunning = true
        isCancelling = false
        hasRun = true
        runTask = Task { [weak self] in
            guard let self, self.generation == token else { return }
            for index in self.reports.indices {
                guard self.generation == token, !self.isCancelling else { break }
                guard self.reports[index].state == .queued else { continue }
                await self.scanRoot(at: index, token: token)
            }
            guard self.generation == token else { return }
            for index in self.reports.indices where self.reports[index].state == .queued {
                self.reports[index].state = .cancelled
            }
            self.session = nil
            self.progressTask?.cancel()
            self.progressTask = nil
            self.progress = nil
            self.isRunning = false
            self.isCancelling = false
            self.runTask = nil
        }
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        session?.cancel()
    }

    func teardown() {
        generation &+= 1
        session?.cancel()
        session = nil
        runTask?.cancel()
        progressTask?.cancel()
        runTask = nil
        progressTask = nil
        isRunning = false
        isRefreshing = false
        isCancelling = false
    }

    private func scanRoot(at index: Int, token: UInt64) async {
        let volume = reports[index].volume
        reports[index].state = .authorizing
        do {
            guard let before = try await currentVolume(volume), let identity = before.rootIdentity else {
                if generation == token { reports[index].state = .unavailable }
                return
            }
            guard generation == token, !isCancelling else { markCancelled(index, token); return }
            let selection = await picker.chooseFolder(startingAt: volume.url, prompt: "Scan Disk")
            defer { selection?.lease.release() }
            guard generation == token, !isCancelling else { markCancelled(index, token); return }
            guard let selection else {
                reports[index].state = .skipped
                reports[index].detail = "Selection cancelled. No scan was started for this disk."
                return
            }
            guard selection.url.standardizedFileURL == volume.url.standardizedFileURL else {
                reports[index].state = .skipped
                reports[index].detail = "A different folder was selected. Select the disk root shown above, or use Choose Folder for a folder scan."
                return
            }
            guard let after = try await currentVolume(volume), after.rootIdentity == identity else {
                if generation == token { reports[index].state = .unavailable }
                return
            }
            guard generation == token, !isCancelling else { markCancelled(index, token); return }
            reports[index].identity = identity
            reports[index].state = .scanning
            reports[index].startedAt = Date()
            progress = nil
            let active = scanner.startScan(.init(rootURL: selection.url, expectedRootIdentity: identity))
            session = active
            progressTask = Task { [weak self] in
                for await update in active.updates {
                    guard let self, !Task.isCancelled, self.generation == token else { return }
                    if case .progress(let progress) = update { self.progress = progress }
                }
            }
            let result = try await active.result.value
            guard generation == token else { return }
            reports[index].state = result.sourceIsUnavailable ? .unavailable
                : (isCancelling || result.completion == .cancelled) ? .cancelled
                : result.hasIncompleteCoverage ? .incomplete : .scanned
            reports[index].logicalBytes = result.tree[result.tree.root].logicalSize
            reports[index].allocatedBytes = result.tree[result.tree.root].allocatedSize
            reports[index].startedAt = result.startedAt
            reports[index].finishedAt = result.finishedAt
            reports[index].identity = result.tree.identity(for: result.tree.root)
            reports[index].issueCounts = result.issues.counts
            reports[index].samples = result.issues.samples.prefix(20).map { "\($0.kind.rawValue): \($0.relativePath)" }
        } catch {
            guard generation == token else { return }
            reports[index].state = isCancelling ? .cancelled : .failed
            reports[index].detail = ScanFailurePresentation.make(from: error).message
            reports[index].finishedAt = Date()
        }
        if generation == token {
            session = nil
            progressTask?.cancel()
            progressTask = nil
            progress = nil
        }
    }

    private func currentVolume(_ volume: ScanVolume) async throws -> ScanVolume? {
        let snapshot = try await discovery.discoverLocalVolumes()
        return snapshot.volumes.first { $0.id == volume.id && $0.url.standardizedFileURL == volume.url.standardizedFileURL }
    }

    private func markCancelled(_ index: Int, _ token: UInt64) {
        if generation == token { reports[index].state = .cancelled }
    }
}
