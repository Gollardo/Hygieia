import AppKit

struct ScanVolume: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let totalCapacity: UInt64
    let availableCapacity: UInt64
    let isInternal: Bool
    let isRemovable: Bool

    var usedCapacity: UInt64 {
        totalCapacity - min(totalCapacity, availableCapacity)
    }
}

protocol VolumeDiscovering: Sendable {
    func discoverLocalVolumes() async -> [ScanVolume]
}

struct FoundationVolumeDiscovery: VolumeDiscovering {
    func discoverLocalVolumes() async -> [ScanVolume] {
        await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .volumeNameKey,
                .volumeUUIDStringKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeIsLocalKey,
                .volumeIsBrowsableKey,
                .volumeIsInternalKey,
                .volumeIsRemovableKey,
            ]
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(keys),
                options: [.skipHiddenVolumes]
            ) ?? []

            return urls.compactMap { url -> ScanVolume? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.volumeIsLocal == true,
                      values.volumeIsBrowsable != false else { return nil }

                let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
                let importantAvailable = values.volumeAvailableCapacityForImportantUsage
                    .map { UInt64(max(0, $0)) }
                let ordinaryAvailable = values.volumeAvailableCapacity
                    .map { UInt64(max(0, $0)) }
                let available = importantAvailable ?? ordinaryAvailable ?? 0
                let name = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName: String
                if let name, !name.isEmpty {
                    displayName = name
                } else {
                    displayName = url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
                }
                let identifier = values.volumeUUIDString ?? url.standardizedFileURL.path

                return ScanVolume(
                    id: identifier,
                    url: url,
                    name: displayName,
                    totalCapacity: total,
                    availableCapacity: available,
                    isInternal: values.volumeIsInternal ?? false,
                    isRemovable: values.volumeIsRemovable ?? false
                )
            }
            .sorted { lhs, rhs in
                if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
                if lhs.isRemovable != rhs.isRemovable { return !lhs.isRemovable && rhs.isRemovable }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }.value
    }
}

@MainActor
protocol FolderPicking {
    func chooseFolder(startingAt initialDirectory: URL?, prompt: String) async -> FolderSelection?
}

extension FolderPicking {
    func chooseFolder() async -> FolderSelection? {
        await chooseFolder(startingAt: nil, prompt: "Choose")
    }
}

@MainActor
final class AppKitFolderPicker: FolderPicking {
    func chooseFolder(startingAt initialDirectory: URL?, prompt: String) async -> FolderSelection? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = initialDirectory
            panel.prompt = prompt
            if let initialDirectory {
                let sourceName = initialDirectory.lastPathComponent.isEmpty ? "this disk" : initialDirectory.lastPathComponent
                panel.message = "Scan \(sourceName) itself, or open a folder inside it."
            }
            let currentFolderAccessory = CurrentFolderAccessory(panel: panel)
            panel.accessoryView = currentFolderAccessory.view
            panel.isAccessoryViewDisclosed = true
            panel.begin { response in
                let url = Self.resolvedSelectionURL(
                    selectedURL: panel.url,
                    currentDirectoryURL: panel.directoryURL,
                    choseCurrentFolder: currentFolderAccessory.didChooseCurrentFolder,
                    acceptedSelection: response == .OK
                )
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                // The open panel already grants this selection's Powerbox access. Do not
                // manufacture another security scope from the returned URL: that policy is
                // reserved for a future bookmark-resolution flow.
                continuation.resume(returning: FolderSelection(url: url, lease: FolderAccessLease(url: url)))
            }
        }
    }

    nonisolated static func resolvedSelectionURL(
        selectedURL: URL?,
        currentDirectoryURL: URL?,
        choseCurrentFolder: Bool,
        acceptedSelection: Bool
    ) -> URL? {
        if choseCurrentFolder {
            // In column view NSOpenPanel can display a folder's contents while
            // directoryURL still names its parent. Prefer the selected directory.
            return selectedURL ?? currentDirectoryURL
        }
        return acceptedSelection ? selectedURL : nil
    }
}

@MainActor
private final class CurrentFolderAccessory: NSObject {
    let view: NSView
    private weak var panel: NSOpenPanel?
    private(set) var didChooseCurrentFolder = false

    init(panel: NSOpenPanel) {
        self.panel = panel

        let button = NSButton(title: "Scan This Folder", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 168, height: 40))
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])

        view = container
        super.init()
        button.target = self
        button.action = #selector(chooseCurrentFolder)
    }

    @objc private func chooseCurrentFolder() {
        didChooseCurrentFolder = true
        panel?.cancel(nil)
    }
}
