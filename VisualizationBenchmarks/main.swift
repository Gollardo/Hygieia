import Foundation
import Darwin
import HygieiaDomain
import HygieiaVisualization

@main
struct HygieiaVisualizationBenchmarks {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let dataset = arguments.first ?? "P01"
        let count = arguments.dropFirst().first.flatMap(Int.init) ?? defaultCount(for: dataset)
        do {
            let tree = try fixture(dataset: dataset, count: count)
            let request = SunburstViewportPolicy.request(
                root: tree.root,
                metric: .reportedAllocated,
                viewport: .init(width: 1_024, height: 768)
            )
            let clock = ContinuousClock()
            let start = clock.now
            let projection = try await VisualizationTreeBuilder().build(tree: tree, request: request)
            let projectionElapsed = start.duration(to: clock.now)
            let layoutStart = clock.now
            let layout = try await SunburstLayout().layout(projection: projection, viewport: .init(width: 1_024, height: 768))
            let layoutElapsed = layoutStart.duration(to: clock.now)
            let checksum = layout.segments.reduce(UInt64(0)) { partial, segment in
                partial &+ segment.value &+ UInt64(segment.projectionIndex.rawValue)
            }
            print("dataset=\(dataset) source_nodes=\(tree.count) projection_nodes=\(projection.nodes.count) segments=\(layout.segments.count) checksum=\(checksum)")
            print("projection=\(projectionElapsed) layout=\(layoutElapsed)")
        } catch {
            fputs("visualization benchmark failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func defaultCount(for dataset: String) -> Int {
        switch dataset {
        case "P01": 1
        case "P02": 271_453
        case "P03", "P04": 1_000_000
        case "P05": 250_000
        case "P06": 100_000
        case "P07": 4_096
        case "P08": 4_096
        default: 10_000
        }
    }

    private static func fixture(dataset: String, count: Int) throws -> FileTree {
        switch dataset {
        case "P02": return balancedTree(branching: 12, depth: 5)
        case "P07": return chain(max(1, count))
        case "P06": return star(count: max(1, count), logicalSize: 1, allocatedSize: 0, flags: [])
        case "P08": return star(count: max(1, count), logicalSize: 1, allocatedSize: 1, flags: [.incompleteSubtree, .package, .hardLinkAlias])
        case "P04": return skewedStar(count: max(2, count))
        case "P05": return thresholdStar(count: max(1, count))
        default: return star(count: max(1, count), logicalSize: 1, allocatedSize: 1, flags: [])
        }
    }

    private static func star(count: Int, logicalSize: UInt64, allocatedSize: UInt64, flags: NodeFlags) -> FileTree {
        var names = NameStore()
        let rootName = try! names.append("root")
        let childName = try! names.append("item")
        let totalLogical = UInt64(count) * logicalSize
        let totalAllocated = UInt64(count) * allocatedSize
        var nodes: ContiguousArray<FileNode> = [
            .init(logicalSize: totalLogical, allocatedSize: totalAllocated, parent: .invalid, firstChild: .init(rawValue: 1), name: rootName, kind: .directory),
        ]
        nodes.reserveCapacity(count + 1)
        for offset in 0..<count {
            let next = offset + 1 < count ? NodeID(rawValue: UInt32(offset + 2)) : .invalid
            nodes.append(.init(logicalSize: logicalSize, allocatedSize: allocatedSize, parent: .init(rawValue: 0), nextSibling: next, name: childName, kind: .regularFile, flags: flags))
        }
        return FileTree(root: .init(rawValue: 0), nodes: nodes, names: names)
    }

    private static func skewedStar(count: Int) -> FileTree {
        var names = NameStore()
        let rootName = try! names.append("root")
        let childName = try! names.append("item")
        let smallValue: UInt64 = 1
        let dominantValue = UInt64(count - 1) * 9
        let total = dominantValue + UInt64(count - 1) * smallValue
        var nodes: ContiguousArray<FileNode> = [
            .init(logicalSize: total, allocatedSize: total, parent: .invalid, firstChild: .init(rawValue: 1), name: rootName, kind: .directory),
        ]
        nodes.reserveCapacity(count + 1)
        for offset in 0..<count {
            let value: UInt64 = offset == 0 ? dominantValue : smallValue
            let next = offset + 1 < count ? NodeID(rawValue: UInt32(offset + 2)) : .invalid
            nodes.append(.init(logicalSize: value, allocatedSize: value, parent: .init(rawValue: 0), nextSibling: next, name: childName, kind: .regularFile))
        }
        return FileTree(root: .init(rawValue: 0), nodes: nodes, names: names)
    }

    private static func thresholdStar(count: Int) -> FileTree {
        var names = NameStore()
        let rootName = try! names.append("root")
        let childName = try! names.append("item")
        var nodes: ContiguousArray<FileNode> = [
            .init(logicalSize: UInt64(count) * 100, allocatedSize: UInt64(count) * 100, parent: .invalid, firstChild: .init(rawValue: 1), name: rootName, kind: .directory),
        ]
        nodes.reserveCapacity(count + 1)
        for offset in 0..<count {
            let value = UInt64(99 + offset % 3)
            let next = offset + 1 < count ? NodeID(rawValue: UInt32(offset + 2)) : .invalid
            nodes.append(.init(logicalSize: value, allocatedSize: value, parent: .init(rawValue: 0), nextSibling: next, name: childName, kind: .regularFile))
        }
        let actualTotal = nodes.dropFirst().reduce(UInt64(0)) { $0 + $1.logicalSize }
        nodes[0].logicalSize = actualTotal
        nodes[0].allocatedSize = actualTotal
        return FileTree(root: .init(rawValue: 0), nodes: nodes, names: names)
    }

    private static func chain(_ count: Int) -> FileTree {
        var names = NameStore()
        let directoryName = try! names.append("directory")
        var nodes: ContiguousArray<FileNode> = []
        nodes.reserveCapacity(count)
        for offset in 0..<count {
            let id = NodeID(rawValue: UInt32(offset))
            let parent: NodeID = offset == 0 ? .invalid : .init(rawValue: UInt32(offset - 1))
            let child: NodeID = offset + 1 < count ? .init(rawValue: UInt32(offset + 1)) : .invalid
            nodes.append(.init(logicalSize: 1, allocatedSize: 1, parent: parent, firstChild: child, name: directoryName, kind: .directory))
            _ = id
        }
        return FileTree(root: .init(rawValue: 0), nodes: nodes, names: names)
    }

    private static func balancedTree(branching: Int, depth: Int) -> FileTree {
        var names = NameStore()
        let directoryName = try! names.append("directory")
        let fileName = try! names.append("file")
        var nodes: ContiguousArray<FileNode> = []

        @discardableResult
        func append(level: Int, parent: NodeID) -> NodeID {
            let id = NodeID(rawValue: UInt32(nodes.count))
            let isLeaf = level == depth
            let subtreeValue = UInt64(pow(branching, depth - level))
            nodes.append(
                .init(
                    logicalSize: subtreeValue,
                    allocatedSize: subtreeValue,
                    parent: parent,
                    name: isLeaf ? fileName : directoryName,
                    kind: isLeaf ? .regularFile : .directory
                )
            )
            guard !isLeaf else { return id }
            var previous: NodeID?
            for _ in 0..<branching {
                let child = append(level: level + 1, parent: id)
                if let previous {
                    nodes[Int(previous.rawValue)].nextSibling = child
                } else {
                    nodes[Int(id.rawValue)].firstChild = child
                }
                previous = child
            }
            return id
        }

        let root = append(level: 0, parent: .invalid)
        return FileTree(root: root, nodes: nodes, names: names)
    }

    private static func pow(_ base: Int, _ exponent: Int) -> Int {
        (0..<exponent).reduce(1) { value, _ in value * base }
    }
}
