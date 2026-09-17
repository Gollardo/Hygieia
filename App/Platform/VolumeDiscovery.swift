import Foundation
import Darwin
import HygieiaDomain

struct ScanVolume: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let totalCapacity: UInt64?
    let availableCapacity: UInt64?
    let isInternal: Bool
    let isRemovable: Bool
    var rootIdentity: FileIdentity? = nil

    var usedFraction: Double? {
        guard let totalCapacity, totalCapacity > 0,
              let availableCapacity, availableCapacity <= totalCapacity else { return nil }
        return Double(totalCapacity - availableCapacity) / Double(totalCapacity)
    }

    var capacityDescription: String {
        guard let totalCapacity, let availableCapacity,
              availableCapacity <= totalCapacity else { return "Capacity unavailable" }
        return "\(byteCount(availableCapacity)) available of \(byteCount(totalCapacity))"
    }
}

struct VolumeDiscoverySnapshot: Sendable {
    let volumes: [ScanVolume]
    let unreadableVolumeCount: Int

    init(volumes: [ScanVolume], unreadableVolumeCount: Int = 0) {
        self.volumes = volumes
        self.unreadableVolumeCount = unreadableVolumeCount
    }
}

enum VolumeDiscoveryError: Error { case unavailable }

protocol VolumeDiscovering: Sendable {
    func discoverLocalVolumes() async throws -> VolumeDiscoverySnapshot
}

struct FoundationVolumeDiscovery: VolumeDiscovering {
    static func includesMount(path: String, browsable: Bool) -> Bool {
        if path == "/" || path == "/System/Volumes/Data" { return true }
        if path.hasPrefix("/System/Volumes/") { return false }
        return browsable
    }

    private static func identity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { lstat($0, &info) } ?? -1
        }) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return .init(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    private static func isMountedRoot(_ url: URL) throws -> Bool {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw VolumeDiscoveryError.unavailable
        }
        defer { close(descriptor) }
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw VolumeDiscoveryError.unavailable }
        let mountPath = withUnsafeBytes(of: info.f_mntonname) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return mountPath == url.path && (info.f_flags & UInt32(MNT_LOCAL)) != 0
    }

    func discoverLocalVolumes() async throws -> VolumeDiscoverySnapshot {
        try await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
                .volumeIsInternalKey, .volumeIsRemovableKey,
            ]
            guard var urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: []
            ) else { throw VolumeDiscoveryError.unavailable }

            var unreadable = 0
            // Foundation can hide the boot Data mount even without skipHiddenVolumes.
            // Add it only after a no-follow descriptor confirms the exact local mount.
            let dataRoot = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
            if !urls.contains(where: { $0.standardizedFileURL == dataRoot }) {
                do { if try Self.isMountedRoot(dataRoot) { urls.append(dataRoot) } }
                catch { unreadable += 1 }
            }
            var volumes: [ScanVolume] = []
            var seen: Set<String> = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys),
                      let isLocal = values.volumeIsLocal else {
                    unreadable += 1
                    continue
                }
                guard isLocal else { continue }
                let path = url.standardizedFileURL.path
                if values.volumeIsBrowsable == nil, path != "/", path != "/System/Volumes/Data" {
                    unreadable += 1
                    continue
                }
                guard Self.includesMount(path: path, browsable: values.volumeIsBrowsable == true) else { continue }
                // The mount path disambiguates simultaneous mounts of the same volume.
                let identifier = (values.volumeUUIDString ?? "unknown") + ":" + path
                guard seen.insert(identifier).inserted else { continue }
                let rawName = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseName = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
                let name = baseName + (path == "/System/Volumes/Data" ? " — Data" : path == "/" ? " — Boot root" : "")
                volumes.append(ScanVolume(
                    id: identifier, url: url,
                    name: name,
                    totalCapacity: values.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    availableCapacity: values.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    isInternal: values.volumeIsInternal ?? false,
                    isRemovable: values.volumeIsRemovable ?? true,
                    rootIdentity: Self.identity(at: url)
                ))
            }
            volumes.sort { lhs, rhs in
                if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
                if lhs.isRemovable != rhs.isRemovable { return !lhs.isRemovable && rhs.isRemovable }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return VolumeDiscoverySnapshot(volumes: volumes, unreadableVolumeCount: unreadable)
        }.value
    }
}
