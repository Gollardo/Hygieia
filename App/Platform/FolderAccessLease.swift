import Foundation

@MainActor
final class FolderAccessLease {
    let url: URL
    private var releaseAccess: (() -> Void)?

    init(url: URL, releaseAccess: @escaping () -> Void = {}) {
        self.url = url
        self.releaseAccess = releaseAccess
    }

    func release() {
        let action = releaseAccess
        releaseAccess = nil
        action?()
    }
}

struct FolderSelection {
    let url: URL
    let lease: FolderAccessLease
}
