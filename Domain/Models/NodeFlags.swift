public struct NodeFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let package = NodeFlags(rawValue: 1 << 0)
    public static let hidden = NodeFlags(rawValue: 1 << 1)
    public static let inaccessible = NodeFlags(rawValue: 1 << 2)
    public static let incompleteSubtree = NodeFlags(rawValue: 1 << 3)
    public static let hardLink = NodeFlags(rawValue: 1 << 4)
    public static let hardLinkAlias = NodeFlags(rawValue: 1 << 5)
    public static let volumeBoundary = NodeFlags(rawValue: 1 << 6)
    public static let compressedHint = NodeFlags(rawValue: 1 << 7)
}
