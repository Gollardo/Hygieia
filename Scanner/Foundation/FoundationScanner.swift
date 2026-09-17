import Darwin
import Foundation
import HygieiaDomain
import HygieiaScannerCore

public struct FoundationScanner: FileSystemScanner {
    private let configuration: ScanConfiguration
    private let backend: FoundationDirectoryBackend

    public init(configuration: ScanConfiguration = .init()) {
        self.configuration = configuration
        self.backend = FoundationDirectoryBackend()
    }

    public func startScan(_ request: ScanRequest) -> ScanSession {
        let pair = AsyncStream<ScanUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let cancellation = FoundationScanCancellation()
        let control = FoundationScanControl(
            request: request,
            configuration: configuration,
            backend: backend,
            continuation: pair.continuation,
            cancellation: cancellation
        )
        let task = Task { try await control.run() }
        return ScanSession(updates: pair.stream, result: task, cancellation: {
            // Set the blocking adapter's flag synchronously. Waiting for an actor
            // hop here can leave a wide directory metadata loop running needlessly.
            cancellation.cancel()
            Task { await control.cancel() }
        })
    }
}

fileprivate final class FoundationScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private actor FoundationScanControl {
    private let request: ScanRequest
    private let configuration: ScanConfiguration
    private let backend: FoundationDirectoryBackend
    private let continuation: AsyncStream<ScanUpdate>.Continuation
    private let cancellation: FoundationScanCancellation
    private var coordinator: ScanCoordinator?
    private var cancelled = false

    init(
        request: ScanRequest,
        configuration: ScanConfiguration,
        backend: FoundationDirectoryBackend,
        continuation: AsyncStream<ScanUpdate>.Continuation,
        cancellation: FoundationScanCancellation
    ) {
        self.request = request
        self.configuration = configuration
        self.backend = backend
        self.continuation = continuation
        self.cancellation = cancellation
    }

    func cancel() async {
        cancellation.cancel()
        cancelled = true
        await coordinator?.cancel()
    }

    func run() async throws -> ScanResult {
        defer { continuation.finish() }
        do {
            let root = try await backend.inspectRoot(request.rootURL)
            if let expected = request.expectedRootIdentity, expected != root.identity {
                throw ScanError.rootChanged
            }
            let coordinator = try ScanCoordinator(rootURL: request.rootURL, root: root, configuration: configuration, updates: continuation)
            self.coordinator = coordinator
            if cancelled || cancellation.isCancelled { await coordinator.cancel() }
            let cancellation = self.cancellation
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for _ in 0..<configuration.workerLimit {
                        group.addTask { [backend] in
                            while !Task.isCancelled, let lease = await coordinator.claim() {
                                let result = await backend.readDirectory(
                                    DirectoryReadRequest(workID: lease.workID, directoryURL: lease.url, expectedIdentity: lease.identity),
                                    cancellation: cancellation
                                )
                                if cancellation.isCancelled { await coordinator.cancel() }
                                try await coordinator.submit(lease, result: result)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
            } catch {
                await coordinator.cancel()
                throw error
            }
            // Do not start another filesystem call after cancellation. The partial
            // result already denies Trash and makes no claim about current coverage.
            if cancellation.isCancelled {
                await coordinator.cancel()
                return try await coordinator.finish()
            }
            let sourceAvailable = await backend.rootStillMatches(request.rootURL, identity: root.identity)
            return try await coordinator.finish(sourceUnavailable: !sourceAvailable)
        } catch let error as FileTreeBuildError {
            throw ScanError.builder(error)
        }
    }
}

public struct FoundationDirectoryBackend: DirectoryScanningBackend {
    private static let queue = DispatchQueue(label: "com.hygieia.scanner.foundation", qos: .utility, attributes: .concurrent)

    public init() {}

    public func inspectRoot(_ url: URL) async throws -> RootDirectoryRecord {
        let metadata = await readMetadata(url, packageHint: false)
        switch metadata {
        case .success(let record):
            if record.kind == .symbolicLink { throw ScanError.rootIsSymbolicLink }
            guard record.kind == .directory else { throw ScanError.rootIsNotDirectory }
            guard let identity = record.identity else { throw ScanError.rootMetadataFailed(EIO) }
            // Metadata I/O stays on the adapter queue, including locality lookup.
            let isLocal = await withCheckedContinuation { continuation in
                Self.queue.async {
                    continuation.resume(returning: try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal)
                }
            }
            guard let isLocal else { throw ScanError.rootLocalityUnknown }
            guard isLocal else { throw ScanError.rootIsNotLocalVolume }
            let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return RootDirectoryRecord(displayName: displayName, identity: identity)
        case .failure(let failure):
            switch failure {
            case .disappeared: throw ScanError.rootMissing
            case .permissionDenied(let code): throw ScanError.rootPermissionDenied(code)
            case .metadataReadFailed(let code): throw ScanError.rootMetadataFailed(code)
            }
        }
    }

    public func rootStillMatches(_ url: URL, identity: FileIdentity) async -> Bool {
        guard case .success(let record) = await readMetadata(url, packageHint: false) else { return false }
        return record.kind == .directory && record.identity == identity
    }

    public func readDirectory(_ request: DirectoryReadRequest) async -> DirectoryReadResult {
        await readDirectory(request, cancellation: nil)
    }

    fileprivate func readDirectory(
        _ request: DirectoryReadRequest,
        cancellation: FoundationScanCancellation?
    ) async -> DirectoryReadResult {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: readDirectoryBlocking(request, cancellation: cancellation))
            }
        }
    }

    private func readMetadata(_ url: URL, packageHint: Bool) async -> Result<DirectoryEntryRecord, DirectoryReadFailure> {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: metadataBlocking(url, packageHint: packageHint))
            }
        }
    }
}

private func readDirectoryBlocking(
    _ request: DirectoryReadRequest,
    cancellation: FoundationScanCancellation?
) -> DirectoryReadResult {
    if cancellation?.isCancelled == true { return .init(workID: request.workID) }
    switch metadataBlocking(request.directoryURL, packageHint: false) {
    case .success(let directory):
        guard directory.kind == .directory, directory.identity == request.expectedIdentity else {
            return DirectoryReadResult(workID: request.workID, failure: .disappeared(code: ESTALE))
        }
    case .failure(let failure):
        return DirectoryReadResult(workID: request.workID, failure: failure)
    }
    let parentFileSystem: FileSystemIdentifier
    switch fileSystemIdentifierBlocking(request.directoryURL, expectedIdentity: request.expectedIdentity) {
    case .success(let identifier): parentFileSystem = identifier
    case .failure(let failure): return .init(workID: request.workID, failure: failure)
    }
    let manager = FileManager.default
    let urls: [URL]
    do {
        // Do not prefetch URL resource keys for every child: that can resolve a
        // symbolic-link target before lstat establishes the no-follow kind.
        urls = try manager.contentsOfDirectory(at: request.directoryURL, includingPropertiesForKeys: nil, options: [])
    } catch {
        return DirectoryReadResult(workID: request.workID, failure: failure(from: error))
    }
    if cancellation?.isCancelled == true { return .init(workID: request.workID) }
    var entries: [DirectoryEntryRecord] = []
    var issues: [DirectoryEntryIssue] = []
    entries.reserveCapacity(urls.count)
    for url in urls {
        if cancellation?.isCancelled == true { return .init(workID: request.workID) }
        switch metadataBlocking(url, packageHint: false) {
        case .success(let entry):
            if entry.kind == .directory {
                if cancellation?.isCancelled == true { return .init(workID: request.workID) }
                // st_dev can be identical across the APFS System/Data firmlink view.
                // Check the actual filesystem on a no-follow directory descriptor.
                guard let identity = entry.identity else {
                    issues.append(.init(name: entry.name, failure: .metadataReadFailed(code: EIO)))
                    continue
                }
                switch fileSystemIdentifierBlocking(url, expectedIdentity: identity) {
                case .success(let childFileSystem):
                    if childFileSystem != parentFileSystem {
                        entries.append(entry.addingFlags([.volumeBoundary, .incompleteSubtree]))
                    } else {
                        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                        entries.append(isPackage ? entry.addingFlags(.package) : entry)
                    }
                case .failure(let failure):
                    issues.append(.init(name: entry.name, failure: failure))
                }
            } else {
                entries.append(entry)
            }
        case .failure(let failure): issues.append(DirectoryEntryIssue(name: url.lastPathComponent, failure: failure))
        }
    }
    return DirectoryReadResult(workID: request.workID, entries: entries, entryIssues: issues)
}

private extension DirectoryEntryRecord {
    func addingFlags(_ added: NodeFlags) -> DirectoryEntryRecord {
        var nextFlags = flags
        nextFlags.formUnion(added)
        return DirectoryEntryRecord(
            name: name,
            kind: kind,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            flags: nextFlags,
            identity: identity,
            reportedLinkCount: reportedLinkCount
        )
    }
}

private struct FileSystemIdentifier: Equatable {
    let first: Int32
    let second: Int32
}

private func fileSystemIdentifierBlocking(
    _ url: URL, expectedIdentity: FileIdentity
) -> Result<FileSystemIdentifier, DirectoryReadFailure> {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
        path.map { open($0, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
    }
    guard descriptor >= 0 else { return .failure(failure(fromErrno: errno)) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .failure(failure(fromErrno: errno)) }
    guard (info.st_mode & S_IFMT) == S_IFDIR,
          FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino)) == expectedIdentity else {
        return .failure(.disappeared(code: ESTALE))
    }
    var filesystem = statfs()
    guard fstatfs(descriptor, &filesystem) == 0 else { return .failure(failure(fromErrno: errno)) }
    return .success(.init(first: filesystem.f_fsid.val.0, second: filesystem.f_fsid.val.1))
}

private func metadataBlocking(_ url: URL, packageHint: Bool) -> Result<DirectoryEntryRecord, DirectoryReadFailure> {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return Int(lstat(path, &status))
    }
    guard result == 0 else { return .failure(failure(fromErrno: errno)) }
    let fileType = status.st_mode & S_IFMT
    let kind: NodeKind
    switch fileType {
    case S_IFREG: kind = .regularFile
    case S_IFDIR: kind = .directory
    case S_IFLNK: kind = .symbolicLink
    default: kind = .other
    }
    guard status.st_size >= 0, status.st_blocks >= 0 else { return .failure(.metadataReadFailed(code: EINVAL)) }
    let rawAllocated = UInt64(status.st_blocks).multipliedReportingOverflow(by: 512)
    guard !rawAllocated.overflow else { return .failure(.metadataReadFailed(code: EOVERFLOW)) }
    let sizes: (UInt64, UInt64)
    switch kind {
    case .regularFile: sizes = (UInt64(status.st_size), rawAllocated.partialValue)
    case .symbolicLink: sizes = (UInt64(status.st_size), 0)
    case .directory, .other: sizes = (0, 0)
    }
    var flags: NodeFlags = []
    if url.lastPathComponent.hasPrefix(".") { flags.insert(.hidden) }
    if kind == .directory, packageHint { flags.insert(.package) }
    let linkCount = UInt32(clamping: UInt64(status.st_nlink))
    let identity = FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino))
    return .success(DirectoryEntryRecord(name: url.lastPathComponent, kind: kind, logicalSize: sizes.0, allocatedSize: sizes.1, flags: flags, identity: identity, reportedLinkCount: linkCount))
}

private func failure(from error: Error) -> DirectoryReadFailure {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        switch nsError.code {
        case NSFileReadNoPermissionError:
            return .permissionDenied(code: EACCES)
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .disappeared(code: ENOENT)
        default:
            break
        }
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return failure(from: underlying)
    }
    return failure(fromErrno: Int32(nsError.code))
}

private func failure(fromErrno code: Int32) -> DirectoryReadFailure {
    switch code {
    case EACCES, EPERM: return .permissionDenied(code: code)
    case ENOENT, ESTALE: return .disappeared(code: code)
    default: return .metadataReadFailed(code: code)
    }
}
