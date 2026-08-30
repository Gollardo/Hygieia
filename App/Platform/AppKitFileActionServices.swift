import AppKit
import HygieiaFileOperations

@MainActor
final class AppKitFinderService: FinderService {
    func reveal(_ target: ValidatedFileActionTarget) {
        NSWorkspace.shared.activateFileViewerSelecting([target.itemURL])
    }
}

@MainActor
final class AppKitTrashService: TrashService {
    private let validator: any FileActionTargetValidating

    init(validator: any FileActionTargetValidating = NoFollowFileActionTargetValidator()) {
        self.validator = validator
    }

    func moveToTrash(_ target: SnapshotFileActionTarget) async throws -> TrashReceipt {
        let validated = try await validator.validate(target)
        let mapping: [URL: URL] = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([validated.itemURL]) { newURLs, error in
                if let error {
                    continuation.resume(throwing: FileActionError.system(domain: (error as NSError).domain, code: (error as NSError).code))
                } else {
                    continuation.resume(returning: newURLs)
                }
            }
        }
        guard let resultingURL = mapping[validated.itemURL] else {
            throw FileActionError.trashUnavailable(code: nil)
        }
        return .init(
            originalURL: validated.itemURL,
            resultingURL: resultingURL,
            movedIdentity: validated.validatedIdentity,
            completedAt: ContinuousClock().now
        )
    }
}
