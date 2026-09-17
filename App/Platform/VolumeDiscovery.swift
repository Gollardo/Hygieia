import Foundation

struct ScanVolume: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let totalCapacity: UInt64?
    let availableCapacity: UInt64?
    let isInternal: Bool
    let isRemovable: Bool

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
    func discoverLocalVolumes() async throws -> VolumeDiscoverySnapshot {
        try await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
                .volumeIsInternalKey, .volumeIsRemovableKey,
            ]
            guard let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]
            ) else { throw VolumeDiscoveryError.unavailable }

            var unreadable = 0
            var volumes: [ScanVolume] = []
            var seen: Set<String> = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: keys),
                      let isLocal = values.volumeIsLocal else {
                    unreadable += 1
                    continue
                }
                guard isLocal, values.volumeIsBrowsable != false else { continue }
                let path = url.standardizedFileURL.path
                // The mount path disambiguates simultaneous mounts of the same volume.
                let identifier = (values.volumeUUIDString ?? "unknown") + ":" + path
                guard seen.insert(identifier).inserted else { continue }
                let name = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
                volumes.append(ScanVolume(
                    id: identifier, url: url,
                    name: name.flatMap { $0.isEmpty ? nil : $0 } ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent),
                    totalCapacity: values.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    availableCapacity: values.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil },
                    isInternal: values.volumeIsInternal ?? false,
                    isRemovable: values.volumeIsRemovable ?? false
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
