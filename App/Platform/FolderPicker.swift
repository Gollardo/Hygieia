import AppKit

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
            panel.begin { response in
                let url = Self.resolvedSelectionURL(selectedURL: panel.url, acceptedSelection: response == .OK)
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

    nonisolated static func resolvedSelectionURL(selectedURL: URL?, acceptedSelection: Bool) -> URL? {
        // Cancellation and directoryURL are not evidence of a Powerbox grant.
        acceptedSelection ? selectedURL : nil
    }
}
