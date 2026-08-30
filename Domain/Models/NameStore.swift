public struct NameEntry: Hashable, Sendable {
    public let offset: UInt32
    public let length: UInt32

    public init(offset: UInt32, length: UInt32) {
        self.offset = offset
        self.length = length
    }
}

public enum NameStoreError: Error, Equatable, Sendable {
    case entryCapacityExceeded
    case byteCapacityExceeded
}

/// Snapshot-local UTF-8 name slab. It intentionally does not intern names.
public struct NameStore: Sendable {
    private var bytes: ContiguousArray<UInt8>
    private var entries: ContiguousArray<NameEntry>

    public init() {
        bytes = []
        entries = []
    }

    public var count: Int { entries.count }
    public var byteCount: Int { bytes.count }

    @discardableResult
    public mutating func append(_ name: String) throws -> NameID {
        let encoded = ContiguousArray(name.utf8)
        guard entries.count < Int(UInt32.max) else { throw NameStoreError.entryCapacityExceeded }
        guard encoded.count < Int(UInt32.max) - bytes.count else { throw NameStoreError.byteCapacityExceeded }
        let id = NameID(rawValue: UInt32(entries.count))
        entries.append(NameEntry(offset: UInt32(bytes.count), length: UInt32(encoded.count)))
        bytes.append(contentsOf: encoded)
        return id
    }

    public func string(for id: NameID) -> String? {
        let index = Int(id.rawValue)
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        let start = Int(entry.offset)
        let end = start + Int(entry.length)
        guard start <= end, end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
