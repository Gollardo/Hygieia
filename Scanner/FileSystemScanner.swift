import Foundation
import HygieiaDomain

public protocol DirectoryScanningBackend: Sendable {
    func readDirectory(_ request: DirectoryReadRequest) async -> DirectoryReadResult
}

public protocol FileSystemScanner: Sendable {
    func startScan(_ request: ScanRequest) -> ScanSession
}

public struct ScanRequest: Sendable {
    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL }
}

public struct DirectoryReadRequest: Sendable {
    public let workID: UInt64
    public let directoryURL: URL
    public let expectedIdentity: FileIdentity
    public init(workID: UInt64, directoryURL: URL, expectedIdentity: FileIdentity) {
        self.workID = workID
        self.directoryURL = directoryURL
        self.expectedIdentity = expectedIdentity
    }
}

public struct DirectoryEntryRecord: Sendable {
    public let name: String
    public let kind: NodeKind
    public let logicalSize: UInt64
    public let allocatedSize: UInt64
    public let flags: NodeFlags
    public let identity: FileIdentity?
    public let reportedLinkCount: UInt32

    public init(name: String, kind: NodeKind, logicalSize: UInt64, allocatedSize: UInt64, flags: NodeFlags = [], identity: FileIdentity? = nil, reportedLinkCount: UInt32 = 1) {
        self.name = name
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.flags = flags
        self.identity = identity
        self.reportedLinkCount = reportedLinkCount
    }
}

public enum DirectoryReadFailure: Error, Sendable {
    case permissionDenied(code: Int32)
    case disappeared(code: Int32)
    case metadataReadFailed(code: Int32)
}

public struct DirectoryReadResult: Sendable {
    public let workID: UInt64
    public let entries: [DirectoryEntryRecord]
    public let entryIssues: [DirectoryEntryIssue]
    public let failure: DirectoryReadFailure?
    public init(workID: UInt64, entries: [DirectoryEntryRecord] = [], entryIssues: [DirectoryEntryIssue] = [], failure: DirectoryReadFailure? = nil) {
        self.workID = workID
        self.entries = entries
        self.entryIssues = entryIssues
        self.failure = failure
    }
}

public struct DirectoryEntryIssue: Sendable {
    public let name: String
    public let failure: DirectoryReadFailure
    public init(name: String, failure: DirectoryReadFailure) { self.name = name; self.failure = failure }
}

public enum ScanCompletion: String, Sendable { case complete, cancelled }

public struct ScanAccountingPolicy: Sendable {
    public let description: String
    public init(description: String = "Logical and reported allocated sizes are accounted subtree totals; directory and symlink allocation are excluded, hard links are accounted once, and APFS shared blocks are not reclaimable-space estimates.") {
        self.description = description
    }
}

public struct ScanProgress: Sendable {
    public let discoveredEntryCount: UInt64
    public let committedNodeCount: UInt64
    public let completedDirectoryCount: UInt64
    public let pendingDirectoryCount: UInt64
    public let inFlightDirectoryCount: UInt64
    public let provisionalLogicalBytes: UInt64
    public let provisionalAllocatedBytes: UInt64
    public let issueCount: UInt64
    public let elapsed: Duration
}

public enum ScanUpdate: Sendable {
    case progress(ScanProgress)
    case finishing
}

public enum ScanIssueKind: String, CaseIterable, Hashable, Sendable {
    case permissionDenied
    case itemDisappeared
    case metadataReadFailed
    case volumeBoundary
    case repeatedDirectoryIdentity
    case hardLinksOutsideRoot
}

public struct ScanIssueSample: Sendable {
    public let kind: ScanIssueKind
    public let relativePath: String
    public let code: Int32?
}

public struct ScanIssueSummary: Sendable {
    public let counts: [ScanIssueKind: UInt64]
    public let samples: [ScanIssueSample]
    public var totalCount: UInt64 { counts.values.reduce(0, +) }
}

public struct ScanResult: Sendable {
    public let rootURL: URL
    public let tree: FileTree
    public let completion: ScanCompletion
    public let accounting: ScanAccountingPolicy
    public let progress: ScanProgress
    public let issues: ScanIssueSummary
    public let startedAt: Date
    public let finishedAt: Date
}

public enum ScanError: Error, Equatable, Sendable {
    case rootMissing
    case rootIsNotDirectory
    case rootIsSymbolicLink
    case rootIsNotLocalVolume
    case rootMetadataFailed(Int32)
    case builder(FileTreeBuildError)
}

public struct ScanConfiguration: Sendable {
    public static let maximumWorkerLimit = 8
    public let workerLimit: Int
    public let retainedIssueSamples: Int
    public let progressMinimumInterval: Duration

    public init(workerLimit: Int = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)), retainedIssueSamples: Int = 256, progressMinimumInterval: Duration = .milliseconds(200)) {
        self.workerLimit = min(Self.maximumWorkerLimit, max(1, workerLimit))
        self.retainedIssueSamples = max(0, retainedIssueSamples)
        self.progressMinimumInterval = progressMinimumInterval
    }
}

public struct ScanSession: Sendable {
    public let updates: AsyncStream<ScanUpdate>
    public let result: Task<ScanResult, Error>
    private let cancellation: @Sendable () -> Void
    public init(updates: AsyncStream<ScanUpdate>, result: Task<ScanResult, Error>, cancellation: @escaping @Sendable () -> Void) {
        self.updates = updates
        self.result = result
        self.cancellation = cancellation
    }
    public func cancel() { cancellation() }
}
