import Foundation
import HygieiaDomain

public struct TrashReceipt: Sendable {
    public let originalURL: URL
    public let resultingURL: URL?
    public let movedIdentity: FileIdentity
    public let completedAt: ContinuousClock.Instant

    public init(originalURL: URL, resultingURL: URL?, movedIdentity: FileIdentity, completedAt: ContinuousClock.Instant) {
        self.originalURL = originalURL
        self.resultingURL = resultingURL
        self.movedIdentity = movedIdentity
        self.completedAt = completedAt
    }
}

/// The only deletion boundary in the initial product. Permanent delete is intentionally absent.
public protocol TrashService: Sendable {
    func moveToTrash(_ target: SnapshotFileActionTarget) async throws -> TrashReceipt
}
