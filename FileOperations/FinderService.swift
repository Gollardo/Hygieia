/// macOS integration boundary. Concrete AppKit/Foundation behavior belongs in an adapter.
@MainActor
public protocol FinderService: Sendable {
    func reveal(_ target: ValidatedFileActionTarget)
}
