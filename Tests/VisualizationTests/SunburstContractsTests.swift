import XCTest
import HygieiaDomain
@testable import HygieiaVisualization

final class SunburstContractsTests: XCTestCase {
    func testOtherIdentityContainsOnlyItsParent() {
        let parent = NodeID(rawValue: 42)
        let item = SunburstItemID.other(parent: parent)

        XCTAssertEqual(item, .other(parent: parent))
        XCTAssertNotEqual(item, .node(parent))
    }

    func testViewportPolicyShowsOnlyDirectChildrenAtEveryUsableSize() {
        XCTAssertEqual(SunburstViewportPolicy.budget(for: .init(width: 100, height: 100)).maximumDepth, 0)
        XCTAssertEqual(SunburstViewportPolicy.budget(for: .init(width: 400, height: 400)).maximumDepth, 1)
        XCTAssertEqual(SunburstViewportPolicy.budget(for: .init(width: 700, height: 700)).maximumDepth, 1)
        XCTAssertEqual(SunburstViewportPolicy.budget(for: .init(width: 1_200, height: 1_200)).maximumDepth, 1)
    }

    func testProjectionContractsPreserveExactValuesAndLinks() {
        let root = NodeID(rawValue: 0)
        let node = ProjectionNode(
            item: .node(root),
            parent: nil,
            firstChild: .init(rawValue: 1),
            nextSibling: nil,
            value: UInt64.max,
            aggregatedDirectChildCount: 0,
            zeroValueDirectChildCount: 2,
            hiddenPositiveDirectChildCount: 3,
            hiddenPositiveDirectChildValue: UInt64.max - 1,
            depth: 0,
            flags: [.incompleteSource, .childrenHiddenByBudget]
        )
        let summary = ProjectionSummary(
            visitedSourceNodeCount: 8,
            representedRealNodeCount: 3,
            otherNodeCount: 1,
            observedZeroValueNodeCount: 2,
            observedHiddenPositiveNodeCount: 3,
            observedHiddenPositiveValue: UInt64.max - 1,
            hasDepthLimitedBranches: false,
            hasBudgetLimitedBranches: true
        )
        let projection = SunburstProjection(
            sourceRoot: root,
            metric: .reportedAllocated,
            nodes: [node],
            summary: summary
        )

        XCTAssertEqual(projection.nodes[0], node)
        XCTAssertEqual(projection.nodes[0].firstChild?.rawValue, 1)
        XCTAssertEqual(projection.summary, summary)
        XCTAssertTrue(projection.nodes[0].flags.contains(.incompleteSource))
        XCTAssertTrue(projection.nodes[0].flags.contains(.childrenHiddenByBudget))
    }

    func testLayoutContractsKeepRootOutOfSegmentsAndUseTypedIndices() {
        let root = NodeID(rawValue: 0)
        let segment = SunburstSegment(
            item: .node(NodeID(rawValue: 1)),
            projectionIndex: .init(rawValue: 1),
            parentSegment: nil,
            value: 100,
            depth: 1,
            startAngle: 0,
            endAngle: .pi,
            innerRadius: 44,
            outerRadius: 72
        )
        let layout = SunburstLayoutResult(
            sourceRoot: root,
            viewport: .init(width: 640, height: 480),
            centerRadius: 44,
            outerRadius: 228,
            segments: [segment],
            ringRanges: [0..<0, 0..<1],
            nodeSegmentsByNodeID: [.init(node: NodeID(rawValue: 1), segment: .init(rawValue: 0))]
        )

        XCTAssertEqual(layout.segments.count, 1)
        XCTAssertEqual(layout.ringRanges[0], 0..<0)
        XCTAssertEqual(layout.nodeSegmentsByNodeID[0].segment.rawValue, 0)
        XCTAssertEqual(SunburstHit.center(root), .center(root))
    }

    func testFixtureBuilderPreservesPreorderAndSiblingOrder() throws {
        let tree = try VisualizationFixtureBuilder.build(
            root: .directory(
                "root",
                logicalSize: 30,
                allocatedSize: 20,
                children: [
                    .init(name: "alpha", logicalSize: 10, allocatedSize: 8),
                    .directory(
                        "beta",
                        logicalSize: 20,
                        allocatedSize: 12,
                        flags: [.incompleteSubtree],
                        children: [.init(name: "gamma", logicalSize: 20, allocatedSize: 12)]
                    ),
                ]
            )
        )

        XCTAssertEqual(tree.count, 4)
        XCTAssertEqual(Array(tree.children(of: tree.root)), [.init(rawValue: 1), .init(rawValue: 2)])
        XCTAssertEqual(tree.pathComponents(to: .init(rawValue: 3)), ["root", "beta", "gamma"])
        XCTAssertTrue(tree[.init(rawValue: 2)].flags.contains(.incompleteSubtree))
    }

    func testFixtureBuilderRejectsInvalidFixtureShape() {
        XCTAssertThrowsError(
            try VisualizationFixtureBuilder.build(
                root: .directory(
                    "root",
                    logicalSize: 0,
                    allocatedSize: 0,
                    children: [.init(name: "file", logicalSize: 0, allocatedSize: 0, children: [.init(name: "invalid", logicalSize: 0, allocatedSize: 0)])]
                )
            )
        ) { error in
            XCTAssertEqual(error as? VisualizationFixtureBuilder.Error, .childrenOnNonDirectory(name: "file"))
        }
    }
}
