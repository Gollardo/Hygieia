# ADR-0004: Bounded renderer-independent Sunburst pipeline

Status: Accepted
Date: 2026-08-30

## Context

M3 must visualize an immutable `FileTree` that can contain millions of nodes. A sector per node would make projection memory, SwiftUI identity, rendering and hit testing scale with the entire snapshot. Geometry-dependent aggregation is necessary, but virtual UI nodes must not leak into Domain or become a second source of truth.

SwiftUI `Canvas` is appropriate for immediate-mode drawing, but its drawn elements do not automatically provide individual interaction or accessibility. Pointer hit testing and an accessible representation therefore need explicit contracts. M2 already establishes one MainActor feature-state owner per window and off-main bounded projections.

## Decision

- Add a `HygieiaVisualization` SwiftPM library depending only on `HygieiaDomain`.
- Keep projection, radial layout and hit testing pure, deterministic, `Sendable` and renderer-independent. The module does not import SwiftUI/AppKit or depend on Scanner/Features.
- Build a flat bounded `SunburstProjection`; the initial hard cap is 2048 nodes including root and virtual nodes.
- Aggregate omitted positive siblings into at most one leaf `Other` per represented parent. Its identity is the parent `NodeID`; count/value are data, not identity. Virtual nodes never enter `FileTree`.
- Keep Canvas rendering, gestures, tooltip, keyboard and synthetic accessibility representation in the app/Explorer feature.
- Use one shared window selection widened from `NodeID?` to real-or-virtual `ExplorerSelection?`. Renderer state never owns selection independently.
- Rebuild projection only when snapshot, visible root, metric or quantized viewport budget class changes. Exact resize relayout and hit testing operate on bounded projection/layout data.
- Drill-down changes `visibleRoot` and navigation history within the current immutable snapshot; it never starts a scan.
- Treat initial geometry thresholds and cap as measured/tunable policy, while bounded output, separation of layers and `Other` semantics are architectural invariants.

The exact contracts, algorithms, tests and benchmark gates are specified in `docs/M3_SUNBURST_MVP.md`.

## Alternatives Considered

- **One SwiftUI shape/view per `FileTree` node:** rejected because view identity and layout would scale with millions of nodes and cannot enforce a safe render budget.
- **Canvas reads `FileTree` and computes sectors in its renderer closure:** rejected because rendering would own data traversal, repeat work during redraw and become difficult to test deterministically.
- **Put `Other` into Domain/FileTree:** rejected because it is viewport/metric-dependent presentation data, not a filesystem object.
- **Include aggregated count in `Other` identity:** rejected because normal resize/threshold changes would unnecessarily invalidate selection and accessibility identity.
- **Use Swift Charts or a third-party chart library:** rejected because radial partition layout, aggregation and hit testing need application-specific control; no dependency is justified.
- **Use recursive reference-type projection nodes:** rejected; the projection is small but flat values align with ownership, Sendable and deterministic indexing without creating a second object graph.
- **Rebuild projection on every resize event:** rejected because a wide visible root can require reading millions of direct children even though only radii changed.
- **Make `Other` drillable:** rejected for M3 because it has no single filesystem identity and would require storing/recomputing an omitted-membership view with additional product semantics.
- **Introduce a second observable Explorer model:** rejected for M3; it would create synchronization/lifecycle work without displacing the single per-window owner established in ADR-0003.
- **Enable asynchronous Canvas rendering by default:** rejected until measurement proves benefit without unacceptable hover/selection latency.

## Consequences

Positive:

- projection/output/render work is bounded independently of `FileTree.count`;
- core geometry and boundary behavior can be exhaustively unit tested without SwiftUI;
- hover and hit testing do not traverse the source tree;
- drill-down is fast conceptually and cannot accidentally rescan the filesystem;
- virtual identity, list/chart/details synchronization and accessibility behavior are explicit;
- future renderer changes do not alter Domain or scanner.

Negative/limitations:

- creating a projection for a new million-wide root still must inspect its direct children to choose the largest correctly;
- quantized budget classes trade some geometry optimality for avoiding repeated full-tree traversal during resize;
- `Other` explains omitted siblings but cannot be opened in M3;
- the feature model gains navigation/projection lifecycle state and a wider selection type;
- Canvas requires a separate accessibility representation;
- initial thresholds and animation policy require real Apple Silicon UX/performance validation.

M4 and later snapshot reconciliation must treat `NodeID`, `Other` identity and navigation history as snapshot-local.
