import HygieiaDomain

struct LargestItemRow: Identifiable, Hashable, Sendable {
    let id: NodeID
    let name: String
    let relativePath: String
    let kind: NodeKind
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let flags: NodeFlags

    func size(for metric: SizeMetric) -> UInt64 {
        switch metric {
        case .reportedAllocated: allocatedSize
        case .logical: logicalSize
        }
    }
}
