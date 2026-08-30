import Foundation
import HygieiaDomain

public struct RootDirectoryRecord: Sendable {
    public let displayName: String
    public let identity: FileIdentity
    public init(displayName: String, identity: FileIdentity) {
        self.displayName = displayName
        self.identity = identity
    }
}

public struct DirectoryLease: Sendable {
    public let workID: UInt64
    public let node: NodeID
    public let url: URL
    public let identity: FileIdentity
}

/// Actor-isolated orchestration and the single owner of the non-Sendable builder.
public actor ScanCoordinator {
    private enum DirectoryState: Equatable { case pending, inFlight(UInt64), finished, unscannable }

    private let rootURL: URL
    private let rootDevice: UInt64
    private let configuration: ScanConfiguration
    private let updates: AsyncStream<ScanUpdate>.Continuation
    private let startedAt = Date()
    private let clock = ContinuousClock()
    private let startedInstant: ContinuousClock.Instant
    private var lastProgressInstant: ContinuousClock.Instant
    private var builder: FileTreeBuilder
    private var directoryStates: ContiguousArray<DirectoryState> = [.pending]
    private var directoryIdentities: ContiguousArray<FileIdentity?>
    private var seenDirectories: Set<FileIdentity>
    private var pendingCursor = 0
    private var nextWorkID: UInt64 = 0
    private var inFlight = 0
    private var completedDirectories: UInt64 = 0
    private var discoveredEntries: UInt64 = 0
    private var provisionalLogical: UInt64 = 0
    private var provisionalAllocated: UInt64 = 0
    private var issueCounts: [ScanIssueKind: UInt64] = [:]
    private var issueSamples: [ScanIssueSample] = []
    private var waiters: [CheckedContinuation<DirectoryLease?, Never>] = []
    private var cancelled = false

    public init(rootURL: URL, root: RootDirectoryRecord, configuration: ScanConfiguration, updates: AsyncStream<ScanUpdate>.Continuation) throws {
        self.rootURL = rootURL
        self.rootDevice = root.identity.device
        self.configuration = configuration
        self.updates = updates
        self.builder = try FileTreeBuilder(rootName: root.displayName, rootIdentity: root.identity)
        self.seenDirectories = [root.identity]
        self.directoryIdentities = [root.identity]
        let now = ContinuousClock().now
        self.startedInstant = now
        self.lastProgressInstant = now
    }

    public func claim() async -> DirectoryLease? {
        if let lease = nextLease() { return lease }
        guard !cancelled, inFlight > 0 else { return nil }
        return await withCheckedContinuation { continuation in waiters.append(continuation) }
    }

    public func submit(_ lease: DirectoryLease, result: DirectoryReadResult) throws {
        guard result.workID == lease.workID,
              Int(lease.node.rawValue) < directoryStates.count,
              directoryStates[Int(lease.node.rawValue)] == .inFlight(lease.workID) else { return }
        inFlight -= 1
        defer { resumeWaiters(); emitProgressIfDue() }
        if cancelled {
            builder.mark(lease.node, adding: [.incompleteSubtree])
            directoryStates[Int(lease.node.rawValue)] = .unscannable
            return
        }
        completedDirectories += 1
        if let failure = result.failure {
            builder.mark(lease.node, adding: [.inaccessible, .incompleteSubtree])
            directoryStates[Int(lease.node.rawValue)] = .unscannable
            recordFailure(failure, for: lease.node)
            return
        }
        directoryStates[Int(lease.node.rawValue)] = .finished
        if !result.entryIssues.isEmpty { builder.mark(lease.node, adding: [.incompleteSubtree]) }
        for issue in result.entryIssues { recordFailure(issue.failure, relativePath: childPath(parent: lease.node, name: issue.name)) }
        for entry in result.entries {
            try add(entry, under: lease.node)
        }
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        for index in directoryStates.indices where directoryStates[index] != .finished {
            builder.mark(NodeID(rawValue: UInt32(index)), adding: [.incompleteSubtree])
            if case .pending = directoryStates[index] { directoryStates[index] = .unscannable }
        }
        let suspended = waiters
        waiters.removeAll(keepingCapacity: false)
        suspended.forEach { $0.resume(returning: nil) }
    }

    public func finish() throws -> ScanResult {
        if cancelled {
            for index in directoryStates.indices where directoryStates[index] != .finished {
                builder.mark(NodeID(rawValue: UInt32(index)), adding: [.incompleteSubtree])
            }
        }
        let tree = try builder.finalize()
        for node in builder.hardLinkGroupsOutsideRoot { recordIssue(.hardLinksOutsideRoot, node: node, code: nil) }
        let progress = makeProgress()
        updates.yield(.finishing)
        updates.finish()
        return ScanResult(
            rootURL: rootURL,
            tree: tree,
            completion: cancelled ? .cancelled : .complete,
            accounting: ScanAccountingPolicy(),
            progress: progress,
            issues: ScanIssueSummary(counts: issueCounts, samples: issueSamples),
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func nextLease() -> DirectoryLease? {
        guard !cancelled else { return nil }
        while pendingCursor < directoryStates.count {
            defer { pendingCursor += 1 }
            guard directoryStates[pendingCursor] == .pending else { continue }
            let node = NodeID(rawValue: UInt32(pendingCursor))
            guard let identity = directoryIdentities[pendingCursor] else {
                directoryStates[pendingCursor] = .unscannable
                builder.mark(node, adding: [.inaccessible, .incompleteSubtree])
                recordIssue(.metadataReadFailed, node: node, code: nil)
                continue
            }
            nextWorkID &+= 1
            directoryStates[pendingCursor] = .inFlight(nextWorkID)
            inFlight += 1
            let relative = builder.relativePath(for: node)
            let url = relative.isEmpty ? rootURL : rootURL.appending(path: relative, directoryHint: .isDirectory)
            return DirectoryLease(workID: nextWorkID, node: node, url: url, identity: identity)
        }
        return nil
    }

    private func resumeWaiters() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: nextLease())
        }
    }

    private func add(_ entry: DirectoryEntryRecord, under parent: NodeID) throws {
        discoveredEntries = try adding(discoveredEntries, 1)
        provisionalLogical = try adding(provisionalLogical, entry.logicalSize)
        provisionalAllocated = try adding(provisionalAllocated, entry.allocatedSize)
        var flags = entry.flags
        let isDirectory = entry.kind == .directory
        var shouldTraverse = isDirectory
        if isDirectory {
            guard let identity = entry.identity else {
                flags.formUnion([.inaccessible, .incompleteSubtree])
                shouldTraverse = false
                recordIssue(.metadataReadFailed, relativePath: childPath(parent: parent, name: entry.name), code: nil)
                let id = try builder.append(parent: parent, name: entry.name, kind: entry.kind, logicalSize: 0, allocatedSize: 0, flags: flags, identity: nil, reportedLinkCount: entry.reportedLinkCount)
                directoryStates.append(.unscannable)
                directoryIdentities.append(nil)
                _ = id
                return
            }
            if identity.device != rootDevice {
                flags.formUnion([.volumeBoundary, .incompleteSubtree])
                shouldTraverse = false
            } else if !seenDirectories.insert(identity).inserted {
                flags.insert(.incompleteSubtree)
                shouldTraverse = false
            }
        }
        let id = try builder.append(parent: parent, name: entry.name, kind: entry.kind, logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize, flags: flags, identity: entry.identity, reportedLinkCount: entry.reportedLinkCount)
        directoryStates.append(shouldTraverse ? .pending : .unscannable)
        directoryIdentities.append(isDirectory ? entry.identity : nil)
        if isDirectory, flags.contains(.volumeBoundary) { recordIssue(.volumeBoundary, node: id, code: nil) }
        if isDirectory, flags.contains(.incompleteSubtree), !flags.contains(.volumeBoundary), !shouldTraverse { recordIssue(.repeatedDirectoryIdentity, node: id, code: nil) }
    }

    private func recordFailure(_ failure: DirectoryReadFailure, for node: NodeID) {
        switch failure {
        case .permissionDenied(let code): recordIssue(.permissionDenied, node: node, code: code)
        case .disappeared(let code): recordIssue(.itemDisappeared, node: node, code: code)
        case .metadataReadFailed(let code): recordIssue(.metadataReadFailed, node: node, code: code)
        }
    }

    private func recordFailure(_ failure: DirectoryReadFailure, relativePath: String) {
        switch failure {
        case .permissionDenied(let code): recordIssue(.permissionDenied, relativePath: relativePath, code: code)
        case .disappeared(let code): recordIssue(.itemDisappeared, relativePath: relativePath, code: code)
        case .metadataReadFailed(let code): recordIssue(.metadataReadFailed, relativePath: relativePath, code: code)
        }
    }

    private func recordIssue(_ kind: ScanIssueKind, node: NodeID, code: Int32?) {
        recordIssue(kind, relativePath: builder.relativePath(for: node), code: code)
    }

    private func recordIssue(_ kind: ScanIssueKind, relativePath: String, code: Int32?) {
        issueCounts[kind, default: 0] += 1
        guard issueSamples.count < configuration.retainedIssueSamples else { return }
        issueSamples.append(ScanIssueSample(kind: kind, relativePath: relativePath, code: code))
    }

    private func childPath(parent: NodeID, name: String) -> String {
        let base = builder.relativePath(for: parent)
        return base.isEmpty ? name : base + "/" + name
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw FileTreeBuildError.sizeOverflow }
        return result.partialValue
    }

    private func emitProgressIfDue() {
        let now = clock.now
        guard now - lastProgressInstant >= configuration.progressMinimumInterval else { return }
        lastProgressInstant = now
        updates.yield(.progress(makeProgress(now: now)))
    }

    private func makeProgress(now: ContinuousClock.Instant? = nil) -> ScanProgress {
        let pending = directoryStates.reduce(into: UInt64(0)) { if $1 == .pending { $0 += 1 } }
        return ScanProgress(
            discoveredEntryCount: discoveredEntries,
            committedNodeCount: UInt64(builder.count),
            completedDirectoryCount: completedDirectories,
            pendingDirectoryCount: pending,
            inFlightDirectoryCount: UInt64(inFlight),
            provisionalLogicalBytes: provisionalLogical,
            provisionalAllocatedBytes: provisionalAllocated,
            issueCount: issueCounts.values.reduce(0, +),
            elapsed: startedInstant.duration(to: now ?? clock.now)
        )
    }
}
