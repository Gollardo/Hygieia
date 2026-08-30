# ADR-0002: M1 scanner core contracts

Status: Accepted
Date: 2026-08-30

## Context

M0 intentionally left mutable tree construction, scanner batching, package traversal and hard-link semantics open. The provisional scanner stub lets a backend assign `NodeID`, exposes per-node batches publicly and offers a boolean symlink-follow option. Those choices blur ownership, make accidental unsafe traversal possible and make progressive snapshots expensive through Swift COW storage.

M1 needs one directory scanner that is correct before optimisation, supports cancellation and can scale to millions of nodes without a Task or reference object per entry.

## Decision

- `NodeID`/`NameID` remain `UInt32`; `FileNode` is a compact flat value with inclusive accounted logical/allocated totals and an arm64 stride target of 40 bytes.
- Names use a UTF-8 slab plus 8-byte entries; full paths are reconstructed on demand.
- Hard-link metadata is sparse. Regular files are grouped by `(st_dev, st_ino)`, represented by separate nodes, and accounted once at a deterministic canonical relative path. This is not reclaimable-space semantics.
- `FileTreeBuilder` is non-Sendable and owned by one `ScanCoordinator` actor.
- A fixed number of long-lived workers perform shallow directory reads. Backend results cross the actor boundary in batches; backend never assigns node IDs.
- Blocking Foundation reads execute on a dedicated utility dispatch queue behind continuations, with at most one outstanding I/O block per worker; Swift cooperative executor is not intentionally blocked.
- Public scan lifecycle returns coalesced progress plus one final complete/cancelled `ScanResult`. A cancelled result contains a valid partial tree; live full-tree publication is deferred.
- Symbolic links are recorded and never followed. A symlink root is rejected. Cross-volume directories are recorded but not traversed in M1.
- Package directories are always scanned and marked; treating a package as one visual object belongs to projection/UI.
- Foundation shallow enumeration is the M1 backend. Its whole-directory array allocation is a measured limitation, not described as fixed-size batching.

The exact implementation specification is `docs/M1_SCANNER_CORE.md`.

## Alternatives Considered

- **Backend assigns `NodeID`:** rejected because identity/order and tree invariants belong to the single builder owner.
- **Deep `FileManager.DirectoryEnumerator`:** rejected because it hides scheduling, cancellation and package/volume boundaries from the coordinator.
- **Task per directory with a semaphore:** rejected even when concurrently bounded; task creation still scales with directory count.
- **Publish immutable `FileTree` checkpoints during scan:** rejected for M1 because continued mutation triggers large COW copies or unsafe shared mutation.
- **Count every hard-link name at full size:** simple, but overstates root totals.
- **Remove hard-link aliases from the tree:** rejected because directory entries and navigation would be incomplete.
- **Treat packages as leaves:** rejected because scanner could not know their descendant size.
- **Follow symlinks within root:** deferred; containment and loop policy add risk without M1 product need.

## Consequences

Positive:

- one explicit owner preserves tree invariants;
- task count and concurrent filesystem calls are structurally bounded;
- symlink traversal is fail-safe;
- hard-link root totals are not multiplied by aliases;
- packages retain correct descendant accounting;
- cancelled scans can still produce an inspectable, explicitly incomplete tree.

Negative/limitations:

- the existing M0 Swift stubs must be refactored before scanner implementation;
- canonical hard-link attribution to a subtree is a deterministic convention, not reclaimable bytes;
- Foundation allocates an entire shallow directory result and may delay cancellation inside that call;
- directory storage blocks and symlink allocated blocks are excluded in M1;
- APFS clones/shared blocks remain overcounted;
- `UInt32` node/name offsets and 40-byte stride become explicit tested capacity assumptions.
