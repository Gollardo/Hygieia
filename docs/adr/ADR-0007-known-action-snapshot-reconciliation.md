# ADR-0007: Known-action snapshot reconciliation

Status: Accepted
Date: 2026-08-31

## Context

M4 required a whole-root scan after every receipt-confirmed Trash batch. That is correct but unnecessarily rereads filesystem metadata when Hygieia already has an immutable snapshot and exact roots that macOS confirmed as moved.

## Decision

- After receipt-confirmed non-overlapping Trash moves, Hygieia builds a separate compact immutable `FileTree` from the old snapshot, excluding exactly those roots.
- The pure Domain reconciler assigns new snapshot-local `NodeID` values, reconstructs names, links, identities, subtree totals and hard-link groups, and validates the result before atomic publication.
- The feature keeps the stale overlay until publication, then drops navigation, selection, projections, marks and invalidation state exactly as for a completed replacement scan.
- Any invalid input, arithmetic/invariant failure, cancellation, or generation change publishes nothing. A failure starts one existing whole-root scan when the access lease remains available.
- This applies only to known successful Trash receipts. It is not FSEvents, arbitrary filesystem-change reconciliation, subtree scanning, or a replacement for M9.

## Alternatives Considered

- **Continue mandatory whole-root scan:** retained as fail-closed fallback, rejected as the only path because known deletions need no metadata discovery.
- **Mutate the published tree:** rejected because readers could observe inconsistent totals, links and snapshot-local IDs.
- **FSEvents or SQLite now:** rejected because neither is needed to prove a known deletion and both expand M4 scope.

## Consequences

Positive:

- successful Trash refresh no longer invokes the scanner;
- hard-link accounting is rebuilt so removal of the former canonical entry promotes a survivor safely;
- all UI state still crosses a snapshot boundary and therefore fails closed for old IDs.

Verification needs:

- reconciliation digest must be compared with a full rescan on owned fixtures before making performance claims;
- signed-sandbox Trash, volume-boundary, cancellation and large-root performance remain manual/benchmark gates;
- M9 continues to own unknown external changes and FSEvents.
