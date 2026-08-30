/// Snapshot-local index into `FileTree` contiguous node storage.
/// It is not a persistent filesystem identity.
public struct NodeID: RawRepresentable, Hashable, Comparable, Sendable {
    public static let invalid = NodeID(rawValue: .max)

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public var isValid: Bool {
        self != .invalid
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
