/// Index into the snapshot-local UTF-8 name store.
public struct NameID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static func < (lhs: NameID, rhs: NameID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
