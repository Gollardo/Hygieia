import XCTest
import HygieiaDomain
@testable import HygieiaVisualization

final class VisualizationPipelineTests: XCTestCase {
    func testProjectionOrdersTiesByAscendingNodeIDAndPreservesExactValues() async throws {
        let tree = try VisualizationFixtureBuilder.build(
            root: .directory(
                "root",
                logicalSize: 100,
                allocatedSize: 100,
                children: [
                    .init(name: "first", logicalSize: 50, allocatedSize: 50),
                    .init(name: "second", logicalSize: 50, allocatedSize: 50),
                ]
            )
        )
        let projection = try await VisualizationTreeBuilder().build(
            tree: tree,
            request: .init(root: tree.root, metric: .logical, maximumDepth: 1, maximumNodeCount: 3, minimumAngularSpanByDepth: [0.01])
        )

        XCTAssertEqual(projection.nodes.map(\.item), [.node(.init(rawValue: 0)), .node(.init(rawValue: 1)), .node(.init(rawValue: 2))])
        XCTAssertEqual(projection.nodes.map(\.value), [100, 50, 50])
        XCTAssertEqual(projection.nodes[0].firstChild, .init(rawValue: 1))
        XCTAssertEqual(projection.nodes[1].nextSibling, .init(rawValue: 2))
    }

    func testProjectionAggregatesOmittedSiblingsIntoStableOtherIdentity() async throws {
        let tree = try VisualizationFixtureBuilder.build(
            root: .directory(
                "root",
                logicalSize: 100,
                allocatedSize: 100,
                children: [
                    .init(name: "large", logicalSize: 60, allocatedSize: 60),
                    .init(name: "medium", logicalSize: 20, allocatedSize: 20),
                    .init(name: "small-a", logicalSize: 10, allocatedSize: 10),
                    .init(name: "small-b", logicalSize: 10, allocatedSize: 10),
                ]
            )
        )
        let projection = try await VisualizationTreeBuilder().build(
            tree: tree,
            request: .init(root: tree.root, metric: .logical, maximumDepth: 1, maximumNodeCount: 3, minimumAngularSpanByDepth: [0.01])
        )

        XCTAssertEqual(projection.nodes.count, 3)
        XCTAssertEqual(projection.nodes[1].item, .node(.init(rawValue: 1)))
        XCTAssertEqual(projection.nodes[2].item, .other(parent: tree.root))
        XCTAssertEqual(projection.nodes[2].value, 40)
        XCTAssertEqual(projection.nodes[2].aggregatedDirectChildCount, 3)
        XCTAssertEqual(projection.summary.otherNodeCount, 1)
    }

    func testProjectionFailsClosedForAccountingMismatch() async throws {
        let tree = try VisualizationFixtureBuilder.build(
            root: .directory(
                "root",
                logicalSize: 99,
                allocatedSize: 99,
                children: [.init(name: "child", logicalSize: 100, allocatedSize: 100)]
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await VisualizationTreeBuilder().build(
                tree: tree,
                request: .init(root: tree.root, metric: .logical, maximumDepth: 1, maximumNodeCount: 3, minimumAngularSpanByDepth: [0.01])
            )
        ) { error in
            XCTAssertEqual(error as? SunburstProjectionError, .inconsistentAccounting(parent: tree.root))
        }
    }

    func testLayoutAndHitTestingUseHalfOpenBoundaries() async throws {
        let tree = try VisualizationFixtureBuilder.build(
            root: .directory(
                "root",
                logicalSize: 100,
                allocatedSize: 100,
                children: [
                    .init(name: "left", logicalSize: 50, allocatedSize: 50),
                    .init(name: "right", logicalSize: 50, allocatedSize: 50),
                ]
            )
        )
        let projection = try await VisualizationTreeBuilder().build(
            tree: tree,
            request: .init(root: tree.root, metric: .logical, maximumDepth: 1, maximumNodeCount: 3, minimumAngularSpanByDepth: [0.01])
        )
        let layout = try await SunburstLayout().layout(projection: projection, viewport: .init(width: 600, height: 600))
        let radius = (layout.segments[0].innerRadius + layout.segments[0].outerRadius) / 2
        let centerX = layout.viewport.width / 2
        let centerY = layout.viewport.height / 2

        XCTAssertEqual(SunburstHitTester.hitTest(layout: layout, x: centerX, y: centerY), .center(tree.root))
        XCTAssertEqual(SunburstHitTester.hitTest(layout: layout, x: centerX, y: centerY - radius), .segment(.init(rawValue: 0)))
        XCTAssertEqual(SunburstHitTester.hitTest(layout: layout, x: centerX + radius, y: centerY), .segment(.init(rawValue: 0)))
        XCTAssertNil(SunburstHitTester.hitTest(layout: layout, x: -1, y: -1))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
