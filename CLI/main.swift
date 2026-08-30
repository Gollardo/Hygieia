import Foundation
import HygieiaDomain
import HygieiaScannerCore
import HygieiaFoundationScanner

@main
struct HygieiaCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw CLIError.usage }
            switch command {
            case "scan": try await scan(arguments: Array(arguments.dropFirst()))
            case "benchmark": try await benchmark(arguments: Array(arguments.dropFirst()))
            case "help", "--help", "-h": print(usage)
            default: throw CLIError.usage
            }
        } catch {
            fputs("hygieia: \(error)\n\n\(usage)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func scan(arguments: [String]) async throws {
        let options = try Options(arguments)
        let configuration = ScanConfiguration(workerLimit: options.workers ?? min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        let result = try await FoundationScanner(configuration: configuration).startScan(.init(rootURL: options.url)).result.value
        let report = Report(result: result, top: options.top, includeRoot: false)
        if options.json { try printJSON(report) } else { printHuman(report) }
    }

    private static func benchmark(arguments: [String]) async throws {
        let options = try Options(arguments)
        let start = ContinuousClock.now
        let configuration = ScanConfiguration(workerLimit: options.workers ?? min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
        let result = try await FoundationScanner(configuration: configuration).startScan(.init(rootURL: options.url)).result.value
        let elapsed = start.duration(to: .now)
        let report = BenchmarkReport(result: result, elapsed: elapsed, workers: configuration.workerLimit)
        try printJSON(report)
    }

    private static func printHuman(_ report: Report) {
        print("Scan \(report.completion): \(report.nodeCount) nodes")
        print("logical \(report.logicalSize) B; reported allocated \(report.allocatedSize) B")
        print("\(report.accounting)")
        if report.hardLinkGroups > 0 { print("Warning: \(report.hardLinkGroups) hard-link groups are accounted once; this is not reclaimable-space accounting.") }
        if report.issueCount > 0 { print("Coverage incomplete: \(report.issueCount) recoverable issues.") }
        for item in report.top { print("\(item.logicalSize)\t\(item.allocatedSize)\t\(item.path)") }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static let usage = "Usage: hygieia scan <directory> [--top N] [--workers N] [--json]\n       hygieia benchmark <directory> [--workers N]"
}

private enum CLIError: Error { case usage; case missingDirectory; case invalidOption(String) }

private struct Options {
    let url: URL
    let top: Int
    let workers: Int?
    let json: Bool

    init(_ arguments: [String]) throws {
        guard let path = arguments.first, !path.hasPrefix("-") else { throw CLIError.missingDirectory }
        var top = 20
        var workers: Int?
        var json = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--top":
                index += 1; guard index < arguments.count, let value = Int(arguments[index]), value > 0 else { throw CLIError.invalidOption("--top") }; top = value
            case "--workers":
                index += 1; guard index < arguments.count, let value = Int(arguments[index]), (1...ScanConfiguration.maximumWorkerLimit).contains(value) else { throw CLIError.invalidOption("--workers (expected 1...\(ScanConfiguration.maximumWorkerLimit))") }; workers = value
            case "--json": json = true
            default: throw CLIError.invalidOption(arguments[index])
            }
            index += 1
        }
        self.url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        self.top = top
        self.workers = workers
        self.json = json
    }
}

private struct Report: Encodable {
    struct Item: Encodable { let path: String; let logicalSize: UInt64; let allocatedSize: UInt64; let kind: String }
    let completion: String
    let nodeCount: Int
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let issueCount: UInt64
    let hardLinkGroups: Int
    let accounting: String
    let top: [Item]

    init(result: ScanResult, top: Int, includeRoot: Bool) {
        let root = result.tree[result.tree.root]
        var items: [Item] = []
        for raw in 0..<result.tree.count {
            let id = NodeID(rawValue: UInt32(raw))
            if !includeRoot && id == result.tree.root { continue }
            let node = result.tree[id]
            let components = result.tree.pathComponents(to: id)
            let path = components.dropFirst().joined(separator: "/")
            items.append(Item(path: path.isEmpty ? "." : path, logicalSize: node.logicalSize, allocatedSize: node.allocatedSize, kind: String(describing: node.kind)))
        }
        self.completion = result.completion.rawValue
        self.nodeCount = result.tree.count
        self.logicalSize = root.logicalSize
        self.allocatedSize = root.allocatedSize
        self.issueCount = result.issues.totalCount
        self.hardLinkGroups = result.tree.hardLinkGroupCount
        self.accounting = result.accounting.description
        self.top = items.sorted { lhs, rhs in lhs.logicalSize == rhs.logicalSize ? lhs.path < rhs.path : lhs.logicalSize > rhs.logicalSize }.prefix(top).map { $0 }
    }
}

private struct BenchmarkReport: Encodable {
    let mode = "foundation-shallow"
    let nodes: Int
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let hardLinkGroups: Int
    let issueCount: UInt64
    let completion: String
    let workers: Int
    let wallMilliseconds: Double
    let processorCount: Int
    let osVersion: String

    init(result: ScanResult, elapsed: Duration, workers: Int) {
        let root = result.tree[result.tree.root]
        self.nodes = result.tree.count
        self.logicalSize = root.logicalSize
        self.allocatedSize = root.allocatedSize
        self.hardLinkGroups = result.tree.hardLinkGroupCount
        self.issueCount = result.issues.totalCount
        self.completion = result.completion.rawValue
        self.workers = workers
        self.wallMilliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        self.processorCount = ProcessInfo.processInfo.activeProcessorCount
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    }
}
